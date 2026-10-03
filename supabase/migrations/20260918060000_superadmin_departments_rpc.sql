-- SuperAdmin-only authoritative department lookup.
-- The frontend must not depend on direct table access for this selector.
-- SECURITY DEFINER lets the function read the academic foundation safely,
-- while current_user_role() restricts execution to an active SuperAdmin.

create or replace function public.superadmin_list_departments()
returns table (
    id uuid,
    code text,
    name text
)
language sql
stable
security definer
set search_path = public
as $$
    select d.id, d.code, d.name
    from public.departments as d
    where public.current_user_role() = 'superadmin'
    order by d.name;
$$;

revoke all on function public.superadmin_list_departments() from public;
grant execute on function public.superadmin_list_departments() to authenticated;
