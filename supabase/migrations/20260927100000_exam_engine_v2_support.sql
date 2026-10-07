-- ============================================================
-- Exam engine v2 support: authoritative clock, deadline enforcement
-- on answer saving, and per-student paper listing.
-- ============================================================

-- Effective deadline for a paper/session: the stored deadline plus time
-- spent paused and any extension granted by an administrator. While a
-- session is paused the deadline moves forward with the wall clock, so the
-- candidate's time is frozen.
create or replace function public.exam_effective_expiry(
  p_exam_session_id uuid,
  p_exam_session_course_id uuid default null
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(esc.paper_expires_at, es.global_expires_at, es.started_at + make_interval(mins => e.duration_minutes))
         + make_interval(secs => (coalesce(es.total_paused_seconds, 0) + coalesce(es.total_extension_seconds, 0))::double precision)
         + case when es.status = 'paused' and es.paused_at is not null then now() - es.paused_at else interval '0' end
  from public.exam_sessions es
  join public.exams e on e.id = es.exam_id
  left join public.exam_session_courses esc
    on esc.id = p_exam_session_course_id and esc.exam_session_id = es.id
  where es.id = p_exam_session_id;
$$;

revoke all on function public.exam_effective_expiry(uuid, uuid) from public, anon, authenticated;

-- Server clock for the candidate's exam page. The client polls this, so
-- pauses, resumes and time extensions apply without a reload and the
-- device clock is never trusted.
create or replace function public.get_exam_clock_v2(p_exam_session_id uuid)
returns table(
  server_now timestamptz,
  expires_at timestamptz,
  session_status text,
  active_exam_session_course_id uuid
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_status text;
  v_active uuid;
begin
  v_student_id := public.current_student_id();
  if v_student_id is null then
    raise exception 'Student authorization required';
  end if;

  select es.status into v_status
  from public.exam_sessions es
  where es.id = p_exam_session_id and es.student_id = v_student_id;

  if not found then
    raise exception 'Exam session does not belong to this student';
  end if;

  select esc.id into v_active
  from public.exam_session_courses esc
  where esc.exam_session_id = p_exam_session_id and esc.status = 'active'
  order by esc.created_at
  limit 1;

  return query
  select now(), public.exam_effective_expiry(p_exam_session_id, v_active), v_status, v_active;
end;
$$;

-- Papers the signed-in student is registered for in an examination, with
-- their progress. Used to choose which paper to start or resume.
create or replace function public.list_my_exam_papers(p_exam_id uuid)
returns table(
  exam_course_id uuid,
  paper_order integer,
  course_code text,
  course_title text,
  paper_status text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
begin
  v_student_id := public.current_student_id();
  if v_student_id is null then
    raise exception 'Student authorization required';
  end if;

  return query
  select ec.id, ec.paper_order, c.code, c.title, coalesce(esc.status, 'not_started')
  from public.exam_courses ec
  join public.courses c on c.id = ec.course_id
  join public.student_course_registrations scr
    on scr.course_id = ec.course_id and scr.student_id = v_student_id and scr.is_active = true
  left join public.exam_sessions es
    on es.exam_id = ec.exam_id and es.student_id = v_student_id
  left join public.exam_session_courses esc
    on esc.exam_session_id = es.id and esc.exam_course_id = ec.id
  where ec.exam_id = p_exam_id
  order by ec.paper_order;
end;
$$;

-- Answer saving now refuses writes after the deadline (20 s grace for
-- network latency). Submission itself stays open so late submissions are
-- scored on whatever was saved in time.
create or replace function public.save_exam_answer_v2(
  p_exam_session_id uuid,
  p_exam_session_course_id uuid,
  p_question_id uuid,
  p_selected_option_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_exam_id uuid;
  v_exam_course_id uuid;
  v_paper_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_student_id := public.current_student_id();
  select es.exam_id, esc.exam_course_id into v_exam_id, v_exam_course_id
  from public.exam_sessions es join public.exam_session_courses esc on esc.exam_session_id=es.id
  where es.id=p_exam_session_id and esc.id=p_exam_session_course_id and es.student_id=v_student_id and es.status='active' and esc.status='active';
  if not found then raise exception 'Examination paper is not active or does not belong to this student'; end if;

  if now() > public.exam_effective_expiry(p_exam_session_id, p_exam_session_course_id) + interval '20 seconds' then
    raise exception 'Time is up for this examination paper';
  end if;

  select count(*) into v_paper_count from public.exam_courses where exam_id=v_exam_id;
  if not exists (
    select 1 from public.questions q
    where q.id=p_question_id and q.exam_id=v_exam_id
      and (q.exam_course_id=v_exam_course_id or (q.exam_course_id is null and v_paper_count=1))
  ) then raise exception 'Question does not belong to this examination paper'; end if;
  if not exists (select 1 from public.question_options where id=p_selected_option_id and question_id=p_question_id) then raise exception 'Selected option does not belong to this question'; end if;
  insert into public.answers(exam_session_id,question_id,selected_option_id,answered_at)
  values(p_exam_session_id,p_question_id,p_selected_option_id,now())
  on conflict(exam_session_id,question_id) do update set selected_option_id=excluded.selected_option_id,answered_at=excluded.answered_at,updated_at=now();
  return true;
end;
$$;

revoke all on function public.get_exam_clock_v2(uuid) from public, anon;
revoke all on function public.list_my_exam_papers(uuid) from public, anon;
grant execute on function public.get_exam_clock_v2(uuid) to authenticated;
grant execute on function public.list_my_exam_papers(uuid) to authenticated;

-- ------------------------------------------------------------
-- plpgsql name clash in the original v2 functions
-- ------------------------------------------------------------
-- These functions declare OUT columns (exam_session_id, exam_course_id, ...)
-- and also query tables with columns of the same names without qualifying
-- them, which PL/pgSQL rejects as ambiguous at run time. They only use
-- RETURN QUERY (never assign to the OUT names), so resolving ambiguous
-- names to columns is the correct and safe behaviour.
alter function public.start_exam_paper_v2(uuid, uuid) set plpgsql.variable_conflict = 'use_column';
alter function public.submit_exam_paper_v2(uuid, uuid) set plpgsql.variable_conflict = 'use_column';
alter function public.get_exam_session_state_v2(uuid) set plpgsql.variable_conflict = 'use_column';
alter function public.get_exam_questions_v2(uuid, uuid) set plpgsql.variable_conflict = 'use_column';
