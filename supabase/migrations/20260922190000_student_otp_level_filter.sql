-- Add level to the SuperAdmin OTP lookup so OTP printing can be filtered by department + level.
drop function if exists public.superadmin_list_student_otps(uuid, text);

create function public.superadmin_list_student_otps(
  p_department_id uuid default null,
  p_search text default null
)
returns table(
  student_id uuid,
  full_name text,
  reg_no text,
  department_id uuid,
  department_code text,
  department_name text,
  level integer,
  current_otp text,
  otp_issued_at timestamptz,
  activated_courses jsonb
)
language plpgsql
security definer stable set search_path=public
as $$
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  return query
  select
    s.id,
    s.full_name,
    s.reg_no,
    d.id,
    d.code,
    d.name,
    s.level,
    coalesce(o.current_otp,''),
    o.issued_at,
    coalesce((
      select jsonb_agg(
        jsonb_build_object('code',x.code,'title',x.title)
        order by x.code
      )
      from (
        select distinct c.id,c.code,c.title
        from public.exams e
        join public.exam_courses ec on ec.exam_id=e.id
        join public.courses c on c.id=ec.course_id
        join public.student_course_registrations scr
          on scr.course_id=c.id
         and scr.student_id=s.id
         and scr.is_active=true
         and scr.academic_session_id=e.academic_session_id
        where e.is_active=true
      ) x
    ),'[]'::jsonb)
  from public.students s
  join public.programmes p on p.id=s.programme_id
  join public.departments d on d.id=p.department_id
  left join public.student_exam_otps o on o.student_id=s.id
  where s.is_active=true
    and (p_department_id is null or d.id=p_department_id)
    and (
      nullif(trim(coalesce(p_search,'')),'') is null
      or lower(s.full_name) like '%'||lower(trim(p_search))||'%'
      or lower(s.reg_no) like '%'||lower(trim(p_search))||'%'
    )
  order by d.code,s.full_name,s.reg_no;
end;
$$;

revoke all on function public.superadmin_list_student_otps(uuid,text) from public;
grant execute on function public.superadmin_list_student_otps(uuid,text) to authenticated;
