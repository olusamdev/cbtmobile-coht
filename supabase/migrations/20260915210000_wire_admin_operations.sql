-- COHT CBT: privileged operational wiring
-- Attendance, admin paper assignments, supervisor alerts, intervention recovery,
-- security audit feed, system settings and safe administrative RPCs.

create table if not exists public.admin_paper_assignments (
    id uuid primary key default gen_random_uuid(),
    admin_id uuid not null references public.profiles(id) on delete cascade,
    exam_course_id uuid not null references public.exam_courses(id) on delete cascade,
    is_active boolean not null default true,
    assigned_at timestamptz not null default now(),
    assigned_by uuid references public.profiles(id) on delete set null,
    unique(admin_id, exam_course_id)
);

create index if not exists idx_admin_paper_assignments_admin on public.admin_paper_assignments(admin_id, is_active);
create index if not exists idx_admin_paper_assignments_paper on public.admin_paper_assignments(exam_course_id, is_active);

create table if not exists public.exam_attendance (
    id uuid primary key default gen_random_uuid(),
    exam_course_id uuid not null references public.exam_courses(id) on delete cascade,
    student_id uuid not null references public.students(id) on delete cascade,
    cleared_by uuid not null references public.profiles(id) on delete restrict,
    cleared_at timestamptz not null default now(),
    note text,
    unique(exam_course_id, student_id)
);

create index if not exists idx_exam_attendance_paper on public.exam_attendance(exam_course_id, cleared_at desc);

create table if not exists public.system_settings (
    key text primary key,
    value jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now(),
    updated_by uuid references public.profiles(id) on delete set null
);

insert into public.system_settings(key, value)
values
 ('exam_mode', '"regular"'::jsonb),
 ('instant_results', 'false'::jsonb)
on conflict (key) do nothing;

alter table public.admin_paper_assignments enable row level security;
alter table public.exam_attendance enable row level security;
alter table public.system_settings enable row level security;

-- No direct client policies: all privileged access goes through SECURITY DEFINER RPCs.

create or replace function public.admin_list_assigned_papers()
returns table(
    paper_id uuid,
    exam_id uuid,
    title text,
    course_code text,
    department_id uuid,
    session_label text,
    starts_at timestamptz,
    candidate_count bigint,
    active_count bigint
)
language plpgsql security definer set search_path=public
as $$
begin
    if public.current_user_role() <> 'admin' then raise exception 'Admin authorization required'; end if;
    return query
    select ec.id, e.id, e.title, c.code, c.department_id,
           coalesce(a.name, '')::text, null::timestamptz,
           count(distinct scr.student_id),
           count(distinct es.id) filter (where es.status in ('active','paused'))
    from admin_paper_assignments apa
    join exam_courses ec on ec.id=apa.exam_course_id
    join exams e on e.id=ec.exam_id
    join courses c on c.id=ec.course_id
    left join programmes p on p.id=c.programme_id
    left join academic_sessions a on a.id=e.academic_session_id
    left join student_course_registrations scr on scr.course_id=ec.course_id and scr.is_active
    left join exam_sessions es on es.exam_id=e.id and es.student_id=scr.student_id
    where apa.admin_id=auth.uid() and apa.is_active
    group by ec.id,e.id,e.title,c.code,p.department_id,a.label
    order by e.title,c.code;
end;
$$;

create or replace function public.admin_list_paper_candidates(p_exam_course_id uuid)
returns table(
    student_id uuid,
    full_name text,
    reg_no text,
    department_id uuid,
    programme text,
    level integer,
    attempt_id uuid,
    attempt_status text,
    strikes bigint,
    attendance_cleared boolean,
    attendance_at timestamptz,
    supervisor_flagged boolean
)
language plpgsql security definer set search_path=public
as $$
begin
    if public.current_user_role() <> 'admin' then raise exception 'Admin authorization required'; end if;
    if not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=p_exam_course_id and is_active) then raise exception 'Paper is not assigned to this admin'; end if;
    return query
    select s.id,s.full_name,s.reg_no,p.department_id,p.name,s.level,
           es.id,es.status,
           coalesce((select count(*) from strikes st where st.exam_session_id=es.id and st.cleared_at is null),0),
           exists(select 1 from exam_attendance ea where ea.exam_course_id=p_exam_course_id and ea.student_id=s.id),
           (select ea.cleared_at from exam_attendance ea where ea.exam_course_id=p_exam_course_id and ea.student_id=s.id),
           exists(select 1 from supervisor_alerts sa where sa.exam_session_id=es.id and sa.status='open')
    from exam_courses ec
    join student_course_registrations scr on scr.course_id=ec.course_id and scr.is_active
    join students s on s.id=scr.student_id and s.is_active
    left join programmes p on p.id=s.programme_id
    left join exams e on e.id=ec.exam_id
    left join exam_sessions es on es.exam_id=e.id and es.student_id=s.id
    where ec.id=p_exam_course_id
    order by s.reg_no;
end;
$$;

create or replace function public.admin_clear_student_into_paper(p_exam_course_id uuid,p_student_id uuid,p_note text default null)
returns boolean
language plpgsql security definer set search_path=public
as $$
begin
    if public.current_user_role() <> 'admin' then raise exception 'Admin authorization required'; end if;
    if not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=p_exam_course_id and is_active) then raise exception 'Paper is not assigned to this admin'; end if;
    if not exists(select 1 from exam_courses ec join student_course_registrations scr on scr.course_id=ec.course_id and scr.is_active where ec.id=p_exam_course_id and scr.student_id=p_student_id) then raise exception 'Student is not registered for this paper'; end if;
    insert into exam_attendance(exam_course_id,student_id,cleared_by,note) values(p_exam_course_id,p_student_id,auth.uid(),nullif(trim(p_note),''))
    on conflict(exam_course_id,student_id) do update set cleared_by=excluded.cleared_by,cleared_at=now(),note=excluded.note;
    return true;
end;
$$;

create or replace function public.admin_clear_all_attendance(p_exam_course_id uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
    if public.current_user_role() <> 'admin' then raise exception 'Admin authorization required'; end if;
    if not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=p_exam_course_id and is_active) then raise exception 'Paper is not assigned to this admin'; end if;
    delete from exam_attendance where exam_course_id=p_exam_course_id;
    get diagnostics n=row_count;
    insert into exam_session_events(exam_session_id,event_type,event_data,performed_by)
    select es.id,'ATTENDANCE_CLEARED_ALL',jsonb_build_object('paper_id',p_exam_course_id,'count',n),auth.uid()
    from exam_session_courses esc join exam_sessions es on es.id=esc.exam_session_id where esc.exam_course_id=p_exam_course_id;
    return n;
end;
$$;

create or replace function public.admin_flag_for_supervisor(p_exam_session_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare aid uuid;
begin
    if public.current_user_role() <> 'admin' then raise exception 'Admin authorization required'; end if;
    if nullif(trim(p_reason),'') is null then raise exception 'A reason is required'; end if;
    select sa.id into aid from supervisor_alerts sa where sa.exam_session_id=p_exam_session_id and sa.status='open' order by sa.created_at desc limit 1;
    if aid is null then
      insert into supervisor_alerts(exam_session_id,message) values(p_exam_session_id,trim(p_reason)) returning id into aid;
    else
      update supervisor_alerts set message=trim(p_reason) where id=aid;
    end if;
    insert into exam_session_events(exam_session_id,event_type,event_data,performed_by) values(p_exam_session_id,'SUPERVISOR_CALLED',jsonb_build_object('reason',trim(p_reason)),auth.uid());
    return aid;
end;
$$;

create or replace function public.admin_list_active_attempts()
returns table(
    attempt_id uuid, student_id uuid, student_name text, matric_number text,
    course_code text, exam_title text, status text, strikes bigint,
    supervisor_flagged boolean, last_event_at timestamptz
)
language plpgsql security definer set search_path=public
as $$
begin
    if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
    return query
    select es.id,s.id,s.full_name,s.reg_no,c.code,e.title,es.status,
      coalesce((select count(*) from strikes st where st.exam_session_id=es.id and st.cleared_at is null),0),
      exists(select 1 from supervisor_alerts sa where sa.exam_session_id=es.id and sa.status='open'),
      (select max(ev.created_at) from exam_session_events ev where ev.exam_session_id=es.id)
    from exam_sessions es join students s on s.id=es.student_id join exams e on e.id=es.exam_id
    left join exam_session_courses esc on esc.exam_session_id=es.id and esc.status='active'
    left join exam_courses ec on ec.id=esc.exam_course_id left join courses c on c.id=ec.course_id
    where es.status in ('active','paused')
      and (public.current_user_role()='superadmin' or exists(select 1 from admin_paper_assignments apa where apa.admin_id=auth.uid() and apa.exam_course_id=esc.exam_course_id and apa.is_active))
    order by (es.status='paused') desc, exists(select 1 from supervisor_alerts sa where sa.exam_session_id=es.id and sa.status='open') desc, strikes desc, es.updated_at;
end;
$$;

create or replace function public.supervision_list_security_events(p_department_id uuid default null,p_exam_id uuid default null,p_min_strike integer default 0)
returns table(id uuid,occurred_at timestamptz,attempt_id uuid,student_name text,matric_number text,course_code text,exam_title text,strike integer,event_type text,reason text,resulting_status text)
language plpgsql security definer set search_path=public
as $$
begin
    if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
    return query
    select ev.id,ev.created_at,ev.exam_session_id,s.full_name,s.reg_no,c.code,e.title,
      coalesce((ev.event_data->>'strike')::integer,0),ev.event_type,coalesce(ev.event_data->>'reason',''),es.status
    from exam_session_events ev join exam_sessions es on es.id=ev.exam_session_id join students s on s.id=es.student_id
    join exams e on e.id=es.exam_id left join exam_session_courses esc on esc.exam_session_id=es.id and esc.status in ('active','submitted')
    left join exam_courses ec on ec.id=esc.exam_course_id left join courses c on c.id=ec.course_id
    left join programmes p on p.id=s.programme_id
    where ev.event_type in ('STRIKE_ISSUED','SESSION_PAUSED','SESSION_RESUMED','SUPERVISOR_CALLED','FORCED_SUBMISSION','PAPER_WIPED','PAPER_CANCELLED')
      and (p_department_id is null or p.department_id=p_department_id)
      and (p_exam_id is null or es.exam_id=p_exam_id)
      and coalesce((ev.event_data->>'strike')::integer,0) >= coalesce(p_min_strike,0)
      and (public.current_user_role()='superadmin' or exists(select 1 from admin_paper_assignments apa where apa.admin_id=auth.uid() and apa.exam_course_id=esc.exam_course_id and apa.is_active))
    order by ev.created_at desc;
end;
$$;

create or replace function public.supervision_get_audit_trail(p_exam_session_id uuid)
returns table(id uuid,event_type text,event_data jsonb,performed_by uuid,created_at timestamptz)
language plpgsql security definer set search_path=public
as $$
begin
    if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
    if public.current_user_role()='admin' and not exists(select 1 from exam_session_courses esc join admin_paper_assignments apa on apa.exam_course_id=esc.exam_course_id where esc.exam_session_id=p_exam_session_id and apa.admin_id=auth.uid() and apa.is_active) then raise exception 'Attempt is outside your assignment'; end if;
    return query select id,event_type,event_data,performed_by,created_at from exam_session_events where exam_session_id=p_exam_session_id order by created_at;
end;
$$;

create or replace function public.admin_wipe_exam_paper(p_exam_session_id uuid,p_reason text)
returns boolean language plpgsql security definer set search_path=public as $$
declare sid uuid; paper uuid;
begin
    if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
    select es.id,esc.id into sid,paper from exam_sessions es join exam_session_courses esc on esc.exam_session_id=es.id where es.id=p_exam_session_id and esc.status='active' limit 1;
    if sid is null then raise exception 'Active examination paper not found'; end if;
    if public.current_user_role()='admin' and not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=(select exam_course_id from exam_session_courses where id=paper) and is_active) then raise exception 'Paper is outside your assignment'; end if;
    delete from answers where exam_session_id=sid;
    delete from strikes where exam_session_id=sid;
    update exam_sessions set status='active',paused_at=null,total_paused_seconds=0,updated_at=now() where id=sid;
    update exam_session_courses set status='active',started_at=now(),submitted_at=null where id=paper;
    insert into exam_session_events(exam_session_id,event_type,event_data,performed_by) values(sid,'PAPER_WIPED',jsonb_build_object('reason',nullif(trim(p_reason),'')),auth.uid());
    return true;
end;
$$;

create or replace function public.admin_cancel_exam_paper(p_exam_session_id uuid,p_reason text)
returns boolean language plpgsql security definer set search_path=public as $$
declare sid uuid; paper uuid;
begin
    if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
    select es.id,esc.id into sid,paper from exam_sessions es join exam_session_courses esc on esc.exam_session_id=es.id where es.id=p_exam_session_id limit 1;
    if sid is null then raise exception 'Examination paper not found'; end if;
    if public.current_user_role()='admin' and not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=(select exam_course_id from exam_session_courses where id=paper) and is_active) then raise exception 'Paper is outside your assignment'; end if;
    update exam_session_courses set status='submitted',submitted_at=now() where id=paper;
    update exam_sessions set status='submitted',submitted_at=now(),updated_at=now() where id=sid;
    insert into exam_session_events(exam_session_id,event_type,event_data,performed_by) values(sid,'PAPER_CANCELLED',jsonb_build_object('reason',nullif(trim(p_reason),''),'lockout_date',current_date),auth.uid());
    return true;
end;
$$;

create or replace function public.superadmin_clear_strikes(p_exam_session_id uuid,p_note text)
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
    if public.current_user_role() <> 'superadmin' then raise exception 'Superadmin authorization required'; end if;
    update strikes set cleared_at=now(),cleared_by=auth.uid(),clear_reason=trim(p_note) where exam_session_id=p_exam_session_id and cleared_at is null;
    get diagnostics n=row_count;
    insert into exam_session_events(exam_session_id,event_type,event_data,performed_by) values(p_exam_session_id,'STRIKES_CLEARED',jsonb_build_object('count',n,'reason',trim(p_note)),auth.uid());
    return n;
end;
$$;

create or replace function public.superadmin_set_exam_mode(p_mode text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
    if public.current_user_role() <> 'superadmin' then raise exception 'Superadmin authorization required'; end if;
    if p_mode not in ('regular','pharmacy-prenational','continuous') then raise exception 'Invalid examination mode'; end if;
    insert into system_settings(key,value,updated_at,updated_by) values('exam_mode',to_jsonb(p_mode),now(),auth.uid()) on conflict(key) do update set value=excluded.value,updated_at=now(),updated_by=auth.uid();
    return true;
end;
$$;

create or replace function public.superadmin_set_instant_results(p_enabled boolean)
returns boolean language plpgsql security definer set search_path=public as $$
begin
    if public.current_user_role() <> 'superadmin' then raise exception 'Superadmin authorization required'; end if;
    insert into system_settings(key,value,updated_at,updated_by) values('instant_results',to_jsonb(p_enabled),now(),auth.uid()) on conflict(key) do update set value=excluded.value,updated_at=now(),updated_by=auth.uid();
    return true;
end;
$$;

create or replace function public.superadmin_list_admins()
returns table(id uuid,full_name text,email text,active boolean,assigned_papers bigint,last_seen_at timestamptz)
language plpgsql security definer set search_path=public as $$
begin
    if public.current_user_role() <> 'superadmin' then raise exception 'Superadmin authorization required'; end if;
    return query
    select p.id,coalesce(p.display_name,'')::text,coalesce(u.email,'')::text,p.is_active,
      (select count(*) from admin_paper_assignments apa where apa.admin_id=p.id and apa.is_active),null::timestamptz
    from profiles p join auth.users u on u.id=p.id where p.role='admin' order by p.display_name;
end;
$$;

create or replace function public.superadmin_set_admin_active(p_admin_id uuid,p_active boolean)
returns boolean language plpgsql security definer set search_path=public as $$
begin
    if public.current_user_role() <> 'superadmin' then raise exception 'Superadmin authorization required'; end if;
    if not exists(select 1 from profiles where id=p_admin_id and role='admin') then raise exception 'Admin account not found'; end if;
    update profiles set is_active=p_active,updated_at=now() where id=p_admin_id;
    return true;
end;
$$;

-- Safe access for the frontend RPCs.
grant execute on function public.admin_list_assigned_papers() to authenticated;
grant execute on function public.admin_list_paper_candidates(uuid) to authenticated;
grant execute on function public.admin_clear_student_into_paper(uuid,uuid,text) to authenticated;
grant execute on function public.admin_clear_all_attendance(uuid) to authenticated;
grant execute on function public.admin_flag_for_supervisor(uuid,text) to authenticated;
grant execute on function public.admin_list_active_attempts() to authenticated;
grant execute on function public.supervision_list_security_events(uuid,uuid,integer) to authenticated;
grant execute on function public.supervision_get_audit_trail(uuid) to authenticated;
grant execute on function public.admin_wipe_exam_paper(uuid,text) to authenticated;
grant execute on function public.admin_cancel_exam_paper(uuid,text) to authenticated;
grant execute on function public.superadmin_clear_strikes(uuid,text) to authenticated;
grant execute on function public.superadmin_set_exam_mode(text) to authenticated;
grant execute on function public.superadmin_set_instant_results(boolean) to authenticated;
grant execute on function public.superadmin_list_admins() to authenticated;
grant execute on function public.superadmin_set_admin_active(uuid,boolean) to authenticated;

-- Scope existing intervention RPCs to the signed-in admin's assigned paper.
create or replace function public.admin_pause_exam_session_scoped(p_exam_session_id uuid,p_reason text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare paper uuid;
begin
  if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
  select esc.exam_course_id into paper from exam_session_courses esc where esc.exam_session_id=p_exam_session_id and esc.status='active' limit 1;
  if paper is null then raise exception 'Active examination paper not found'; end if;
  if public.current_user_role()='admin' and not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=paper and is_active) then raise exception 'Paper is outside your assignment'; end if;
  perform public.pause_exam_session(p_exam_session_id,p_reason);
  return true;
end;
$$;

create or replace function public.admin_resume_exam_session_scoped(p_exam_session_id uuid,p_reason text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare paper uuid;
begin
  if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
  select esc.exam_course_id into paper from exam_session_courses esc where esc.exam_session_id=p_exam_session_id and esc.status='active' limit 1;
  if paper is null then raise exception 'Active examination paper not found'; end if;
  if public.current_user_role()='admin' and not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=paper and is_active) then raise exception 'Paper is outside your assignment'; end if;
  perform public.resume_exam_session(p_exam_session_id,p_reason);
  return true;
end;
$$;

grant execute on function public.admin_pause_exam_session_scoped(uuid,text) to authenticated;
grant execute on function public.admin_resume_exam_session_scoped(uuid,text) to authenticated;

create or replace function public.admin_force_submit_exam_paper_scoped(p_exam_session_course_id uuid,p_reason text)
returns boolean language plpgsql security definer set search_path=public as $$
declare paper uuid;
begin
  if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
  select exam_course_id into paper from exam_session_courses where id=p_exam_session_course_id;
  if paper is null then raise exception 'Examination paper not found'; end if;
  if public.current_user_role()='admin' and not exists(select 1 from admin_paper_assignments where admin_id=auth.uid() and exam_course_id=paper and is_active) then raise exception 'Paper is outside your assignment'; end if;
  perform public.admin_force_submit_exam_paper(p_exam_session_course_id,p_reason);
  return true;
end;
$$;

grant execute on function public.admin_force_submit_exam_paper_scoped(uuid,text) to authenticated;
