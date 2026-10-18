import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHmac,randomUUID} from 'node:crypto';
import {collectTransactionSync,buildShoppingList,checkoutParameters,verifyStripeSignature,stripeSettlement,encryptToken,decryptToken,cents,verifiedEntitlement} from '../functions/_shared/core.mjs';
import {createHandler} from '../functions/_shared/handler.mjs';

const txn=(id,amount)=>({transaction_id:id,account_id:'acct',name:'Merchant',date:'2026-10-18',amount,iso_currency_code:'CAD',pending:false});
test('transaction pagination restarts after mutation and commits a complete result',async()=>{
  const calls=[]; let first=true;
  const result=await collectTransactionSync(async(path,body)=>{
    calls.push(body.cursor);
    if(body.cursor==='next' && first) {first=false;const e=new Error();e.providerCode='TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION';throw e;}
    if(body.cursor==='start') return {added:[txn('a',1)],modified:[],removed:[],next_cursor:'next',has_more:true};
    return {added:[txn('b',2)],modified:[txn('a',3)],removed:[{transaction_id:'b'}],next_cursor:'finished',has_more:false};
  },'secret-token','start');
  assert.deepEqual(calls,['start','next','start','next']);
  assert.equal(result.cursor,'finished'); assert.equal(result.transactions.length,1); assert.equal(result.transactions[0].amountCents,300); assert.deepEqual(result.removed,['b']);
});
test('incomplete transaction sync propagates failure without returning a cursor',async()=>{
  await assert.rejects(collectTransactionSync(async()=>{throw new Error('timeout')},'secret',null),/timeout/);
});
test('shopping requests preserve quantities without claiming an order was placed',()=>{
  const list=buildShoppingList('Groceries',[{title:'Oat milk',quantity:'2 × 1L'}]);
  assert.equal(list.line_items[0].name,'2 × 1L Oat milk'); assert.equal(list.link_type,'shopping_list');
  assert.throws(()=>buildShoppingList('Empty',[]),/pending items/);
});
test('checkout uses server quote values and cannot create digital subscriptions',()=>{
  const body=checkoutParameters({id:randomUUID(),amount_cents:12345,currency:'CAD',description:'Cleaning',stripe_account_id:'acct_verified'},'https://example.test/return');
  assert.equal(body.get('mode'),'payment'); assert.equal(body.get('line_items[0][price_data][unit_amount]'),'12345');
  assert.equal(body.get('payment_intent_data[transfer_data][destination]'),'acct_verified');
  assert.equal(body.has('subscription_data'),false);
  assert.throws(()=>checkoutParameters({amount_cents:1},'http://example.test'),/return URLs/);
});
test('Stripe webhooks require a valid, fresh signature and settled payment state',async()=>{
  const event={id:'evt_1',type:'checkout.session.completed',data:{object:{id:'cs_1',amount_total:100,currency:'cad',payment_status:'paid'}}};
  const raw=JSON.stringify(event), time=123456;
  const signature=createHmac('sha256','webhook-secret').update(`${time}.${raw}`).digest('hex');
  assert.deepEqual(await verifyStripeSignature(raw,`t=${time},v1=${signature}`,'webhook-secret',time),event);
  await assert.rejects(verifyStripeSignature(raw+' ',`t=${time},v1=${signature}`,'webhook-secret',time),/Invalid webhook/);
  await assert.rejects(verifyStripeSignature(raw,`t=${time},v1=${signature}`,'webhook-secret',time+301),/Expired/);
  assert.equal(stripeSettlement({...event,data:{object:{...event.data.object,payment_status:'unpaid'}}}),null);
  assert.equal(stripeSettlement(event).p_amount_cents,100);
});
test('bank access tokens are authenticated ciphertext and reject the wrong key',async()=>{
  const secret='ab'.repeat(32), token='access-sandbox-sensitive';
  const encrypted=await encryptToken(token,secret);
  assert.equal(encrypted.includes(token),false);
  assert.equal(await decryptToken(encrypted,secret),token);
  await assert.rejects(decryptToken(encrypted,'cd'.repeat(32)));
});
test('currency conversion preserves unknown balances and validates finite amounts',()=>{
  assert.equal(cents(null),null); assert.equal(cents(89.99),8999); assert.equal(cents(-12.34),-1234); assert.throws(()=>cents(Infinity));
});
test('API fails closed without authentication and never reflects provider secrets',async()=>{
  const handler=createHandler({get:()=>undefined},async()=>{throw new Error('secret-value')});
  const response=await handler(new Request('https://project.test/household-api/bank/snapshot',{method:'POST',body:'{}'}));
  assert.equal(response.status,401); assert.equal((await response.text()).includes('secret-value'),false);
});
test('public signup verification and adult membership gate private finance',async()=>{
  const user=randomUUID();
  const handler=createHandler({get:name=>({SUPABASE_URL:'https://project.test',SUPABASE_ANON_KEY:'public'}[name])},async url=>{
    if(url.endsWith('auth/v1/user')) return Response.json({id:user,email_confirmed_at:'2026-10-18T00:00:00Z'});
    return Response.json([]);
  });
  const response=await handler(new Request('https://project.test/household-api/bank/snapshot',{method:'POST',headers:{authorization:'Bearer user-token'},body:'{}'}));
  assert.equal(response.status,403);
});
test('verified subscriptions require the correct app, product, and household token',()=>{
  const household=randomUUID();
  const tx={bundleId:'com.example.household',appAccountToken:household,productId:'com.householdos.premium.annual',originalTransactionId:'original',expiresDate:Date.now()+86400000,signedDate:Date.now()};
  assert.equal(verifiedEntitlement(tx,household,'com.example.household').p_revoked,false);
  assert.equal(verifiedEntitlement({...tx,revocationDate:Date.now()},household,'com.example.household').p_revoked,true);
  assert.throws(()=>verifiedEntitlement(tx,randomUUID(),'com.example.household'),/different app or household/);
  assert.throws(()=>verifiedEntitlement({...tx,productId:'unrelated'},household,'com.example.household'),/Unsupported/);
});
