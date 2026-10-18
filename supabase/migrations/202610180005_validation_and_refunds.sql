-- Preserve ownership invariants even if an Auth admin deletion races a request.
create function private.protect_owner_account() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.household_members where user_id=old.id and role='owner') then raise exception 'Transfer household ownership before deleting this account'; end if;
  return old;
end;
$$;
create trigger protect_household_owner before delete on auth.users for each row execute function private.protect_owner_account();
revoke execute on function private.protect_owner_account() from public,anon,authenticated;

-- Validate document types and allocations for every write, including future clients.
create function private.validate_record_payload() returns trigger
language plpgsql security definer set search_path = '' as $$
declare pair record; total bigint:=0; value jsonb; step jsonb;
begin
  if jsonb_typeof(new.payload->'title')<>'string' then raise exception 'Title must be text'; end if;
  foreach value in array array[new.payload->'completed',new.payload->'paid'] loop
    if value is not null and jsonb_typeof(value)<>'boolean' then raise exception 'Completion and paid status must be booleans'; end if;
  end loop;
  if new.payload->>'shoppingByID' is not null and not exists(select 1 from public.household_members where household_id=new.household_id and user_id=(new.payload->>'shoppingByID')::uuid) then raise exception 'Shopper must be a household member'; end if;
  if new.payload ? 'subtasks' then
    if jsonb_typeof(new.payload->'subtasks')<>'array' or jsonb_array_length(new.payload->'subtasks')>30 then raise exception 'Use no more than 30 subtasks'; end if;
    for step in select * from jsonb_array_elements(new.payload->'subtasks') loop
      if jsonb_typeof(step->'title')<>'string' or length(trim(step->>'title')) not between 1 and 160 or jsonb_typeof(step->'completed')<>'boolean' then raise exception 'Invalid subtask'; end if;
      perform (step->>'id')::uuid;
    end loop;
  end if;
  if new.payload ? 'rotation' then
    if jsonb_typeof(new.payload->'rotation')<>'array' or jsonb_array_length(new.payload->'rotation')>100 then raise exception 'Invalid rotation'; end if;
    for step in select * from jsonb_array_elements(new.payload->'rotation') loop perform (step #>> '{}')::uuid; end loop;
  end if;
  if new.kind='bill' and new.payload ? 'shares' then
    if jsonb_typeof(new.payload->'shares')<>'object' then raise exception 'Invalid household shares'; end if;
    for pair in select * from jsonb_each(new.payload->'shares') loop
      if jsonb_typeof(pair.value)<>'number' or (pair.value::text) !~ '^[0-9]+$' then raise exception 'Shares must be nonnegative integer cents'; end if;
      if not exists(select 1 from public.household_members where household_id=new.household_id and user_id=pair.key::uuid and role in ('owner','member')) then
        -- Historical allocations remain valid after a member leaves.
        if tg_op<>'UPDATE' or old.payload->'shares' is distinct from new.payload->'shares' then raise exception 'Shares must belong to adult household members'; end if;
      end if;
      total:=total+(pair.value::text)::bigint;
    end loop;
    if new.payload->'shares'<>'{}'::jsonb and total<>(new.payload->>'amountCents')::bigint then raise exception 'Shares must add up to the bill amount'; end if;
  end if;
  return new;
end;
$$;
create trigger validate_household_document before insert or update on public.household_records for each row execute function private.validate_record_payload();
revoke execute on function private.validate_record_payload() from public,anon,authenticated;

alter table private.checkout_requests add column refunded_cents bigint not null default 0;
alter table public.service_quotes drop constraint service_quotes_status_check;
alter table public.service_quotes add check(status in ('quoted','checkout','paid','refunded','partially_refunded','cancelled'));
create function public.server_stripe_refund(p_event_id text,p_quote_id uuid,p_amount_cents bigint,p_refunded_cents bigint,p_currency text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare request private.checkout_requests; target text;
begin
  select * into request from private.checkout_requests where booking_id=p_quote_id for update;
  if request.id is null or request.status not in ('paid','partially_refunded','refunded') then raise exception 'Settled checkout not registered; retry event'; end if;
  if exists(select 1 from private.webhook_events where provider='stripe' and event_id=p_event_id) then return false; end if;
  if request.amount_cents<>p_amount_cents or lower(request.currency)<>lower(p_currency) or p_refunded_cents<0 or p_refunded_cents>p_amount_cents then raise exception 'Refund amount or currency mismatch'; end if;
  if p_refunded_cents>=request.refunded_cents then
    target:=case when p_refunded_cents=p_amount_cents then 'refunded' else 'partially_refunded' end;
    update private.checkout_requests set refunded_cents=p_refunded_cents,status=target where id=request.id;
    update public.service_quotes set status=target where id=request.booking_id;
  end if;
  insert into private.webhook_events(provider,event_id) values('stripe',p_event_id) on conflict do nothing;
  return true;
end;
$$;
revoke execute on function public.server_stripe_refund(text,uuid,bigint,bigint,text) from public,anon,authenticated;
grant execute on function public.server_stripe_refund(text,uuid,bigint,bigint,text) to service_role;
