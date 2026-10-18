create table private.subscription_grants (
  original_id text primary key,
  household_id uuid not null references public.households on delete cascade,
  product_id text not null,
  expires_at timestamptz not null,
  revoked boolean not null,
  signed_at timestamptz not null
);
grant all on private.subscription_grants to service_role;

create function public.household_entitlement(p_household_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare entitlement private.subscription_grants;
begin
  if not private.is_member(p_household_id) then raise exception 'Household access denied'; end if;
  select * into entitlement from private.subscription_grants where household_id=p_household_id and not revoked and expires_at>now() order by expires_at desc limit 1;
  return jsonb_build_object('active',entitlement.original_id is not null,'expiresAt',entitlement.expires_at,'productID',entitlement.product_id);
end;
$$;
create function public.server_store_entitlement(p_household_id uuid,p_original_id text,p_product_id text,p_expires_at timestamptz,p_revoked boolean,p_signed_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from private.subscription_grants where original_id=p_original_id and household_id<>p_household_id) then raise exception 'Subscription already belongs to a different household'; end if;
  insert into private.subscription_grants(original_id,household_id,product_id,expires_at,revoked,signed_at)
  values(p_original_id,p_household_id,p_product_id,p_expires_at,p_revoked,p_signed_at)
  on conflict(original_id) do update set product_id=excluded.product_id,expires_at=excluded.expires_at,revoked=excluded.revoked,signed_at=excluded.signed_at
    where excluded.signed_at>=private.subscription_grants.signed_at;
end;
$$;
revoke execute on function public.household_entitlement(uuid),public.server_store_entitlement(uuid,text,text,timestamptz,boolean,timestamptz) from public,anon,authenticated;
grant execute on function public.household_entitlement(uuid) to authenticated;
grant execute on function public.server_store_entitlement(uuid,text,text,timestamptz,boolean,timestamptz) to service_role;
