-- Supabase creates this publication. Local PostgreSQL tests may omit it.
do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.household_records,public.household_members;
  end if;
end;
$$;
