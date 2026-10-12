-- ============================================================
-- Add one student, and register a student for courses one by one
-- ============================================================
-- Imports remain available for bulk work; these cover single additions.

create or replace function public.superadmin_create_student(
  p_reg_no text,
  p_full_name text,
  p_programme_id uuid,
  p_level integer default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg text := nullif(trim(coalesce(p_reg_no, '')), '');
  v_name text := nullif(regexp_replace(trim(coalesce(p_full_name, '')), '\s+', ' ', 'g'), '');
  v_id uuid;
begin
  perform public.require_superadmin();

  if v_reg is null then raise exception 'Matriculation number is required.'; end if;
  -- The matric number becomes part of the student's sign-in address.
  if v_reg ~ '\s' then raise exception 'Matriculation number cannot contain spaces.'; end if;
  if v_name is null or length(v_name) < 2 then raise exception 'Enter the student''s full name.'; end if;
  if p_programme_id is null or not exists (select 1 from public.programmes where id = p_programme_id and is_active) then
    raise exception 'Choose an active programme (cadre).';
  end if;
  if p_level is not null and p_level <= 0 then raise exception 'Level must be a positive number.'; end if;
  if exists (select 1 from public.students where lower(reg_no) = lower(v_reg)) then
    raise exception 'A student with this registration number already exists.';
  end if;

  insert into public.students(reg_no, full_name, programme_id, level)
  values (v_reg, v_name, p_programme_id, p_level)
  returning id into v_id;

  return v_id;
end;
$$;

-- Courses a student can be registered for. By default only the student's own
-- department; the caller can widen it to every department (service courses).
create or replace function public.superadmin_list_courses_for_student(
  p_student_id uuid,
  p_academic_session_id uuid default null,
  p_all_departments boolean default false
) returns table(
  course_id uuid, code text, title text, level integer, semester integer, credit_units integer,
  department_code text, programme_code text, matches_programme boolean, already_registered boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_dept uuid;
  v_prog uuid;
  v_session uuid;
begin
  perform public.require_superadmin();

  select p.department_id, s.programme_id into v_dept, v_prog
  from public.students s left join public.programmes p on p.id = s.programme_id
  where s.id = p_student_id;
  if not found then raise exception 'Student not found.'; end if;
  if v_dept is null and not p_all_departments then
    raise exception 'This student has no department yet.';
  end if;

  v_session := coalesce(p_academic_session_id, (select s2.id from public.academic_sessions s2 where s2.is_current limit 1));

  return query
  select c.id, c.code, c.title, c.level, c.semester, c.credit_units, d.code, pr.code,
         (c.programme_id is not distinct from v_prog),
         exists (
           select 1 from public.student_course_registrations scr
           where scr.student_id = p_student_id and scr.course_id = c.id and scr.academic_session_id = v_session
         )
  from public.courses c
  left join public.departments d on d.id = c.department_id
  left join public.programmes pr on pr.id = c.programme_id
  where c.is_active and (p_all_departments or c.department_id = v_dept)
  order by (c.programme_id is not distinct from v_prog) desc, c.level nulls last, c.code;
end;
$$;

create or replace function public.superadmin_register_student_courses(
  p_student_id uuid,
  p_course_ids uuid[],
  p_academic_session_id uuid,
  p_registration_type text default 'regular'
) returns table(added integer, skipped integer)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_type text := lower(coalesce(nullif(trim(coalesce(p_registration_type, '')), ''), 'regular'));
  v_added integer;
  v_distinct integer;
begin
  perform public.require_superadmin();

  if not exists (select 1 from public.students where id = p_student_id and is_active) then
    raise exception 'Student not found or inactive.';
  end if;
  if v_type not in ('regular', 'resit', 'carry_over', 'special') then
    raise exception 'Registration type must be regular, resit, carry_over or special.';
  end if;
  if not exists (select 1 from public.academic_sessions where id = p_academic_session_id and is_active) then
    raise exception 'Choose an active academic session.';
  end if;
  if p_course_ids is null or cardinality(p_course_ids) = 0 then
    raise exception 'Select at least one course.';
  end if;
  if exists (
    select 1 from unnest(p_course_ids) x
    where not exists (select 1 from public.courses c where c.id = x and c.is_active)
  ) then
    raise exception 'One or more selected courses do not exist or are inactive.';
  end if;

  select count(distinct x) into v_distinct from unnest(p_course_ids) x;

  with ins as (
    insert into public.student_course_registrations(student_id, course_id, academic_session_id, registration_type)
    select distinct p_student_id, x, p_academic_session_id, v_type from unnest(p_course_ids) x
    on conflict (student_id, course_id, academic_session_id) do nothing
    returning 1
  )
  select count(*)::integer into v_added from ins;

  return query select v_added, v_distinct - v_added;
end;
$$;

revoke all on function public.superadmin_create_student(text, text, uuid, integer) from public, anon;
revoke all on function public.superadmin_list_courses_for_student(uuid, uuid, boolean) from public, anon;
revoke all on function public.superadmin_register_student_courses(uuid, uuid[], uuid, text) from public, anon;
grant execute on function public.superadmin_create_student(text, text, uuid, integer) to authenticated;
grant execute on function public.superadmin_list_courses_for_student(uuid, uuid, boolean) to authenticated;
grant execute on function public.superadmin_register_student_courses(uuid, uuid[], uuid, text) to authenticated;
