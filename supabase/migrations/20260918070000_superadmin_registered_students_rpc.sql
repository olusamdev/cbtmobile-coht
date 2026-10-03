-- Authoritative SuperAdmin registry lookup.
-- Filters students through the real academic hierarchy:
-- students -> programmes -> departments.
-- This keeps department filtering server-side and independent of
-- PostgREST nested relationship response shape.

create or replace function public.superadmin_list_registered_students(
    p_department_id uuid default null
)
returns table (
    student_id uuid,
    reg_no text,
    full_name text,
    level integer,
    programme_id uuid,
    programme_name text,
    department_id uuid,
    department_code text,
    department_name text
)
language sql
stable
security definer
set search_path = public
as $$
    select
        s.id as student_id,
        s.reg_no,
        s.full_name,
        s.level,
        p.id as programme_id,
        p.name as programme_name,
        d.id as department_id,
        d.code as department_code,
        d.name as department_name
    from public.students as s
    left join public.programmes as p
        on p.id = s.programme_id
    left join public.departments as d
        on d.id = p.department_id
    where public.current_user_role() = 'superadmin'
      and s.is_active = true
      and (
          p_department_id is null
          or d.id = p_department_id
      )
    order by s.reg_no;
$$;

revoke all on function public.superadmin_list_registered_students(uuid) from public;
grant execute on function public.superadmin_list_registered_students(uuid) to authenticated;
