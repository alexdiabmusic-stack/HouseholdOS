export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
export function requireUUID(value, label = 'Record ID') {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) throw new HttpError(400,`${label} is invalid.`);
  return value;
}
export function cents(amount) {
  if (amount == null) return null;
  if (typeof amount !== 'number' || !Number.isFinite(amount)) throw new HttpError(502,'Invalid amount from provider.');
  const value = Math.round(amount * 100);
  if (!Number.isSafeInteger(value)) throw new HttpError(502,'Amount exceeds supported range.');
  return value;
}
export function mapAccount(account,institution) {
  return {id:account.account_id,name:account.name,institution,type:account.type,currency:account.balances.iso_currency_code ?? 'XXX',balanceCents:cents(account.balances.current),availableCents:cents(account.balances.available),mask:account.mask ?? null};
}
export function mapTransaction(tx) {
  return {id:tx.transaction_id,accountID:tx.account_id,name:tx.merchant_name ?? tx.name,date:tx.date,amountCents:cents(tx.amount),currency:tx.iso_currency_code ?? 'XXX',pending:tx.pending === true,category:tx.personal_finance_category?.primary ?? 'OTHER'};
}
// A cursor is committed only after every page has completed successfully.
export async function collectTransactionSync(call,accessToken,cursor) {
  for(let attempt=0;attempt<3;attempt++) {
    let next = cursor, hasMore = true, pages = 0;
    const changed=new Map(), removed=new Set();
    try {
      while(hasMore) {
        if(++pages>40) throw new HttpError(503,'Bank history is still syncing. Try again later.');
        const page=await call('/transactions/sync',{access_token:accessToken,...(next ? {cursor:next} : {}),count:500});
        for(const tx of [...page.added,...page.modified]) { changed.set(tx.transaction_id,mapTransaction(tx)); removed.delete(tx.transaction_id); }
        for(const tx of page.removed) { changed.delete(tx.transaction_id); removed.add(tx.transaction_id); }
        next=page.next_cursor; hasMore=page.has_more;
      }
      return {cursor:next,transactions:[...changed.values()],removed:[...removed]};
    } catch(error) {
      if(error.providerCode!=='TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' || attempt===2) throw error;
    }
  }
}
export function buildShoppingList(title,items) {
  if(!Array.isArray(items) || items.length<1 || items.length>200) throw new HttpError(400,'Choose a list with 1 to 200 pending items.');
  return {title:title.slice(0,100),link_type:'shopping_list',line_items:items.map(item=>({name:[item.quantity,item.title].filter(Boolean).join(' ').slice(0,200),quantity:1,unit:'each'}))};
}
export function checkoutParameters(quote,returnURL) {
  const url=new URL(returnURL);
  if(url.protocol!=='https:') throw new HttpError(503,'Payment return URLs are not configured.');
  if(!Number.isSafeInteger(Number(quote.amount_cents)) || Number(quote.amount_cents)<1) throw new HttpError(400,'Invalid quote amount.');
  return new URLSearchParams({
    mode:'payment',success_url:`${url.origin}${url.pathname}?payment=returned`,cancel_url:`${url.origin}${url.pathname}?payment=cancelled`,
    'line_items[0][price_data][currency]':quote.currency.toLowerCase(),
    'line_items[0][price_data][unit_amount]':String(quote.amount_cents),
    'line_items[0][price_data][product_data][name]':quote.description.slice(0,100),
    'line_items[0][quantity]':'1',
    'payment_intent_data[transfer_data][destination]':quote.stripe_account_id,
    'metadata[quote_id]':quote.id,
    'payment_intent_data[metadata][quote_id]':quote.id,
  });
}
function equalHex(a,b) {
  if(a.length!==b.length) return false;
  let result=0; for(let i=0;i<a.length;i++) result|=a.charCodeAt(i)^b.charCodeAt(i);
  return result===0;
}
export async function verifyStripeSignature(raw,header,secret,now=Math.floor(Date.now()/1000)) {
  if(!header || !secret) throw new HttpError(400,'Missing webhook signature.');
  const parts=header.split(',').map(x=>x.split('='));
  const timestamp=parts.find(([k])=>k==='t')?.[1];
  if(!timestamp || !/^\d+$/.test(timestamp) || Math.abs(now-Number(timestamp))>300) throw new HttpError(400,'Expired webhook signature.');
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const signed=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`${timestamp}.${raw}`));
  const expected=[...new Uint8Array(signed)].map(x=>x.toString(16).padStart(2,'0')).join('');
  if(!parts.some(([k,v])=>k==='v1' && equalHex(v ?? '',expected))) throw new HttpError(400,'Invalid webhook signature.');
  return JSON.parse(raw);
}
export function stripeSettlement(event) {
  const session=event.data?.object;
  const allowed=['checkout.session.completed','checkout.session.async_payment_succeeded','checkout.session.async_payment_failed','checkout.session.expired'];
  if(!allowed.includes(event.type)) return null;
  if(event.type==='checkout.session.completed' && session.payment_status!=='paid') return null;
  if(event.type==='checkout.session.async_payment_succeeded' && session.payment_status!=='paid') throw new HttpError(400,'Payment is not settled.');
  return {p_event_id:event.id,p_type:event.type,p_session_id:session.id,p_amount_cents:session.amount_total,p_currency:session.currency};
}
export async function encryptToken(token,secret) {
  if(!secret || !/^[0-9a-f]{64}$/i.test(secret)) throw new HttpError(503,'Bank token encryption is not configured.');
  const keyBytes=new Uint8Array(secret.match(/.{2}/g).map(x=>parseInt(x,16)));
  const key=await crypto.subtle.importKey('raw',keyBytes,'AES-GCM',false,['encrypt']);
  const iv=crypto.getRandomValues(new Uint8Array(12));
  const data=await crypto.subtle.encrypt({name:'AES-GCM',iv},key,new TextEncoder().encode(token));
  return `v1.${btoa(String.fromCharCode(...iv))}.${btoa(String.fromCharCode(...new Uint8Array(data)))}`;
}
export async function decryptToken(value,secret) {
  if(!secret || !/^[0-9a-f]{64}$/i.test(secret)) throw new HttpError(503,'Bank token encryption is not configured.');
  const [version,iv,data]=value.split('.');
  if(version!=='v1' || !iv || !data) throw new HttpError(500,'Stored bank connection is invalid.');
  const key=await crypto.subtle.importKey('raw',new Uint8Array(secret.match(/.{2}/g).map(x=>parseInt(x,16))),'AES-GCM',false,['decrypt']);
  return new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:Uint8Array.from(atob(iv),x=>x.charCodeAt(0))},key,Uint8Array.from(atob(data),x=>x.charCodeAt(0))));
}

// Call only with Apple's cryptographically verified transaction payload.
export function verifiedEntitlement(tx,householdID,bundleID) {
  requireUUID(householdID,'Household');
  if(tx.bundleId!==bundleID || tx.appAccountToken?.toLowerCase()!==householdID.toLowerCase()) throw new HttpError(403,'This purchase belongs to a different app or household.');
  if(!['com.householdos.premium.monthly','com.householdos.premium.annual'].includes(tx.productId)) throw new HttpError(400,'Unsupported subscription product.');
  if(typeof tx.originalTransactionId!=='string' || !Number.isFinite(tx.expiresDate) || !Number.isFinite(tx.signedDate)) throw new HttpError(400,'Incomplete subscription transaction.');
  return {p_household_id:householdID,p_original_id:tx.originalTransactionId,p_product_id:tx.productId,p_expires_at:new Date(tx.expiresDate).toISOString(),p_revoked:tx.revocationDate!=null,p_signed_at:new Date(tx.signedDate).toISOString()};
}
