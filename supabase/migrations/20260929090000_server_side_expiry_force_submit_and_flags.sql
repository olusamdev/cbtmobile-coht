-- ============================================================
-- One authoritative scoring path, server-side expiry sweeper,
-- corrected admin force-submit, and persistent question flags.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Per-paper scoring (shared by every submission path)
-- ------------------------------------------------------------
-- Questions are matched to the paper through questions.exam_course_id, with a
-- single-paper exam falling back to questions that have no paper set.

create or replace function public.score_exam_paper(
  p_session public.exam_sessions,
  p_sc public.exam_session_courses,
  p_now timestamptz
)
returns public.exam_results
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total integer;
  v_correct integer;
  v_wrong integer;
  v_unanswered integer;
  v_result public.exam_results;
begin
  select count(*) into v_total
  from public.questions q
  where q.exam_id = p_session.exam_id
    and (q.exam_course_id = p_sc.exam_course_id
         or (q.exam_course_id is null
             and (select count(*) from public.exam_courses where exam_id = p_session.exam_id) = 1));

  if v_total = 0 then
    raise exception 'This examination paper contains no questions';
  end if;

  select count(*) filter (where qo.is_correct = true),
         count(*) filter (where qo.is_correct = false)
    into v_correct, v_wrong
  from public.questions q
  left join public.answers a on a.question_id = q.id and a.exam_session_id = p_session.id
  left join public.question_options qo on qo.id = a.selected_option_id and qo.question_id = q.id
  where q.exam_id = p_session.exam_id
    and (q.exam_course_id = p_sc.exam_course_id
         or (q.exam_course_id is null
             and (select count(*) from public.exam_courses where exam_id = p_session.exam_id) = 1))
    and a.selected_option_id is not null;

  v_unanswered := greatest(0, v_total - v_correct - v_wrong);

  insert into public.exam_results(
    exam_session_id, exam_session_course_id, student_id, exam_id,
    total_questions, answered_questions, correct_answers, wrong_answers, unanswered_questions,
    score, percentage, status, scored_at)
  values (
    p_session.id, p_sc.id, p_session.student_id, p_session.exam_id,
    v_total, v_correct + v_wrong, v_correct, v_wrong, v_unanswered,
    v_correct, round((v_correct::numeric / nullif(v_total, 0)) * 100, 2), 'final', p_now)
  on conflict (exam_session_course_id) do update
  set total_questions = excluded.total_questions,
      answered_questions = excluded.answered_questions,
      correct_answers = excluded.correct_answers,
      wrong_answers = excluded.wrong_answers,
      unanswered_questions = excluded.unanswered_questions,
      score = excluded.score,
      percentage = excluded.percentage,
      status = excluded.status,
      scored_at = excluded.scored_at
  returning * into v_result;

  update public.exam_session_courses
  set status = 'submitted', submitted_at = p_now, updated_at = p_now
  where id = p_sc.id;

  return v_result;
end;
$$;

revoke all on function public.score_exam_paper(public.exam_sessions, public.exam_session_courses, timestamptz)
  from public, anon, authenticated;

-- ------------------------------------------------------------
-- 2. Mode-aware finalisation without a signed-in student
-- ------------------------------------------------------------
-- Used by administrative force-submit and the expiry sweeper. Mirrors
-- submit_exam_paper_v2: Pharmacy PreNational scores every paper and ends the
-- sitting; Regular ends the session; Continuous ends it only once no other
-- registered paper is left.

create or replace function public.finalize_exam_papers(
  p_exam_session_id uuid,
  p_exam_session_course_id uuid
)
returns table(result_id uuid, all_submitted boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_session public.exam_sessions%rowtype;
  v_sc public.exam_session_courses%rowtype;
  v_exam public.exams%rowtype;
  v_ec public.exam_session_courses%rowtype;
  v_result public.exam_results%rowtype;
  v_selected public.exam_results%rowtype;
  v_day public.student_exam_day_sessions%rowtype;
  v_all boolean := false;
  v_now timestamptz := now();
begin
  select * into v_session from public.exam_sessions where id = p_exam_session_id for update;
  if not found then raise exception 'Examination session does not exist'; end if;

  select * into v_sc from public.exam_session_courses
  where id = p_exam_session_course_id and exam_session_id = p_exam_session_id for update;
  if not found then raise exception 'Examination paper session does not exist'; end if;

  select * into v_exam from public.exams where id = v_session.exam_id;

  if v_sc.status = 'submitted' then
    select * into v_selected from public.exam_results where exam_session_course_id = v_sc.id;
    if not found then raise exception 'Paper is marked submitted but no result exists'; end if;
    return query select v_selected.id,
      not exists (select 1 from public.exam_session_courses x where x.exam_session_id = v_session.id and x.status <> 'submitted');
    return;
  end if;

  if v_exam.mode <> 'pharmacy_prenational' and v_sc.status not in ('active', 'paused', 'submission_pending') then
    raise exception 'This examination paper cannot be submitted';
  end if;

  if v_exam.mode = 'pharmacy_prenational' then
    for v_ec in
      select * from public.exam_session_courses x
      where x.exam_session_id = v_session.id and x.status <> 'submitted'
      order by x.created_at
      for update
    loop
      v_result := public.score_exam_paper(v_session, v_ec, v_now);
      if v_ec.id = v_sc.id then v_selected := v_result; end if;
    end loop;
    v_all := true;
    update public.exam_sessions set status = 'submitted', submitted_at = v_now, updated_at = v_now where id = v_session.id;

  else
    v_selected := public.score_exam_paper(v_session, v_sc, v_now);

    if v_exam.mode = 'regular' then
      v_all := true;
      update public.exam_sessions set status = 'submitted', submitted_at = v_now, updated_at = v_now where id = v_session.id;
    else
      select * into v_day from public.student_exam_day_sessions
      where student_id = v_session.student_id and exam_date = current_date for update;

      if not exists (
        select 1 from public.exams e
        join public.exam_courses ec on ec.exam_id = e.id
        join public.student_course_registrations scr on scr.course_id = ec.course_id and scr.student_id = v_session.student_id
        where e.is_active = true and e.mode = 'continuous' and scr.is_active = true
          and not exists (
            select 1 from public.exam_session_courses esc2
            join public.exam_sessions es2 on es2.id = esc2.exam_session_id
            where es2.student_id = v_session.student_id and es2.exam_course_id = ec.id and esc2.status = 'submitted'
          )
      ) then
        v_all := true;
        update public.student_exam_day_sessions
        set status = 'ended', otp_rotation_required = true, otp_epoch = otp_epoch + 1, updated_at = v_now
        where id = v_day.id;
        update public.exam_sessions set status = 'submitted', submitted_at = v_now, updated_at = v_now where id = v_session.id;
      else
        update public.exam_sessions set status = 'active', submitted_at = null, updated_at = v_now where id = v_session.id;
      end if;
    end if;
  end if;

  return query select v_selected.id, v_all;
end;
$$;

revoke all on function public.finalize_exam_papers(uuid, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Administrative force-submit now uses the shared path
-- ------------------------------------------------------------
-- The previous version counted every question in the exam instead of the
-- paper's own, left exam_id unset on the result, and never ended the session.

create or replace function public.admin_force_submit_exam_paper(
  p_exam_session_course_id uuid,
  p_reason text
)
returns table (
  result_id uuid,
  exam_session_course_id uuid,
  score numeric,
  percentage numeric,
  correct_answers integer,
  wrong_answers integer,
  unanswered_questions integer,
  result_status text,
  submission_confirmed boolean
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_session_id uuid;
  v_result_id uuid;
  v_row public.exam_results%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if public.current_user_role() not in ('admin', 'superadmin') then
    raise exception 'Administrative authorization required';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required for force submission';
  end if;

  select esc.exam_session_id into v_session_id
  from public.exam_session_courses esc where esc.id = p_exam_session_course_id;
  if v_session_id is null then raise exception 'Examination paper session does not exist'; end if;

  select f.result_id into v_result_id from public.finalize_exam_papers(v_session_id, p_exam_session_course_id) f;
  select * into v_row from public.exam_results r where r.id = v_result_id;

  insert into public.exam_session_events(exam_session_id, event_type, event_data, performed_by)
  values (v_session_id, 'ADMIN_FORCE_SUBMISSION',
    jsonb_build_object('exam_session_course_id', p_exam_session_course_id, 'result_id', v_row.id,
                       'reason', p_reason, 'score', v_row.score, 'percentage', v_row.percentage),
    auth.uid());

  return query select v_row.id, v_row.exam_session_course_id, v_row.score, v_row.percentage,
    v_row.correct_answers, v_row.wrong_answers, v_row.unanswered_questions, v_row.status, true;
end;
$$;

-- ------------------------------------------------------------
-- 4. Expiry sweeper
-- ------------------------------------------------------------
-- Submits papers whose server deadline passed more than p_grace_seconds ago,
-- so a closed browser can never leave a paper open. Paused sessions are
-- skipped: their effective deadline keeps moving while paused.

create or replace function public.sweep_expired_exam_sessions(p_grace_seconds integer default 60)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select es.id as session_id, esc.id as course_id
    from public.exam_sessions es
    join lateral (
      select x.id
      from public.exam_session_courses x
      where x.exam_session_id = es.id and x.status in ('active', 'submission_pending')
      order by x.created_at
      limit 1
    ) esc on true
    where es.status = 'active'
      and public.exam_effective_expiry(es.id, esc.id) < now() - make_interval(secs => greatest(p_grace_seconds, 0))
  loop
    begin
      perform public.finalize_exam_papers(r.session_id, r.course_id);
      insert into public.exam_session_events(exam_session_id, event_type, event_data)
      values (r.session_id, 'AUTO_SUBMISSION_EXPIRED',
              jsonb_build_object('exam_session_course_id', r.course_id, 'reason', 'Time expired'));
      v_count := v_count + 1;
    exception when others then
      insert into public.exam_session_events(exam_session_id, event_type, event_data)
      values (r.session_id, 'AUTO_SUBMISSION_FAILED', jsonb_build_object('error', sqlerrm));
    end;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.sweep_expired_exam_sessions(integer) from public, anon, authenticated;
grant execute on function public.sweep_expired_exam_sessions(integer) to service_role;

-- Manual trigger for SuperAdmins (used when pg_cron is not enabled).
create or replace function public.superadmin_sweep_expired_exam_sessions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_superadmin();
  return public.sweep_expired_exam_sessions(60);
end;
$$;

revoke all on function public.superadmin_sweep_expired_exam_sessions() from public, anon;
grant execute on function public.superadmin_sweep_expired_exam_sessions() to authenticated;

-- Run every minute when pg_cron is available; otherwise the SuperAdmin monitor
-- calls the function above. Failure here must never fail the migration.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname = 'sweep-expired-exam-sessions';
    perform cron.schedule('sweep-expired-exam-sessions', '* * * * *', 'select public.sweep_expired_exam_sessions(60)');
  end if;
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end $$;

-- ------------------------------------------------------------
-- 5. Persistent question flags (flag for review)
-- ------------------------------------------------------------

create table if not exists public.exam_question_flags (
  exam_session_id uuid not null references public.exam_sessions(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (exam_session_id, question_id)
);

alter table public.exam_question_flags enable row level security;
revoke all on public.exam_question_flags from anon, authenticated;

create or replace function public.set_exam_question_flag(
  p_exam_session_id uuid, p_question_id uuid, p_flagged boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_status text;
begin
  select student_id into v_student_id
  from public.profiles where id = auth.uid() and role = 'student' and is_active = true;
  if v_student_id is null then raise exception 'Student authorization required'; end if;

  select es.status into v_status
  from public.exam_sessions es where es.id = p_exam_session_id and es.student_id = v_student_id;
  if v_status is null then raise exception 'Exam session does not exist'; end if;
  if v_status <> 'active' then raise exception 'Flags can only be changed while the paper is active'; end if;

  if not exists (
    select 1 from public.questions q
    join public.exam_sessions es on es.exam_id = q.exam_id
    where q.id = p_question_id and es.id = p_exam_session_id
  ) then
    raise exception 'Question does not belong to this examination';
  end if;

  if p_flagged then
    insert into public.exam_question_flags(exam_session_id, question_id)
    values (p_exam_session_id, p_question_id) on conflict do nothing;
  else
    delete from public.exam_question_flags
    where exam_session_id = p_exam_session_id and question_id = p_question_id;
  end if;
end;
$$;

create or replace function public.get_exam_flags(p_exam_session_id uuid)
returns table(question_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_student_id uuid;
begin
  select student_id into v_student_id
  from public.profiles where id = auth.uid() and role = 'student' and is_active = true;
  if v_student_id is null then raise exception 'Student authorization required'; end if;

  if not exists (select 1 from public.exam_sessions where id = p_exam_session_id and student_id = v_student_id) then
    raise exception 'Exam session does not exist';
  end if;

  return query
  select f.question_id from public.exam_question_flags f where f.exam_session_id = p_exam_session_id;
end;
$$;

revoke all on function public.set_exam_question_flag(uuid, uuid, boolean) from public, anon;
revoke all on function public.get_exam_flags(uuid) from public, anon;
grant execute on function public.set_exam_question_flag(uuid, uuid, boolean) to authenticated;
grant execute on function public.get_exam_flags(uuid) to authenticated;
