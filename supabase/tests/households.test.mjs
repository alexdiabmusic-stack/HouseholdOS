import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { PGlite } from '@electric-sql/pglite';

let db;
const owner = randomUUID(), member = randomUUID(), child = randomUUID(), outsider = randomUUID(), unverified = randomUUID();
let household;
async function as(user, action) {
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);
  await db.exec('set role authenticated');
  try { return await action(); } finally { await db.exec('reset role'); }
}
async function rpc(name, params) {
  const values = Object.values(params);
  const result = await db.query(`select to_jsonb(public.${name}(${Object.keys(params).map((k,i)=>`${k} => $${i+1}`).join(',')})) as result`,values);
  return result.rows[0]?.result;
}
function mutation(kind,payload,options={}) {
  return {p_id:options.id ?? randomUUID(),p_household_id:options.household ?? household.id,p_kind:kind,p_payload:payload,p_base_version:options.version ?? 0,p_deleted:options.deleted ?? false,p_mutation_id:options.mutation ?? randomUUID()};
}
before(async()=>{
  db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    grant usage on schema auth to authenticated;
    grant execute on function auth.uid() to authenticated;`);
  for(const [id,email,verified] of [[owner,'owner@example.test',true],[member,'member@example.test',true],[child,'child@example.test',true],[outsider,'other@example.test',true],[unverified,'unverified@example.test',false]]) {
    await db.query('insert into auth.users values($1,$2,$3)',[id,email,verified ? new Date().toISOString() : null]);
  }
  for(const file of (await readdir(new URL('../migrations/',import.meta.url))).sort()) {
    await db.exec(await readFile(new URL('../migrations/'+file,import.meta.url),'utf8'));
  }
  household = await as(owner,()=>rpc('create_household',{p_name:'Our home',p_display_name:'Owner'}));
});
after(async()=>{await db?.close()});

test('email confirmation is required before creating a household',async()=>{
  await assert.rejects(as(unverified,()=>rpc('create_household',{p_name:'No',p_display_name:'Unverified'})),/Verify your email/);
});
test('invites require owner, matching verified email, and cannot be reused by another user',async()=>{
  const invite=await as(owner,()=>rpc('create_invite',{p_household_id:household.id,p_email:'MEMBER@example.test'}));
  await assert.rejects(as(outsider,()=>rpc('accept_invite',{p_token:invite.token,p_display_name:'Wrong'})),/invalid, expired/);
  assert.equal(await as(member,()=>rpc('accept_invite',{p_token:invite.token,p_display_name:'Member'})),household.id);
  await assert.rejects(as(member,()=>rpc('create_invite',{p_household_id:household.id,p_email:'other@example.test'})),/Only the household owner/);
  const childInvite=await as(owner,()=>rpc('create_invite',{p_household_id:household.id,p_email:'child@example.test',p_role:'child'}));
  await as(child,()=>rpc('accept_invite',{p_token:childInvite.token,p_display_name:'Child'}));
});
test('RLS isolates households and blocks all direct application writes',async()=>{
  assert.equal((await as(outsider,()=>db.query('select * from public.households'))).rows.length,0);
  await assert.rejects(as(member,()=>db.query("insert into public.household_members values($1,$2,'Escalated','owner',now())",[household.id,outsider])),/permission denied/);
  await assert.rejects(as(outsider,()=>rpc('mutate_record',mutation('task',{title:'Intrusion'}))),/access denied/);
  await assert.rejects(as(member,()=>db.query('select * from private.bank_items')),/permission denied/);
});
test('mutations are retry-safe and preserve conflicting edits',async()=>{
  const change=mutation('task',{title:'Dishes',completed:false});
  const created=await as(owner,()=>rpc('mutate_record',change));
  const replay=await as(owner,()=>rpc('mutate_record',change));
  assert.deepEqual(replay,created);
  assert.equal(created.record.version,1);
  const updated=await as(member,()=>rpc('mutate_record',mutation('task',{title:'Dishes after dinner',completed:false},{id:change.p_id,version:1})));
  assert.equal(updated.record.version,2);
  const conflict=await as(owner,()=>rpc('mutate_record',mutation('task',{title:'My stale edit'},{id:change.p_id,version:1})));
  assert.equal(conflict.conflict,true);
  assert.equal(conflict.record.payload.title,'Dishes after dinner');
});
test('children can share chores but cannot read or write bills',async()=>{
  await as(child,()=>rpc('mutate_record',mutation('task',{title:'Tidy bedroom',assigneeID:child})));
  await as(owner,()=>rpc('mutate_record',mutation('bill',{title:'Rent',amountCents:150000,currency:'CAD'})));
  assert.equal((await as(child,()=>db.query("select * from public.household_records where kind='bill'"))).rows.length,0);
  await assert.rejects(as(child,()=>rpc('mutate_record',mutation('bill',{title:'No',amountCents:1,currency:'CAD'}))),/Financial access/);
});
test('deleted lists cascade tombstones and cannot be resurrected',async()=>{
  const list=mutation('list',{title:'Groceries'});
  await as(owner,()=>rpc('mutate_record',list));
  const item=mutation('item',{title:'Milk',parentID:list.p_id.toUpperCase()});
  await as(member,()=>rpc('mutate_record',item));
  await as(owner,()=>rpc('mutate_record',{...list,p_base_version:1,p_deleted:true,p_mutation_id:randomUUID()}));
  const row=await db.query('select deleted,version from public.household_records where id=$1',[item.p_id]);
  assert.equal(row.rows[0].deleted,true);
  await assert.rejects(as(owner,()=>rpc('mutate_record',{...list,p_base_version:2,p_mutation_id:randomUUID()})),/cannot be restored/);
  await assert.rejects(as(member,()=>rpc('mutate_record',mutation('item',{title:'Bread',parentID:list.p_id}))),/List no longer exists/);
});
test('recurrences run once, preserve month-end anchors and local wall time',async()=>{
  const task=mutation('task',{title:'Filter',completed:false,repeatRule:'monthly',anchorDay:31,dueAt:'2026-01-31T14:00:00Z'});
  await as(owner,()=>rpc('mutate_record',task));
  const complete={...task,p_base_version:1,p_payload:{...task.p_payload,completed:true},p_mutation_id:randomUUID()};
  const first=await as(owner,()=>rpc('mutate_record',complete));
  assert.equal(first.nextRecord.payload.dueAt,'2026-02-28T14:00:00Z');
  const second=await as(owner,()=>rpc('mutate_record',mutation('task',{...first.nextRecord.payload,completed:true},{id:first.nextRecord.id,version:1})));
  assert.equal(second.nextRecord.payload.dueAt,'2026-03-31T13:00:00Z');
  assert.deepEqual(await as(owner,()=>rpc('mutate_record',complete)),first);
  const daily=await db.query("select private.next_due('2026-03-07T14:00:00Z','daily','America/Toronto',7) as due");
  assert.equal(daily.rows[0].due.toISOString(),'2026-03-08T13:00:00.000Z');
});
test('payment records require a real member payer and positive integer cents',async()=>{
  await assert.rejects(as(owner,()=>rpc('mutate_record',mutation('bill',{title:'Bad',amountCents:0,currency:'CAD'}))),/Invalid bill/);
  await assert.rejects(as(owner,()=>rpc('mutate_record',mutation('bill',{title:'Bad',amountCents:100,currency:'CAD',paid:true}))),/who paid/);
  await assert.rejects(as(owner,()=>rpc('mutate_record',mutation('task',{title:'Bad assignment',assigneeID:outsider}))),/Assignee/);
});
test('removing members revokes access; owners must transfer ownership first',async()=>{
  await assert.rejects(as(owner,()=>rpc('remove_member',{p_household_id:household.id,p_user_id:owner})),/Transfer ownership/);
  await as(owner,()=>rpc('remove_member',{p_household_id:household.id,p_user_id:child}));
  assert.equal((await as(child,()=>db.query('select * from public.household_records'))).rows.length,0);
  await assert.rejects(as(child,()=>rpc('mutate_record',mutation('task',{title:'Old access'}))),/access denied/);
});

test('expired and revoked invitations cannot create memberships',async()=>{
  const expired=await as(owner,()=>rpc('create_invite',{p_household_id:household.id,p_email:'other@example.test'}));
  await db.query("update public.household_invites set expires_at=now()-interval '1 minute' where id=$1",[expired.id]);
  await assert.rejects(as(outsider,()=>rpc('accept_invite',{p_token:expired.token,p_display_name:'Outsider'})),/expired/);
  const revoked=await as(owner,()=>rpc('create_invite',{p_household_id:household.id,p_email:'other@example.test'}));
  await as(owner,()=>rpc('revoke_invite',{p_invite_id:revoked.id}));
  await assert.rejects(as(outsider,()=>rpc('accept_invite',{p_token:revoked.token,p_display_name:'Outsider'})),/invalid/);
});
test('server integration RPCs are inaccessible to application users',async()=>{
  await assert.rejects(as(owner,()=>rpc('server_bank_items',{p_user_id:owner})),/permission denied/);
  await assert.rejects(as(owner,()=>rpc('server_store_entitlement',{p_household_id:household.id,p_original_id:'fake',p_product_id:'fake',p_expires_at:new Date().toISOString(),p_revoked:false,p_signed_at:new Date().toISOString()})),/permission denied/);
});
test('bank sync commits transactions and cursor atomically and detects competing refreshes',async()=>{
  const bank=await rpc('server_link_bank',{p_user_id:owner,p_item_id:'item-1',p_access_token:'encrypted-token',p_institution_name:'Test bank'});
  const sync={p_user_id:owner,p_bank_id:bank,p_expected_cursor:null,p_cursor:'cursor-1',p_accounts:[{id:'account-1',name:'Checking'}],p_transactions:[{id:'transaction-1',amountCents:100}],p_removed:[]};
  assert.equal(await rpc('server_commit_bank_sync',sync),true);
  assert.equal(await rpc('server_commit_bank_sync',{...sync,p_cursor:'wrong'}),false);
  assert.equal((await rpc('server_bank_items',{p_user_id:owner}))[0].cursor,'cursor-1');
  assert.equal((await as(member,()=>db.query('select * from public.bank_accounts'))).rows.length,0);
  await rpc('server_commit_bank_sync',{...sync,p_expected_cursor:'cursor-1',p_cursor:'cursor-2',p_transactions:[],p_removed:['transaction-1']});
  assert.equal((await db.query('select * from public.bank_transactions')).rows.length,0);
});
test('Stripe settlement requires matching amount, deduplicates events, and survives stale failures',async()=>{
  const quote=randomUUID();
  await db.query("insert into public.service_quotes(id,household_id,provider_name,stripe_account_id,amount_cents,currency,description,expires_at) values($1,$2,'Cleaner','acct_test',12345,'CAD','Cleaning',now()+interval '1 day')",[quote,household.id]);
  await rpc('server_save_checkout',{p_user_id:owner,p_quote_id:quote,p_session_id:'cs_test'});
  const settlement={p_event_id:'evt_paid',p_type:'checkout.session.completed',p_session_id:'cs_test',p_amount_cents:12345,p_currency:'cad'};
  await assert.rejects(rpc('server_stripe_event',{...settlement,p_amount_cents:1}),/amount or currency/);
  assert.equal(await rpc('server_stripe_event',settlement),true);
  assert.equal(await rpc('server_stripe_event',settlement),false);
  await rpc('server_stripe_event',{...settlement,p_event_id:'evt_stale',p_type:'checkout.session.async_payment_failed'});
  assert.equal((await db.query('select status from public.service_quotes where id=$1',[quote])).rows[0].status,'paid');
  await assert.rejects(rpc('server_quote',{p_user_id:outsider,p_quote_id:quote}),/access denied/);
});
test('household subscriptions reject reassignment and old revocation events',async()=>{
  const later=Date.now()+3600000, signed=Date.now();
  const grant={p_household_id:household.id,p_original_id:'original_1',p_product_id:'com.householdos.premium.annual',p_expires_at:new Date(later).toISOString(),p_revoked:false,p_signed_at:new Date(signed).toISOString()};
  await rpc('server_store_entitlement',grant);
  assert.equal((await as(member,()=>rpc('household_entitlement',{p_household_id:household.id}))).active,true);
  await rpc('server_store_entitlement',{...grant,p_revoked:true,p_signed_at:new Date(signed-1000).toISOString()});
  assert.equal((await as(owner,()=>rpc('household_entitlement',{p_household_id:household.id}))).active,true);
  const other=await as(outsider,()=>rpc('create_household',{p_name:'Other home',p_display_name:'Other'}));
  await assert.rejects(rpc('server_store_entitlement',{...grant,p_household_id:other.id}),/different household/);
  await rpc('server_store_entitlement',{...grant,p_revoked:true,p_signed_at:new Date(signed+1000).toISOString()});
  assert.equal((await as(owner,()=>rpc('household_entitlement',{p_household_id:household.id}))).active,false);
});
