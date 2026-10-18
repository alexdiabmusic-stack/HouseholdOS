-- Narrow server RPCs keep the private schema out of the public API.
create function public.server_bank_items(p_user_id uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(i)),'[]'::jsonb) from private.bank_items i where i.user_id=p_user_id;
$$;
create function public.server_link_bank(p_user_id uuid,p_item_id text,p_access_token text,p_institution_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if exists(select 1 from private.bank_items where item_id=p_item_id and user_id<>p_user_id) then raise exception 'Bank item belongs to another user'; end if;
  insert into private.bank_items(user_id,item_id,access_token,institution_name)
  values(p_user_id,p_item_id,p_access_token,p_institution_name)
  on conflict(item_id) do update set access_token=excluded.access_token returning id into result;
  return result;
end;
$$;
create function public.server_commit_bank_sync(p_user_id uuid,p_bank_id uuid,p_expected_cursor text,p_cursor text,p_accounts jsonb,p_transactions jsonb,p_removed jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
declare bank private.bank_items; account jsonb; txn jsonb;
begin
  select * into bank from private.bank_items where id=p_bank_id and user_id=p_user_id for update;
  if bank.id is null then raise exception 'Bank item not found'; end if;
  if bank.cursor is distinct from p_expected_cursor then return false; end if;
  delete from public.bank_accounts where item_id=p_bank_id and user_id=p_user_id;
  for account in select * from jsonb_array_elements(p_accounts) loop
    insert into public.bank_accounts(id,user_id,item_id,payload) values(account->>'id',p_user_id,p_bank_id,account);
  end loop;
  for txn in select * from jsonb_array_elements(p_transactions) loop
    if exists(select 1 from public.bank_transactions where id=txn->>'id' and user_id<>p_user_id) then raise exception 'Transaction owner mismatch'; end if;
    insert into public.bank_transactions(id,user_id,item_id,payload) values(txn->>'id',p_user_id,p_bank_id,txn)
      on conflict(id) do update set payload=excluded.payload,updated_at=now();
  end loop;
  delete from public.bank_transactions where item_id=p_bank_id and user_id=p_user_id and id in (select jsonb_array_elements_text(p_removed));
  update private.bank_items set cursor=p_cursor where id=p_bank_id;
  return true;
end;
$$;
create function public.server_forget_bank(p_user_id uuid,p_bank_id uuid) returns void
language sql security definer set search_path = '' as $$
  delete from private.bank_items where id=p_bank_id and user_id=p_user_id;
$$;

create function public.server_quote(p_user_id uuid,p_quote_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare quote public.service_quotes;
begin
  select * into quote from public.service_quotes where id=p_quote_id;
  if quote.id is null or not exists(select 1 from public.household_members where household_id=quote.household_id and user_id=p_user_id and role in ('owner','member')) then raise exception 'Quote access denied'; end if;
  if quote.status not in ('quoted','checkout') or quote.expires_at<=now() then raise exception 'Quote is paid, cancelled, or expired'; end if;
  return to_jsonb(quote);
end;
$$;
create function public.server_save_checkout(p_user_id uuid,p_quote_id uuid,p_session_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare quote public.service_quotes;
begin
  select * into quote from public.service_quotes where id=p_quote_id for update;
  perform public.server_quote(p_user_id,p_quote_id);
  insert into private.checkout_requests(household_id,user_id,booking_id,provider_account_id,amount_cents,currency,stripe_session_id,status)
  values(quote.household_id,p_user_id,quote.id,quote.stripe_account_id,quote.amount_cents,quote.currency,p_session_id,'checkout')
  on conflict(booking_id) do update set stripe_session_id=excluded.stripe_session_id,status='checkout';
  update public.service_quotes set status='checkout' where id=p_quote_id;
end;
$$;
create function public.server_stripe_event(p_event_id text,p_type text,p_session_id text,p_amount_cents bigint,p_currency text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare request private.checkout_requests; target text;
begin
  if exists(select 1 from private.webhook_events where provider='stripe' and event_id=p_event_id) then return false; end if;
  select * into request from private.checkout_requests where stripe_session_id=p_session_id for update;
  if request.id is null then raise exception 'Checkout not registered; retry event'; end if;
  if request.amount_cents<>p_amount_cents or lower(request.currency)<>lower(p_currency) then raise exception 'Payment amount or currency mismatch'; end if;
  target := case p_type when 'checkout.session.completed' then 'paid' when 'checkout.session.async_payment_succeeded' then 'paid' when 'checkout.session.async_payment_failed' then 'quoted' when 'checkout.session.expired' then 'quoted' else null end;
  if target is null then raise exception 'Unsupported payment event'; end if;
  -- A stale failure/expiry must never reverse a settled payment.
  if request.status not in ('partially_refunded','refunded') and (request.status<>'paid' or target='paid') then
    update private.checkout_requests set status=target where id=request.id;
    update public.service_quotes set status=target where id=request.booking_id;
  end if;
  insert into private.webhook_events(provider,event_id) values('stripe',p_event_id) on conflict do nothing;
  return true;
end;
$$;
create function public.server_can_delete_account(p_user_id uuid) returns boolean
language sql security definer set search_path = '' as $$
  select not exists(select 1 from public.household_members where user_id=p_user_id and role='owner');
$$;

-- Preserve shared records when an account is deleted; user-owned bank data cascades.
alter table public.household_records drop constraint household_records_updated_by_fkey;
alter table public.household_records alter column updated_by drop not null;
alter table public.household_records add foreign key(updated_by) references auth.users on delete set null;
alter table public.household_invites drop constraint household_invites_created_by_fkey;
alter table public.household_invites add foreign key(created_by) references auth.users on delete cascade;
alter table private.checkout_requests drop constraint checkout_requests_user_id_fkey;
alter table private.checkout_requests alter column user_id drop not null;
alter table private.checkout_requests add foreign key(user_id) references auth.users on delete set null;

revoke execute on function public.server_bank_items(uuid),public.server_link_bank(uuid,text,text,text),public.server_commit_bank_sync(uuid,uuid,text,text,jsonb,jsonb,jsonb),public.server_forget_bank(uuid,uuid),public.server_quote(uuid,uuid),public.server_save_checkout(uuid,uuid,text),public.server_stripe_event(text,text,text,bigint,text),public.server_can_delete_account(uuid) from public,anon,authenticated;
grant execute on function public.server_bank_items(uuid),public.server_link_bank(uuid,text,text,text),public.server_commit_bank_sync(uuid,uuid,text,text,jsonb,jsonb,jsonb),public.server_forget_bank(uuid,uuid),public.server_quote(uuid,uuid),public.server_save_checkout(uuid,uuid,text),public.server_stripe_event(text,text,text,bigint,text),public.server_can_delete_account(uuid) to service_role;
