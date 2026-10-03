-- Expose active courses to the SuperAdmin examination setup
-- without weakening RLS on the courses table.

create or replace function public.superadmin_list_active_courses()
returns table (
  id uuid,
  code text,
  title text,
  level text,
  semester text,
  department_id uuid,
  programme_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role = 'superadmin'
      and p.is_active = true
  ) then
    raise exception 'SuperAdmin authorization required.';
  end if;

  return query
  select
    c.id,
    c.code,
    c.title,
    c.level,
    c.semester,
    c.department_id,
    c.programme_id
  from public.courses c
  where c.is_active = true
  order by c.code;
end;
$$;

revoke all on function public.superadmin_list_active_courses() from public;
grant execute on function public.superadmin_list_active_courses() to authenticated;
