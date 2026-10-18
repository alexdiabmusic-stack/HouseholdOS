import {HttpError,requireUUID,mapAccount,collectTransactionSync,buildShoppingList,checkoutParameters,verifyStripeSignature,stripeSettlement,encryptToken,decryptToken} from './core.mjs';

export function createHandler(env,fetcher=fetch) {
  const setting=(name)=>env.get(name);
  const required=(name)=>{const value=setting(name);if(!value) throw new HttpError(503,'This connection has not been configured yet.');return value;};
  const base=()=>required('SUPABASE_URL').replace(/\/$/,'');
  const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});

  async function api(path,{token,service=false,method='POST',body}={}) {
    const key=service ? required('SUPABASE_SERVICE_ROLE_KEY') : required('SUPABASE_ANON_KEY');
    const response=await fetcher(`${base()}/${path}`,{method,headers:{apikey:key,Authorization:`Bearer ${service ? key : token}`,'Content-Type':'application/json'},...(body===undefined ? {} : {body:JSON.stringify(body)}),signal:AbortSignal.timeout(20000)});
    if(!response.ok) {
      const failure=await response.json().catch(()=>({}));
      throw new HttpError(response.status>=500 ? 503 : response.status,failure.message ?? failure.msg ?? 'The operation could not be completed.');
    }
    if(response.status===204) return null;
    const text=await response.text(); return text ? JSON.parse(text) : null;
  }
  const rpc=(name,body)=>api(`rest/v1/rpc/${name}`,{service:true,body});
  async function plaid(path,body) {
    const environment=setting('PLAID_ENV') ?? 'sandbox';
    if(!['sandbox','production'].includes(environment)) throw new HttpError(503,'Bank environment is invalid.');
    const response=await fetcher(`https://${environment}.plaid.com${path}`,{method:'POST',headers:{'Content-Type':'application/json','Plaid-Version':'2020-09-14'},body:JSON.stringify({client_id:required('PLAID_CLIENT_ID'),secret:required('PLAID_SECRET'),...body}),signal:AbortSignal.timeout(25000)});
    const result=await response.json();
    if(!response.ok) {
      const error=new HttpError(502,result.error_code==='ITEM_LOGIN_REQUIRED' ? 'Reconnect your bank to refresh its data.' : 'Plaid could not complete the request. Try again or reconnect your bank.');
      error.providerCode=result.error_code; throw error;
    }
    return result;
  }
  async function stripe(path,body,key) {
    const secret=required('STRIPE_SECRET_KEY');
    if(!secret.startsWith('sk_test_') && setting('ENABLE_LIVE_SERVICE_PAYMENTS')!=='true') throw new HttpError(503,'Live service payments are not enabled.');
    const response=await fetcher(`https://api.stripe.com/v1${path}`,{method:body ? 'POST':'GET',headers:{Authorization:`Bearer ${secret}`,...(body ? {'Content-Type':'application/x-www-form-urlencoded'} : {}),...(key ? {'Idempotency-Key':key}:{})},...(body ? {body:body.toString()}:{}),signal:AbortSignal.timeout(20000)});
    const result=await response.json();
    if(!response.ok) throw new HttpError(502,'The payment service could not complete the request.');
    return result;
  }
  async function bankItems(userID) { return await rpc('server_bank_items',{p_user_id:userID}); }
  async function syncBanks(userID) {
    const items=await bankItems(userID);
    for(const item of items) {
      const access=await decryptToken(item.access_token,required('BANK_TOKEN_ENCRYPTION_KEY'));
      const accounts=await plaid('/accounts/get',{access_token:access});
      const changes=await collectTransactionSync(plaid,access,item.cursor);
      const committed=await rpc('server_commit_bank_sync',{p_user_id:userID,p_bank_id:item.id,p_expected_cursor:item.cursor,p_cursor:changes.cursor,p_accounts:accounts.accounts.map(a=>mapAccount(a,item.institution_name)),p_transactions:changes.transactions,p_removed:changes.removed});
      if(!committed) throw new HttpError(409,'Another refresh finished first. Refresh again to get the latest data.');
    }
  }
  async function exchange(userID,publicToken) {
    if(typeof publicToken!=='string' || !publicToken.startsWith('public-') || publicToken.length>300) throw new HttpError(400,'Invalid bank linking token.');
    const result=await plaid('/item/public_token/exchange',{public_token:publicToken});
    // Persist immediately after exchange so a later sync error cannot orphan access.
    await rpc('server_link_bank',{p_user_id:userID,p_item_id:result.item_id,p_access_token:await encryptToken(result.access_token,required('BANK_TOKEN_ENCRYPTION_KEY')),p_institution_name:'Connected bank'});
    await syncBanks(userID);
  }
  async function disconnect(userID) {
    for(const item of await bankItems(userID)) {
      await plaid('/item/remove',{access_token:await decryptToken(item.access_token,required('BANK_TOKEN_ENCRYPTION_KEY'))});
      await rpc('server_forget_bank',{p_user_id:userID,p_bank_id:item.id});
    }
  }

  return async function handle(request) {
    try {
      const url=new URL(request.url);
      const marker='/household-api/';
      const action=url.pathname.includes(marker) ? url.pathname.split(marker)[1] : url.pathname.replace(/^\//,'');
      if(request.method!=='POST') return json({error:'Use POST.'},405);
      if(Number(request.headers.get('content-length') ?? 0)>65536) throw new HttpError(413,'Request is too large.');
      const raw=await request.text();
      if(new TextEncoder().encode(raw).length>65536) throw new HttpError(413,'Request is too large.');

      if(action==='stripe/webhook') {
        const event=await verifyStripeSignature(raw,request.headers.get('stripe-signature'),required('STRIPE_WEBHOOK_SECRET'));
        if(event.livemode && setting('ENABLE_LIVE_SERVICE_PAYMENTS')!=='true') throw new HttpError(400,'Live payments are not enabled.');
        const settlement=stripeSettlement(event);
        if(settlement) await rpc('server_stripe_event',settlement);
        if(event.type==='charge.refunded') {
          const charge=event.data?.object;
          await rpc('server_stripe_refund',{p_event_id:event.id,p_quote_id:requireUUID(charge?.metadata?.quote_id,'Quote'),p_amount_cents:charge.amount,p_refunded_cents:charge.amount_refunded,p_currency:charge.currency});
        }
        return json({received:true});
      }
      if(action==='storekit/notifications') {
        const {appleService}=await import('./apple.mjs');
        const event=await appleService(env).notification(JSON.parse(raw).signedPayload);
        if(event) await rpc('server_store_entitlement',event);
        return json({received:true});
      }

      const authorization=request.headers.get('authorization');
      if(!authorization?.startsWith('Bearer ')) throw new HttpError(401,'Sign in to continue.');
      const token=authorization.slice(7);
      const user=await api('auth/v1/user',{token,method:'GET'});
      if(!user.id || !user.email_confirmed_at) throw new HttpError(403,'Verify your email before continuing.');
      const body=raw ? JSON.parse(raw) : {};
      if(!body || Array.isArray(body) || typeof body!=='object') throw new HttpError(400,'Invalid request.');

      if(action==='capabilities') {
        return json({banking:!!setting('PLAID_CLIENT_ID') && !!setting('PLAID_SECRET') && !!setting('BANK_TOKEN_ENCRYPTION_KEY'),grocery:!!setting('INSTACART_API_KEY'),servicePayments:!!setting('STRIPE_SECRET_KEY') && !!setting('STRIPE_WEBHOOK_SECRET') && !!setting('PAYMENT_RETURN_URL'),subscriptions:setting('PREMIUM_LAUNCH_ENABLED')==='true' && ['APP_BUNDLE_ID','APP_STORE_PRIVATE_KEY','APP_STORE_KEY_ID','APP_STORE_ISSUER_ID','APPLE_ROOT_CA_BASE64'].every(key=>!!setting(key))});
      }
      if(action==='storekit/verify') {
        const household=requireUUID(body.household_id,'Household');
        const membership=await api(`rest/v1/household_members?household_id=eq.${household}&user_id=eq.${user.id}&role=in.(owner,member)&select=user_id`,{token,method:'GET'});
        if(membership.length!==1) throw new HttpError(403,'An adult household member must manage this subscription.');
        const {appleService}=await import('./apple.mjs');
        const event=await appleService(env).transaction(body.transaction_id,household);
        await rpc('server_store_entitlement',event);
        return json(await api('rest/v1/rpc/household_entitlement',{token,body:{p_household_id:household}}));
      }

      if(action.startsWith('bank/') || action==='stripe/checkout') {
        const memberships=await api(`rest/v1/household_members?user_id=eq.${user.id}&role=in.(owner,member)&select=user_id&limit=1`,{token,method:'GET'});
        if(memberships.length===0) throw new HttpError(403,'An adult household account is required.');
      }
      if(action==='bank/link-token') {
        // OAuth banks require a registered HTTPS universal-link redirect.
        const redirect=required('PLAID_REDIRECT_URI');
        if(new URL(redirect).protocol!=='https:') throw new HttpError(503,'Bank redirect is not configured.');
        const result=await plaid('/link/token/create',{user:{client_user_id:user.id},client_name:'Household OS',products:['transactions'],country_codes:(setting('PLAID_COUNTRY_CODES') ?? 'CA,US').split(','),language:'en',redirect_uri:redirect,...(setting('PLAID_WEBHOOK_URL') ? {webhook:setting('PLAID_WEBHOOK_URL')} : {})});
        return json({link_token:result.link_token});
      }
      if(action==='bank/sandbox') {
        if((setting('PLAID_ENV') ?? 'sandbox')!=='sandbox') throw new HttpError(403,'Sandbox test connections are disabled.');
        // Transaction-specific persona. Bank Income uses its own separate product.
        const result=await plaid('/sandbox/public_token/create',{institution_id:'ins_109508',initial_products:['transactions'],options:{override_username:'user_transactions_dynamic',override_password:'pass_good'}});
        await exchange(user.id,result.public_token);
        return json({connected:true,environment:'sandbox'});
      }
      if(action==='bank/exchange') { await exchange(user.id,body.public_token); return json({connected:true}); }
      if(action==='bank/sync') { await syncBanks(user.id); return json({synced:true}); }
      if(action==='bank/disconnect') { await disconnect(user.id); return json({disconnected:true}); }
      if(action==='bank/snapshot') {
        const accounts=await api('rest/v1/bank_accounts?select=payload,updated_at&order=id',{token,method:'GET'});
        const txs=await api('rest/v1/bank_transactions?select=payload&order=payload->>date.desc,id&limit=200',{token,method:'GET'});
        return json({accounts:accounts.map(x=>x.payload),transactions:txs.map(x=>x.payload),environment:setting('PLAID_ENV') ?? 'sandbox',refreshedAt:accounts.map(x=>x.updated_at).sort().at(-1) ?? null});
      }
      if(action==='grocery/list') {
        const id=requireUUID(body.list_id,'List');
        const rows=await api(`rest/v1/household_records?id=eq.${id}&kind=eq.list&deleted=eq.false&select=*`,{token,method:'GET'});
        if(rows.length!==1) throw new HttpError(404,'List not found.');
        const parent=rows[0];
        const children=await api(`rest/v1/household_records?household_id=eq.${parent.household_id}&kind=eq.item&deleted=eq.false&select=payload&limit=1000`,{token,method:'GET'});
        const pending=children.filter(x=>x.payload.parentID?.toLowerCase()===id.toLowerCase() && !x.payload.completed).map(x=>x.payload);
        const host=(setting('INSTACART_ENV') ?? 'development')==='production' ? 'https://connect.instacart.com':'https://connect.dev.instacart.tools';
        const response=await fetcher(`${host}/idp/v1/products/products_link`,{method:'POST',headers:{Authorization:`Bearer ${required('INSTACART_API_KEY')}`,'Content-Type':'application/json',Accept:'application/json'},body:JSON.stringify(buildShoppingList(parent.payload.title,pending)),signal:AbortSignal.timeout(20000)});
        if(!response.ok) throw new HttpError(502,'Instacart could not create a shopping list.');
        const result=await response.json();
        const link=new URL(result.products_link_url);
        if(link.protocol!=='https:' || !(link.hostname==='instacart.com' || link.hostname.endsWith('.instacart.com') || link.hostname.endsWith('.instacart.tools'))) throw new HttpError(502,'Instacart returned an invalid link.');
        return json({url:link.toString()});
      }
      if(action==='stripe/checkout') {
        const quote=await rpc('server_quote',{p_user_id:user.id,p_quote_id:requireUUID(body.quote_id,'Quote')});
        const account=await stripe(`/accounts/${encodeURIComponent(quote.stripe_account_id)}`);
        if(!account.charges_enabled || !account.payouts_enabled) throw new HttpError(409,'This provider is not ready to accept payments.');
        const session=await stripe('/checkout/sessions',checkoutParameters(quote,required('PAYMENT_RETURN_URL')),`householdos-quote-${quote.id}`);
        if(session.status==='expired') throw new HttpError(409,'This checkout expired. Request an updated quote.');
        await rpc('server_save_checkout',{p_user_id:user.id,p_quote_id:quote.id,p_session_id:session.id});
        return json({url:session.url});
      }
      if(action==='account/delete') {
        const allowed=await rpc('server_can_delete_account',{p_user_id:user.id});
        if(!allowed) throw new HttpError(409,'Transfer ownership of your households before deleting your account.');
        await disconnect(user.id);
        await api(`auth/v1/admin/users/${user.id}`,{service:true,method:'DELETE'});
        return json({deleted:true});
      }
      throw new HttpError(404,'Unknown operation.');
    } catch(error) {
      if(error instanceof HttpError) return json({error:error.message},error.status);
      if(error instanceof SyntaxError) return json({error:'Invalid JSON request.'},400);
      // Do not return provider bodies, SQL traces, access tokens, or credentials.
      return json({error:'The service could not complete the request. Please try again.'},503);
    }
  };
}
