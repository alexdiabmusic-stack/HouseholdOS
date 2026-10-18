-- Shared records are versioned documents. All writes go through checked RPCs;
-- direct writes are denied, and private bank credentials live in a private schema.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  timezone text not null default 'America/Toronto',
  currency text not null default 'CAD' check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now()
);
create table public.household_members (
  household_id uuid not null references public.households on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 80),
  role text not null check (role in ('owner','member','child')),
  joined_at timestamptz not null default now(),
  primary key (household_id,user_id)
);
create table public.household_invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  token text not null unique default (replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')),
  invited_email text not null,
  role text not null default 'member' check (role in ('member','child')),
  created_by uuid not null references auth.users,
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_by uuid references auth.users,
  revoked_at timestamptz
);
create table public.household_records (
  id uuid primary key,
  household_id uuid not null references public.households on delete cascade,
  kind text not null check (kind in ('list','item','task','bill','asset')),
  payload jsonb not null,
  version bigint not null default 1,
  deleted boolean not null default false,
  updated_by uuid not null references auth.users,
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(payload) = 'object')
);
create index household_records_scope on public.household_records(household_id,updated_at,id);
create table public.household_activity (
  id bigint generated always as identity primary key,
  household_id uuid not null references public.households on delete cascade,
  record_id uuid,
  actor_id uuid references auth.users on delete set null,
  actor_name text not null,
  action text not null,
  title text not null,
  created_at timestamptz not null default now()
);
create index household_activity_scope on public.household_activity(household_id,id desc);
create table private.mutations (
  user_id uuid not null references auth.users on delete cascade,
  mutation_id uuid not null,
  household_id uuid not null references public.households on delete cascade,
  result jsonb not null,
  primary key(user_id,mutation_id)
);
create table private.bank_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  item_id text not null unique,
  access_token text not null,
  institution_name text not null,
  cursor text,
  created_at timestamptz not null default now()
);
create table public.bank_accounts (
  id text primary key,
  user_id uuid not null references auth.users on delete cascade,
  item_id uuid not null references private.bank_items on delete cascade,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);
create table public.bank_transactions (
  id text primary key,
  user_id uuid not null references auth.users on delete cascade,
  item_id uuid not null references private.bank_items on delete cascade,
  payload jsonb not null,
  updated_at timestamptz not null default now()
);
create table private.checkout_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  user_id uuid not null references auth.users,
  booking_id uuid not null unique,
  provider_account_id text not null,
  amount_cents bigint not null check (amount_cents > 0),
  currency text not null,
  stripe_session_id text unique,
  status text not null default 'requested',
  created_at timestamptz not null default now()
);
create table public.service_quotes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  provider_name text not null,
  stripe_account_id text not null,
  amount_cents bigint not null check (amount_cents between 1 and 10000000),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  description text not null,
  status text not null default 'quoted' check (status in ('quoted','checkout','paid','refunded','cancelled')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create table private.webhook_events (
  provider text not null,
  event_id text not null,
  processed_at timestamptz not null default now(),
  primary key(provider,event_id)
);

create function private.is_member(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.household_members m where m.household_id=h and m.user_id=auth.uid());
$$;
create function private.is_adult(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.household_members m where m.household_id=h and m.user_id=auth.uid() and m.role in ('owner','member'));
$$;
create function private.is_owner(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.household_members m where m.household_id=h and m.user_id=auth.uid() and m.role='owner');
$$;
grant usage on schema private to authenticated;
grant execute on function private.is_member(uuid),private.is_adult(uuid),private.is_owner(uuid) to authenticated;

alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_invites enable row level security;
alter table public.household_records enable row level security;
alter table public.household_activity enable row level security;
alter table public.bank_accounts enable row level security;
alter table public.bank_transactions enable row level security;
alter table public.service_quotes enable row level security;
create policy household_read on public.households for select to authenticated using (private.is_member(id));
create policy member_read on public.household_members for select to authenticated using (private.is_member(household_id));
create policy invite_read on public.household_invites for select to authenticated using (private.is_owner(household_id));
create policy record_read on public.household_records for select to authenticated using (private.is_member(household_id) and (kind <> 'bill' or private.is_adult(household_id)));
create policy activity_read on public.household_activity for select to authenticated using (private.is_adult(household_id));
create policy account_read on public.bank_accounts for select to authenticated using (user_id=auth.uid());
create policy transaction_read on public.bank_transactions for select to authenticated using (user_id=auth.uid());
create policy quote_read on public.service_quotes for select to authenticated using (private.is_adult(household_id));
revoke all on all tables in schema public from anon,authenticated;
grant select on public.households,public.household_members,public.household_invites,public.household_records,public.household_activity,public.bank_accounts,public.bank_transactions,public.service_quotes to authenticated;

create function public.create_household(p_name text,p_display_name text,p_timezone text default 'America/Toronto',p_currency text default 'CAD') returns public.households
language plpgsql security definer set search_path = '' as $$
declare h public.households;
begin
  perform 1 from auth.users where id=auth.uid() for update;
  if auth.uid() is null or not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email first'; end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then raise exception 'Unknown timezone'; end if;
  insert into public.households(name,timezone,currency) values(trim(p_name),p_timezone,p_currency) returning * into h;
  insert into public.household_members(household_id,user_id,display_name,role) values(h.id,auth.uid(),trim(p_display_name),'owner');
  return h;
end;
$$;

create function public.create_invite(p_household_id uuid,p_email text,p_role text default 'member') returns public.household_invites
language plpgsql security definer set search_path = '' as $$
declare i public.household_invites;
begin
  if not private.is_owner(p_household_id) then raise exception 'Only the household owner can invite members'; end if;
  if trim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'Enter a valid email'; end if;
  insert into public.household_invites(household_id,invited_email,role,created_by) values(p_household_id,lower(trim(p_email)),p_role,auth.uid()) returning * into i;
  return i;
end;
$$;
create function public.accept_invite(p_token text,p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare i public.household_invites; verified_email text;
begin
  select lower(email) into verified_email from auth.users where id=auth.uid() and email_confirmed_at is not null;
  if verified_email is null then raise exception 'Verify your email first'; end if;
  select * into i from public.household_invites where token=p_token for update;
  if i.id is null or i.revoked_at is not null or i.expires_at<=now() or i.invited_email<>verified_email then raise exception 'Invitation is invalid, expired, or addressed to another email'; end if;
  if i.accepted_by is not null and i.accepted_by<>auth.uid() then raise exception 'Invitation already used'; end if;
  insert into public.household_members(household_id,user_id,display_name,role) values(i.household_id,auth.uid(),trim(p_display_name),i.role) on conflict do nothing;
  update public.household_invites set accepted_by=auth.uid() where id=i.id;
  return i.household_id;
end;
$$;
create function public.revoke_invite(p_invite_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.household_invites where id=p_invite_id and private.is_owner(household_id)) then raise exception 'Only the owner can revoke invitations'; end if;
  update public.household_invites set revoked_at=now() where id=p_invite_id;
end;
$$;
create function public.remove_member(p_household_id uuid,p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.households where id=p_household_id for update;
  if auth.uid() is null or (auth.uid()<>p_user_id and not private.is_owner(p_household_id)) then raise exception 'Not authorized'; end if;
  if exists(select 1 from public.household_members where household_id=p_household_id and user_id=p_user_id and role='owner') then raise exception 'Transfer ownership before leaving'; end if;
  delete from public.household_members where household_id=p_household_id and user_id=p_user_id;
end;
$$;
create function public.transfer_ownership(p_household_id uuid,p_user_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from auth.users where id=p_user_id for update;
  perform 1 from public.households where id=p_household_id for update;
  if not private.is_owner(p_household_id) or not exists(select 1 from public.household_members where household_id=p_household_id and user_id=p_user_id and role='member') then raise exception 'Choose an adult member as the new owner'; end if;
  update public.household_members set role='member' where household_id=p_household_id and user_id=auth.uid();
  update public.household_members set role='owner' where household_id=p_household_id and user_id=p_user_id;
end;
$$;

create function private.next_due(p_date timestamptz,p_rule text,p_timezone text,p_anchor integer) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare local_date timestamp; target timestamp;
begin
  local_date := p_date at time zone p_timezone;
  if p_rule='daily' then return (local_date+interval '1 day') at time zone p_timezone;
  elsif p_rule='weekly' then return (local_date+interval '7 days') at time zone p_timezone;
  elsif p_rule='monthly' then
    target := date_trunc('month',local_date)+interval '1 month';
    return (target::date + local_date::time + (least(p_anchor,extract(day from target+interval '1 month -1 day')::int)-1)*interval '1 day') at time zone p_timezone;
  elsif p_rule='yearly' then return (local_date+interval '1 year') at time zone p_timezone;
  else return null;
  end if;
end;
$$;

create function public.mutate_record(p_id uuid,p_household_id uuid,p_kind text,p_payload jsonb,p_base_version bigint,p_deleted boolean,p_mutation_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare old public.household_records; saved public.household_records; prior jsonb; result jsonb; parent public.household_records; next_date timestamptz; next_payload jsonb; next_record public.household_records; actor text; tz text; next_id uuid; rotation jsonb; current_pos integer;
begin
  -- Serialize household mutations, including inserts, to close check/write races.
  select timezone into tz from public.households where id=p_household_id for update;
  if not private.is_member(p_household_id) then raise exception 'Household access denied'; end if;
  if p_kind='bill' and not private.is_adult(p_household_id) then raise exception 'Financial access denied'; end if;
  select m.result into prior from private.mutations m where m.user_id=auth.uid() and m.mutation_id=p_mutation_id and m.household_id=p_household_id;
  if prior is not null then return prior; end if;
  if p_kind not in ('list','item','task','bill','asset') or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>16384 then raise exception 'Invalid record'; end if;
  if length(trim(coalesce(p_payload->>'title',''))) not between 1 and 160 then raise exception 'Title must be 1 to 160 characters'; end if;
  if coalesce(p_payload->>'repeatRule','none') not in ('none','daily','weekly','monthly','yearly') then raise exception 'Invalid recurrence'; end if;
  if p_payload->>'dueAt' is not null then perform (p_payload->>'dueAt')::timestamptz; end if;
  if coalesce(p_payload->>'anchorDay','1')::int not between 1 and 31 then raise exception 'Invalid recurrence anchor'; end if;
  if p_payload->>'assigneeID' is not null and not exists(select 1 from public.household_members where household_id=p_household_id and user_id=(p_payload->>'assigneeID')::uuid) then raise exception 'Assignee must belong to this household'; end if;
  select * into old from public.household_records where id=p_id;
  if p_kind='bill' then
    if coalesce(p_payload->>'amountCents','0')::bigint not between 1 and 100000000 or coalesce(p_payload->>'currency','') !~ '^[A-Z]{3}$' then raise exception 'Invalid bill amount or currency'; end if;
    if p_payload->>'paidByID' is not null and (old.id is null or old.payload->>'paidByID' is distinct from p_payload->>'paidByID') and not exists(select 1 from public.household_members where household_id=p_household_id and user_id=(p_payload->>'paidByID')::uuid and role in ('owner','member')) then raise exception 'Invalid payer'; end if;
    if coalesce(p_payload->>'paid','false')::boolean and (p_payload->>'paidByID' is null or p_payload->>'paidAt' is null) then raise exception 'Record who paid and when'; end if;
    if coalesce(p_payload->>'paid','false')::boolean then perform (p_payload->>'paidAt')::timestamptz; end if;
  end if;
  select * into old from public.household_records where id=p_id;
  if old.id is not null and (old.household_id<>p_household_id or old.kind<>p_kind) then raise exception 'Record access denied'; end if;
  if (old.id is null and p_base_version<>0) or (old.id is not null and old.version<>p_base_version) then
    return jsonb_build_object('conflict',true,'record',case when old.id is null then null else to_jsonb(old) end);
  end if;
  if old.deleted and not p_deleted then raise exception 'Deleted records cannot be restored; add a new record'; end if;
  if p_kind='item' then
    select * into parent from public.household_records where id=(p_payload->>'parentID')::uuid;
    if parent.id is null or parent.kind<>'list' or parent.household_id<>p_household_id or parent.deleted then raise exception 'List no longer exists'; end if;
  end if;
  insert into public.household_records(id,household_id,kind,payload,version,deleted,updated_by)
    values(p_id,p_household_id,p_kind,p_payload,1,p_deleted,auth.uid())
    on conflict(id) do update set payload=excluded.payload,version=public.household_records.version+1,deleted=excluded.deleted,updated_by=auth.uid(),updated_at=now() returning * into saved;
  if p_deleted and p_kind='list' then
    update public.household_records set deleted=true,version=version+1,updated_by=auth.uid(),updated_at=now() where household_id=p_household_id and kind='item' and (payload->>'parentID')::uuid=p_id and not deleted;
  end if;
  select display_name into actor from public.household_members where household_id=p_household_id and user_id=auth.uid();
  insert into public.household_activity(household_id,record_id,actor_id,actor_name,action,title)
    values(p_household_id,p_id,auth.uid(),actor,case when p_deleted then 'deleted' when old.id is null then 'added' when p_kind='bill' and coalesce(p_payload->>'paid','false')='true' and coalesce(old.payload->>'paid','false')='false' then 'recorded payment for' when coalesce(p_payload->>'completed','false')='true' and coalesce(old.payload->>'completed','false')='false' then 'completed' else 'updated' end,p_payload->>'title');
  -- Completing a recurring occurrence creates the next exactly once. Reversing
  -- completion does not regenerate an existing next occurrence.
  if not p_deleted and p_kind in ('task','bill') and coalesce(p_payload->>'repeatRule','none')<>'none' and p_payload->>'dueAt' is not null and
    ((p_kind='task' and coalesce(p_payload->>'completed','false')='true' and coalesce(old.payload->>'completed','false')='false') or (p_kind='bill' and coalesce(p_payload->>'paid','false')='true' and coalesce(old.payload->>'paid','false')='false')) then
    select id into next_id from public.household_records where household_id=p_household_id and (payload->>'previousID')::uuid=p_id limit 1;
    if next_id is null then
      next_date := private.next_due((p_payload->>'dueAt')::timestamptz,p_payload->>'repeatRule',tz,coalesce((p_payload->>'anchorDay')::int,extract(day from (p_payload->>'dueAt')::timestamptz at time zone tz)::int));
      next_payload := (p_payload - 'paidByID' - 'paidAt' - 'completedAt') || jsonb_build_object('completed',false,'paid',false,'dueAt',to_char(next_date at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),'previousID',p_id);
      if jsonb_typeof(p_payload->'subtasks')='array' then
        next_payload:=jsonb_set(next_payload,'{subtasks}',(select coalesce(jsonb_agg(step || '{"completed":false}'::jsonb),'[]'::jsonb) from jsonb_array_elements(p_payload->'subtasks') step));
      end if;
      if jsonb_typeof(p_payload->'rotation')='array' then
        select coalesce(jsonb_agg(v order by ord),'[]'::jsonb) into rotation from jsonb_array_elements_text(p_payload->'rotation') with ordinality as r(v,ord) where exists(select 1 from public.household_members where household_id=p_household_id and user_id=r.v::uuid);
        if jsonb_array_length(rotation)>0 then
          select ord::integer-1 into current_pos from jsonb_array_elements_text(rotation) with ordinality as r(v,ord) where r.v::uuid=(p_payload->>'assigneeID')::uuid limit 1;
          next_payload:=jsonb_set(next_payload,'{assigneeID}',rotation->((coalesce(current_pos,-1)+1)%jsonb_array_length(rotation)));
          next_payload:=jsonb_set(next_payload,'{rotation}',rotation);
        end if;
      end if;
      if next_payload->>'assigneeID' is not null and not exists(select 1 from public.household_members where household_id=p_household_id and user_id=(next_payload->>'assigneeID')::uuid) then next_payload:=next_payload-'assigneeID'; end if;
      insert into public.household_records(id,household_id,kind,payload,updated_by) values(gen_random_uuid(),p_household_id,p_kind,next_payload,auth.uid()) returning * into next_record;
    end if;
  end if;
  result := jsonb_build_object('conflict',false,'record',to_jsonb(saved),'nextRecord',case when next_record.id is null then null else to_jsonb(next_record) end);
  insert into private.mutations(user_id,mutation_id,household_id,result) values(auth.uid(),p_mutation_id,p_household_id,result);
  return result;
end;
$$;

-- Security-definer functions must never inherit PostgreSQL's PUBLIC execute grant.
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on function public.create_household(text,text,text,text),public.create_invite(uuid,text,text),public.accept_invite(text,text),public.revoke_invite(uuid),public.remove_member(uuid,uuid),public.transfer_ownership(uuid,uuid),public.mutate_record(uuid,uuid,text,jsonb,bigint,boolean,uuid) to authenticated;
revoke execute on all functions in schema private from public,anon;
-- These helpers expose membership booleans only, never credentials or table writes.
grant execute on function private.is_member(uuid),private.is_adult(uuid),private.is_owner(uuid) to authenticated;

-- Edge functions run with a service role, using verified user IDs. Never expose
-- the private schema through PostgREST or grant it to application users.
grant usage on schema private to service_role;
grant all on all tables in schema private to service_role;
grant all on all tables in schema public to service_role;
grant usage,select on all sequences in schema public to service_role;
