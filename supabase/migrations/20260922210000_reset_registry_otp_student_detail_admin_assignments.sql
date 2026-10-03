-- COHT CBT: controlled test-data reset + registry detail + OTP + admin paper assignment/live-paper wiring.
-- This migration changes data through protected RPCs; it does not drop schema, RLS, or auth users for staff.

create table if not exists public.student_exam_otps (
  student_id uuid primary key references public.students(id) on delete cascade,
  current_otp text not null,
  otp_epoch bigint not null default 1,
  valid_for_date date not null default current_date,
  issued_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint student_exam_otps_format check (current_otp ~ '^[A-Z0-9]{6}$')
);
create index if not exists idx_student_exam_otps_valid_date on public.student_exam_otps(valid_for_date);
alter table public.student_exam_otps enable row level security;
revoke all on public.student_exam_otps from anon, authenticated;

create or replace function public.superadmin_list_student_departments()
returns table(id uuid, code text, name text)
language sql security definer stable set search_path=public
as $$
  select d.id, d.code, d.name
  from public.departments d
  where public.current_user_role()='superadmin' and d.is_active=true
  order by d.code;
$$;
revoke all on function public.superadmin_list_student_departments() from public;
grant execute on function public.superadmin_list_student_departments() to authenticated;

create or replace function public.superadmin_list_student_otps(p_department_id uuid default null, p_search text default null)
returns table(student_id uuid, full_name text, reg_no text, department_id uuid, department_code text, department_name text, level integer, current_otp text, otp_issued_at timestamptz, activated_courses jsonb)
language plpgsql security definer stable set search_path=public
as $$
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  return query
  select s.id,s.full_name,s.reg_no,d.id,d.code,d.name,s.level,coalesce(o.current_otp,''),o.issued_at,
    coalesce((select jsonb_agg(jsonb_build_object('code',x.code,'title',x.title) order by x.code) from (
      select distinct c.id,c.code,c.title from public.exams e
      join public.exam_courses ec on ec.exam_id=e.id
      join public.courses c on c.id=ec.course_id
      join public.student_course_registrations scr on scr.course_id=c.id and scr.student_id=s.id and scr.is_active=true and scr.academic_session_id=e.academic_session_id
      where e.is_active=true
    ) x),'[]'::jsonb)
  from public.students s
  join public.programmes p on p.id=s.programme_id
  join public.departments d on d.id=p.department_id
  left join public.student_exam_otps o on o.student_id=s.id
  where s.is_active=true
    and (p_department_id is null or d.id=p_department_id)
    and (nullif(trim(coalesce(p_search,'')),'') is null or lower(s.full_name) like '%'||lower(trim(p_search))||'%' or lower(s.reg_no) like '%'||lower(trim(p_search))||'%')
  order by d.code,s.full_name,s.reg_no;
end; $$;
revoke all on function public.superadmin_list_student_otps(uuid,text) from public;
grant execute on function public.superadmin_list_student_otps(uuid,text) to authenticated;

-- Full student drill-down: identity + academic placement + every active/inactive course registration.
create or replace function public.superadmin_get_student_detail(p_student_id uuid)
returns table(
  student_id uuid,
  full_name text,
  reg_no text,
  level integer,
  is_active boolean,
  programme_id uuid,
  programme_code text,
  programme_name text,
  department_id uuid,
  department_code text,
  department_name text,
  registrations jsonb
)
language plpgsql security definer stable set search_path=public
as $$
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  return query
  select s.id,s.full_name,s.reg_no,s.level,s.is_active,p.id,p.code,p.name,d.id,d.code,d.name,
    coalesce((select jsonb_agg(jsonb_build_object(
      'registration_id',scr.id,
      'course_id',c.id,
      'course_code',c.code,
      'course_title',c.title,
      'course_level',c.level,
      'semester',c.semester,
      'credit_units',c.credit_units,
      'academic_session_id',a.id,
      'academic_session_name',a.name,
      'registration_type',scr.registration_type,
      'is_active',scr.is_active
    ) order by a.name desc nulls last,c.code)
    from public.student_course_registrations scr
    join public.courses c on c.id=scr.course_id
    left join public.academic_sessions a on a.id=scr.academic_session_id
    where scr.student_id=s.id),'[]'::jsonb)
  from public.students s
  left join public.programmes p on p.id=s.programme_id
  left join public.departments d on d.id=p.department_id
  where s.id=p_student_id;
end; $$;
revoke all on function public.superadmin_get_student_detail(uuid) from public;
grant execute on function public.superadmin_get_student_detail(uuid) to authenticated;

-- Admin paper assignment management.
create table if not exists public.admin_paper_assignments (
    id uuid primary key default gen_random_uuid(),
    admin_id uuid not null references public.profiles(id) on delete cascade,
    exam_course_id uuid not null references public.exam_courses(id) on delete cascade,
    is_active boolean not null default true,
    assigned_at timestamptz not null default now(),
    assigned_by uuid references public.profiles(id) on delete set null,
    unique(admin_id, exam_course_id)
);
create index if not exists idx_admin_paper_assignments_admin on public.admin_paper_assignments(admin_id,is_active);
create index if not exists idx_admin_paper_assignments_paper on public.admin_paper_assignments(exam_course_id,is_active);
alter table public.admin_paper_assignments enable row level security;
revoke all on public.admin_paper_assignments from anon, authenticated;

create or replace function public.superadmin_list_admin_paper_assignments()
returns table(assignment_id uuid, admin_id uuid, admin_name text, admin_email text, exam_course_id uuid, exam_id uuid, exam_title text, course_code text, course_title text, is_active boolean, assigned_at timestamptz)
language plpgsql security definer stable set search_path=public
as $$
begin
 if public.current_user_role()<>'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
 return query
 select apa.id,p.id,coalesce(p.display_name,''),coalesce(u.email,''),ec.id,e.id,e.title,c.code,c.title,apa.is_active,apa.assigned_at
 from public.admin_paper_assignments apa
 join public.profiles p on p.id=apa.admin_id
 join auth.users u on u.id=p.id
 join public.exam_courses ec on ec.id=apa.exam_course_id
 join public.exams e on e.id=ec.exam_id
 join public.courses c on c.id=ec.course_id
 where p.role='admin'
 order by p.display_name,e.title,c.code;
end; $$;
revoke all on function public.superadmin_list_admin_paper_assignments() from public;
grant execute on function public.superadmin_list_admin_paper_assignments() to authenticated;

create or replace function public.superadmin_assign_admin_paper(p_admin_id uuid,p_exam_course_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare aid uuid;
begin
 if public.current_user_role()<>'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
 if not exists(select 1 from public.profiles where id=p_admin_id and role='admin' and is_active) then raise exception 'Active administrator account not found'; end if;
 if not exists(select 1 from public.exam_courses ec join public.exams e on e.id=ec.exam_id where ec.id=p_exam_course_id) then raise exception 'Examination paper not found'; end if;
 insert into public.admin_paper_assignments(admin_id,exam_course_id,is_active,assigned_by)
 values(p_admin_id,p_exam_course_id,true,auth.uid())
 on conflict(admin_id,exam_course_id) do update set is_active=true,assigned_by=auth.uid(),assigned_at=now()
 returning id into aid;
 return aid;
end; $$;
revoke all on function public.superadmin_assign_admin_paper(uuid,uuid) from public;
grant execute on function public.superadmin_assign_admin_paper(uuid,uuid) to authenticated;

create or replace function public.superadmin_unassign_admin_paper(p_assignment_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if public.current_user_role()<>'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
 update public.admin_paper_assignments set is_active=false where id=p_assignment_id;
 return found;
end; $$;
revoke all on function public.superadmin_unassign_admin_paper(uuid) from public;
grant execute on function public.superadmin_unassign_admin_paper(uuid) to authenticated;

-- A paper is visible to an Admin as a live paper only when the examination is active AND
-- that specific paper is actively assigned to the signed-in Admin.
create or replace function public.admin_list_assigned_papers()
returns table(paper_id uuid,exam_id uuid,title text,course_code text,department_id uuid,session_label text,starts_at timestamptz,candidate_count bigint,active_count bigint)
language plpgsql security definer set search_path=public as $$
begin
 if public.current_user_role()<>'admin' then raise exception 'Admin authorization required'; end if;
 return query
 select ec.id,e.id,e.title,c.code,c.department_id,coalesce(a.name,'')::text,null::timestamptz,
   count(distinct scr.student_id),
   count(distinct es.id) filter(where es.status in ('active','paused'))
 from public.admin_paper_assignments apa
 join public.exam_courses ec on ec.id=apa.exam_course_id
 join public.exams e on e.id=ec.exam_id
 join public.courses c on c.id=ec.course_id
 left join public.academic_sessions a on a.id=e.academic_session_id
 left join public.student_course_registrations scr on scr.course_id=ec.course_id and scr.is_active
 left join public.exam_sessions es on es.exam_id=e.id and es.student_id=scr.student_id
 where apa.admin_id=auth.uid() and apa.is_active and e.is_active
 group by ec.id,e.id,e.title,c.code,c.department_id,a.name
 order by e.title,c.code;
end; $$;
revoke all on function public.admin_list_assigned_papers() from public;
grant execute on function public.admin_list_assigned_papers() to authenticated;

-- Controlled full application-data reset for test/import preparation.
-- Staff Auth accounts and their profiles are preserved. Student Auth accounts are removed so
-- a fresh student import can recreate them without email conflicts. Schema/migrations remain intact.
create or replace function public.superadmin_reset_application_data()
returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  r record;
  preserved_count integer;
  student_auth_count integer := 0;
  tables_sql text;
begin
 if public.current_user_role()<>'superadmin' then raise exception 'SuperAdmin authorization required'; end if;

 create temporary table coht_preserved_staff on commit drop as
 select * from public.profiles where role in ('admin','superadmin');
 select count(*) into preserved_count from coht_preserved_staff;

 -- Remove student Auth accounts first. Their profiles cascade away; staff Auth accounts are untouched.
 delete from auth.users
 where id in (select id from public.profiles where role='student');
 get diagnostics student_auth_count = row_count;

 select string_agg(format('%I.%I', schemaname, tablename), ', ' order by tablename)
 into tables_sql
 from pg_tables
 where schemaname='public'
   and tablename not in ('spatial_ref_sys');

 if tables_sql is null then raise exception 'No application tables found'; end if;
 execute 'truncate table ' || tables_sql || ' cascade';

 -- Restore staff profiles after the application tables are empty.
 execute 'insert into public.profiles select * from coht_preserved_staff';

 return jsonb_build_object('status','reset','staff_profiles_preserved',preserved_count,'student_auth_accounts_removed',student_auth_count);
end; $$;
revoke all on function public.superadmin_reset_application_data() from public;
grant execute on function public.superadmin_reset_application_data() to authenticated;
