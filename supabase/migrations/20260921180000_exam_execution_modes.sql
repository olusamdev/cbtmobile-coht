-- COHT CBT: execution semantics for Regular, Pharmacy PreNational and Continuous.
-- This migration is additive and keeps existing RPCs intact while introducing
-- mode-aware, paper-aware execution primitives.

alter table public.exam_sessions
  add column if not exists global_expires_at timestamptz;

alter table public.exam_session_courses
  add column if not exists paper_expires_at timestamptz;

alter table public.questions
  add column if not exists exam_course_id uuid references public.exam_courses(id) on delete cascade;

create index if not exists idx_questions_exam_course_id
  on public.questions(exam_course_id);

-- Existing single-paper examinations remain fully compatible: their questions
-- are automatically attached to their only paper. Multi-paper questions are
-- intentionally left unmapped until the SuperAdmin assigns a paper.
update public.questions q
set exam_course_id = x.exam_course_id
from (
  select ec.exam_id, ec.id as exam_course_id
  from public.exam_courses ec
  where not exists (
    select 1
    from public.exam_courses ec2
    where ec2.exam_id = ec.exam_id
      and ec2.id <> ec.id
  )
) x
where q.exam_id = x.exam_id
  and q.exam_course_id is null;

create table if not exists public.student_exam_day_sessions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete restrict,
  exam_date date not null default current_date,
  status text not null default 'active'
    check (status in ('active','ended','locked')),
  otp_epoch bigint not null default 1,
  otp_rotation_required boolean not null default false,
  last_exam_session_id uuid references public.exam_sessions(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(student_id, exam_date)
);

create index if not exists idx_student_exam_day_sessions_student_date
  on public.student_exam_day_sessions(student_id, exam_date);

-- ------------------------------------------------------------
-- START / SWITCH PAPER
-- ------------------------------------------------------------
create or replace function public.start_exam_paper_v2(
  p_exam_id uuid,
  p_exam_course_id uuid
)
returns table (
  exam_session_id uuid,
  exam_session_course_id uuid,
  mode text,
  paper_status text,
  session_status text,
  started_at timestamptz,
  paper_expires_at timestamptz,
  global_expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_exam public.exams%rowtype;
  v_ec public.exam_courses%rowtype;
  v_session public.exam_sessions%rowtype;
  v_sc public.exam_session_courses%rowtype;
  v_day public.student_exam_day_sessions%rowtype;
  v_now timestamptz := now();
  v_paper_deadline timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_student_id := public.current_student_id();
  if v_student_id is null then raise exception 'Authenticated user is not an active student'; end if;

  select * into v_exam from public.exams
  where id = p_exam_id and is_active = true;
  if not found then raise exception 'Exam is not active or does not exist'; end if;

  select * into v_ec from public.exam_courses
  where id = p_exam_course_id and exam_id = p_exam_id;
  if not found then raise exception 'Exam paper does not belong to this examination'; end if;

  if not exists (
    select 1 from public.student_course_registrations scr
    where scr.student_id = v_student_id and scr.course_id = v_ec.course_id and scr.is_active = true
  ) then raise exception 'Student is not registered for this course'; end if;

  if v_exam.mode = 'continuous' then
    insert into public.student_exam_day_sessions(student_id, exam_date, status)
    values (v_student_id, current_date, 'active')
    on conflict (student_id, exam_date) do update set status = 'active', updated_at = now()
    returning * into v_day;

    if v_day.otp_rotation_required then
      raise exception 'This student examination day has ended; a new OTP is required';
    end if;

    if exists (
      select 1 from public.exam_session_courses esc
      join public.exam_sessions es on es.id = esc.exam_session_id
      where es.student_id = v_student_id
        and esc.status = 'active'
        and es.status in ('active','paused','submission_pending')
    ) then
      raise exception 'Finish the current paper before starting another paper';
    end if;
  end if;

  select * into v_session
  from public.exam_sessions
  where exam_id = p_exam_id and student_id = v_student_id
  for update;

  if not found then
    insert into public.exam_sessions(exam_id, student_id, status, started_at, global_expires_at)
    values (
      p_exam_id,
      v_student_id,
      'active',
      v_now,
      case when v_exam.mode = 'pharmacy_prenational' then v_now + make_interval(mins => v_exam.duration_minutes) else null end
    ) returning * into v_session;
  elsif v_session.status = 'submitted' then
    raise exception 'This examination session has already been submitted';
  end if;

  if v_exam.mode = 'pharmacy_prenational' then
    -- Pharmacy: create every paper in the session up front. They are all
    -- available concurrently and share the one global deadline.
    insert into public.exam_session_courses(exam_session_id, exam_course_id, status)
    select v_session.id, ec.id, case when ec.id = p_exam_course_id then 'active' else 'available' end
    from public.exam_courses ec
    where ec.exam_id = p_exam_id
    on conflict (exam_session_id, exam_course_id) do update
      set status = case when exam_session_courses.status = 'submitted' then 'submitted'
                        when excluded.exam_course_id = p_exam_course_id then 'active'
                        else 'available' end,
          updated_at = now();

    select * into v_sc from public.exam_session_courses
    where exam_session_id = v_session.id and exam_course_id = p_exam_course_id
    for update;

    update public.exam_session_courses
    set status = case when id = v_sc.id then 'active' when status <> 'submitted' then 'available' else status end,
        updated_at = now()
    where exam_session_id = v_session.id;

    return query select v_session.id, v_sc.id, v_exam.mode, v_sc.status, v_session.status,
      v_session.started_at, null::timestamptz, v_session.global_expires_at;
    return;
  end if;

  -- Regular / Continuous: one active paper with its own deadline.
  select * into v_sc
  from public.exam_session_courses
  where exam_session_id = v_session.id and exam_course_id = p_exam_course_id
  for update;

  if not found then
    v_paper_deadline := v_now + make_interval(mins => v_exam.duration_minutes);
    insert into public.exam_session_courses(exam_session_id, exam_course_id, status, started_at, paper_expires_at)
    values (v_session.id, p_exam_course_id, 'active', v_now, v_paper_deadline)
    returning * into v_sc;
  elsif v_sc.status = 'submitted' then
    raise exception 'This examination paper has already been submitted';
  else
    v_paper_deadline := coalesce(v_sc.paper_expires_at, v_now + make_interval(mins => v_exam.duration_minutes));
    update public.exam_session_courses set status='active', started_at=coalesce(started_at,v_now), paper_expires_at=v_paper_deadline, updated_at=now()
    where id=v_sc.id returning * into v_sc;
  end if;

  if v_exam.mode = 'continuous' then
    update public.student_exam_day_sessions
    set last_exam_session_id = v_session.id, updated_at = now()
    where id = v_day.id;
  end if;

  return query select v_session.id, v_sc.id, v_exam.mode, v_sc.status, v_session.status,
    v_session.started_at, v_sc.paper_expires_at, v_session.global_expires_at;
end;
$$;

-- ------------------------------------------------------------
-- SAFE PAPER-AWARE QUESTION DELIVERY
-- ------------------------------------------------------------
create or replace function public.get_exam_questions_v2(
  p_exam_session_id uuid,
  p_exam_session_course_id uuid
)
returns table (
  question_id uuid,
  question_number integer,
  question_text text,
  option_id uuid,
  option_key text,
  option_text text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_exam_id uuid;
  v_exam_course_id uuid;
  v_exam_mode text;
  v_paper_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_student_id := public.current_student_id();

  select es.exam_id, esc.exam_course_id
    into v_exam_id, v_exam_course_id
  from public.exam_sessions es
  join public.exam_session_courses esc on esc.exam_session_id = es.id
  where es.id = p_exam_session_id and esc.id = p_exam_session_course_id and es.student_id = v_student_id;
  if not found then raise exception 'Examination paper session does not belong to this student'; end if;

  select mode into v_exam_mode from public.exams where id=v_exam_id;
  select count(*) into v_paper_count from public.exam_courses where exam_id=v_exam_id;

  return query
  select q.id, q.question_number, q.question_text, qo.id, qo.option_key, qo.option_text
  from public.questions q
  join public.question_options qo on qo.question_id=q.id
  where q.exam_id=v_exam_id
    and (
      q.exam_course_id = v_exam_course_id
      or (q.exam_course_id is null and v_paper_count = 1)
    )
  order by q.question_number, qo.option_key;
end;
$$;

-- Existing answer saving remains compatible, but v2 prevents a question from
-- another paper being answered in a multi-paper examination.
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

-- ------------------------------------------------------------
-- MODE-AWARE SUBMISSION
-- ------------------------------------------------------------
create or replace function public.submit_exam_paper_v2(
  p_exam_session_course_id uuid,
  p_submission_request_id uuid
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
  submission_confirmed boolean,
  mode text,
  all_papers_submitted boolean,
  otp_rotation_required boolean,
  next_exam_session_course_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_sc public.exam_session_courses%rowtype;
  v_session public.exam_sessions%rowtype;
  v_exam public.exams%rowtype;
  v_ec record;
  v_total integer;
  v_correct integer;
  v_wrong integer;
  v_unanswered integer;
  v_result public.exam_results%rowtype;
  v_selected_result public.exam_results%rowtype;
  v_now timestamptz := now();
  v_rotate boolean := false;
  v_all boolean := false;
  v_next uuid;
  v_day public.student_exam_day_sessions%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_student_id := public.current_student_id();

  select * into v_sc from public.exam_session_courses where id=p_exam_session_course_id for update;
  if not found then raise exception 'Examination paper session does not exist'; end if;
  select * into v_session from public.exam_sessions where id=v_sc.exam_session_id for update;
  if not found or v_session.student_id<>v_student_id then raise exception 'This examination session does not belong to you'; end if;
  select * into v_exam from public.exams where id=v_session.exam_id;

  if v_sc.status='submitted' then
    select * into v_selected_result from public.exam_results where exam_session_course_id=v_sc.id;
    if not found then raise exception 'Paper is marked submitted but no result exists'; end if;
    return query select v_selected_result.id,v_selected_result.exam_session_course_id,v_selected_result.score,v_selected_result.percentage,
      v_selected_result.correct_answers,v_selected_result.wrong_answers,v_selected_result.unanswered_questions,v_selected_result.status,true,
      v_exam.mode,(not exists(select 1 from public.exam_session_courses where exam_session_id=v_session.id and status<>'submitted')),
      false,null::uuid;
    return;
  end if;

  if v_exam.mode <> 'pharmacy_prenational' and v_sc.status <> 'active' then
    raise exception 'This examination paper cannot currently be submitted';
  end if;

  -- Pharmacy is one atomic sitting: score every paper in the same transaction.
  -- Regular/Continuous score only the requested paper.
  if v_exam.mode='pharmacy_prenational' then
    for v_ec in
      select esc.*
      from public.exam_session_courses esc
      where esc.exam_session_id=v_session.id and esc.status<>'submitted'
      order by esc.created_at
      for update
    loop
      select count(*) into v_total
      from public.questions q
      where q.exam_id=v_session.exam_id
        and (q.exam_course_id=v_ec.exam_course_id
             or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1));
      if v_total=0 then raise exception 'A Pharmacy paper has no questions assigned to it'; end if;

      select count(*) filter(where qo.is_correct=true), count(*) filter(where qo.is_correct=false)
        into v_correct,v_wrong
      from public.questions q
      left join public.answers a on a.question_id=q.id and a.exam_session_id=v_session.id
      left join public.question_options qo on qo.id=a.selected_option_id and qo.question_id=q.id
      where q.exam_id=v_session.exam_id
        and (q.exam_course_id=v_ec.exam_course_id
             or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1))
        and a.selected_option_id is not null;

      v_unanswered := greatest(0,v_total-v_correct-v_wrong);
      insert into public.exam_results(exam_session_id,exam_session_course_id,student_id,exam_id,total_questions,answered_questions,correct_answers,wrong_answers,unanswered_questions,score,percentage,status,scored_at)
      values(v_session.id,v_ec.id,v_student_id,v_session.exam_id,v_total,v_correct+v_wrong,v_correct,v_wrong,v_unanswered,v_correct,round((v_correct::numeric/nullif(v_total,0))*100,2),'final',v_now)
      on conflict(exam_session_course_id) do update set total_questions=excluded.total_questions,answered_questions=excluded.answered_questions,correct_answers=excluded.correct_answers,wrong_answers=excluded.wrong_answers,unanswered_questions=excluded.unanswered_questions,score=excluded.score,percentage=excluded.percentage,status='final',scored_at=v_now
      returning * into v_result;

      update public.exam_session_courses set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_ec.id;
      if v_ec.id=v_sc.id then v_selected_result:=v_result; end if;
    end loop;
    v_all := true;
    v_rotate := true;
    update public.exam_sessions set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_session.id;

  else
    select count(*) into v_total from public.questions q
    where q.exam_id=v_session.exam_id
      and (q.exam_course_id=v_sc.exam_course_id
           or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1));
    if v_total=0 then raise exception 'This examination paper contains no questions'; end if;

    select count(*) filter(where qo.is_correct=true), count(*) filter(where qo.is_correct=false)
      into v_correct,v_wrong
    from public.questions q
    left join public.answers a on a.question_id=q.id and a.exam_session_id=v_session.id
    left join public.question_options qo on qo.id=a.selected_option_id and qo.question_id=q.id
    where q.exam_id=v_session.exam_id
      and (q.exam_course_id=v_sc.exam_course_id
           or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1))
      and a.selected_option_id is not null;

    v_unanswered := greatest(0,v_total-v_correct-v_wrong);
    insert into public.exam_results(exam_session_id,exam_session_course_id,student_id,exam_id,total_questions,answered_questions,correct_answers,wrong_answers,unanswered_questions,score,percentage,status,scored_at)
    values(v_session.id,v_sc.id,v_student_id,v_session.exam_id,v_total,v_correct+v_wrong,v_correct,v_wrong,v_unanswered,v_correct,round((v_correct::numeric/nullif(v_total,0))*100,2),'final',v_now)
    on conflict(exam_session_course_id) do update set total_questions=excluded.total_questions,answered_questions=excluded.answered_questions,correct_answers=excluded.correct_answers,wrong_answers=excluded.wrong_answers,unanswered_questions=excluded.unanswered_questions,score=excluded.score,percentage=excluded.percentage,status='final',scored_at=v_now
    returning * into v_selected_result;
    update public.exam_session_courses set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_sc.id;

    if v_exam.mode='regular' then
      v_all := true;
      v_rotate := true;
      update public.exam_sessions set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_session.id;
    else
      select * into v_day from public.student_exam_day_sessions where student_id=v_student_id and exam_date=current_date for update;
      if not exists (
        select 1 from public.exams e
        join public.exam_courses ec on ec.exam_id=e.id
        join public.student_course_registrations scr on scr.course_id=ec.course_id and scr.student_id=v_student_id
        where e.is_active=true and e.mode='continuous' and scr.is_active=true
          and not exists (
            select 1 from public.exam_session_courses esc2
            join public.exam_sessions es2 on es2.id=esc2.exam_session_id
            where es2.student_id=v_student_id and es2.exam_course_id=ec.id and esc2.status='submitted'
          )
      ) then
        v_all := true;
        v_rotate := true;
        update public.student_exam_day_sessions set status='ended',otp_rotation_required=true,otp_epoch=otp_epoch+1,updated_at=v_now where id=v_day.id;
        update public.exam_sessions set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_session.id;
      else
        v_all := false;
        update public.exam_sessions set status='active',submitted_at=null,updated_at=v_now where id=v_session.id;
        select esc2.id into v_next
        from public.exam_session_courses esc2
        where esc2.exam_session_id=v_session.id and esc2.status<>'submitted'
        order by esc2.created_at limit 1;
      end if;
    end if;
  end if;

  return query select v_selected_result.id,v_selected_result.exam_session_course_id,v_selected_result.score,v_selected_result.percentage,
    v_selected_result.correct_answers,v_selected_result.wrong_answers,v_selected_result.unanswered_questions,v_selected_result.status,true,
    v_exam.mode,v_all,v_rotate,v_next;
end;
$$;

revoke all on function public.start_exam_paper_v2(uuid,uuid) from public;
revoke all on function public.get_exam_questions_v2(uuid,uuid) from public;
revoke all on function public.save_exam_answer_v2(uuid,uuid,uuid,uuid) from public;
revoke all on function public.submit_exam_paper_v2(uuid,uuid) from public;
grant execute on function public.start_exam_paper_v2(uuid,uuid) to authenticated;
grant execute on function public.get_exam_questions_v2(uuid,uuid) to authenticated;
grant execute on function public.save_exam_answer_v2(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.submit_exam_paper_v2(uuid,uuid) to authenticated;

-- ------------------------------------------------------------
-- PAPER-SPECIFIC QUESTION IMPORT
-- ------------------------------------------------------------
alter table public.questions drop constraint if exists questions_exam_id_question_number_key;
create unique index if not exists uq_questions_exam_paper_number
  on public.questions(exam_id, exam_course_id, question_number)
  where exam_course_id is not null;
create unique index if not exists uq_questions_exam_legacy_number
  on public.questions(exam_id, question_number)
  where exam_course_id is null;

create or replace function public.superadmin_validate_question_import_v2(p_rows jsonb)
returns table(row_number integer, status text, message text)
language plpgsql
security definer
set search_path=public
as $$
declare
  r jsonb;
  i integer := 0;
  v_exam uuid;
  v_paper uuid;
  v_mode text;
  v_papers integer;
  v_correct text;
  v_qn integer;
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  for r in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    i := i + 1;
    begin
      v_exam := (r->>'exam_id')::uuid;
      v_paper := nullif(r->>'exam_course_id','')::uuid;
      v_qn := nullif(r->>'question_number','')::integer;
      v_correct := upper(trim(r->>'correct_option'));
      select mode into v_mode from public.exams where id=v_exam and is_active=false;
      if v_mode is null then raise exception 'Examination does not exist or is already active'; end if;
      select count(*) into v_papers from public.exam_courses where exam_id=v_exam;
      if v_paper is null and v_papers=1 then select id into v_paper from public.exam_courses where exam_id=v_exam limit 1; end if;
      if v_paper is null then raise exception 'Select a specific paper for this multi-paper examination'; end if;
      if not exists(select 1 from public.exam_courses where id=v_paper and exam_id=v_exam) then raise exception 'Selected paper does not belong to the examination'; end if;
      if v_qn is null or v_qn <= 0 then raise exception 'Question number must be a positive integer'; end if;
      if coalesce(trim(r->>'question_text'),'')='' then raise exception 'Question text is required'; end if;
      if v_correct not in ('A','B','C','D','E') then raise exception 'Correct option must be A, B, C, D or E'; end if;
      if coalesce(trim(r->>'option_a'),'')='' or coalesce(trim(r->>'option_b'),'')='' or coalesce(trim(r->>'option_c'),'')='' or coalesce(trim(r->>'option_d'),'')='' then raise exception 'Options A-D are required'; end if;
      row_number := i; status := 'valid'; message := 'Ready to import'; return next;
    exception when others then
      row_number := i; status := 'error'; message := sqlerrm; return next;
    end;
  end loop;
end;
$$;

create or replace function public.superadmin_confirm_question_import_v2(p_rows jsonb)
returns table(imported integer, updated integer, total_questions integer)
language plpgsql
security definer
set search_path=public
as $$
declare
  r jsonb;
  v_exam uuid;
  v_paper uuid;
  v_qn integer;
  v_qid uuid;
  v_new boolean;
  v_mode text;
  v_papers integer;
  v_key text;
  v_opt text;
  v_id uuid;
  n_new integer := 0;
  n_updated integer := 0;
  n_total integer := 0;
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  for r in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    v_exam := (r->>'exam_id')::uuid;
    v_paper := nullif(r->>'exam_course_id','')::uuid;
    v_qn := (r->>'question_number')::integer;
    select mode into v_mode from public.exams where id=v_exam and is_active=false;
    if v_mode is null then raise exception 'Examination does not exist or is already active'; end if;
    select count(*) into v_papers from public.exam_courses where exam_id=v_exam;
    if v_paper is null and v_papers=1 then select id into v_paper from public.exam_courses where exam_id=v_exam limit 1; end if;
    if v_paper is null or not exists(select 1 from public.exam_courses where id=v_paper and exam_id=v_exam) then raise exception 'Every imported question must belong to a valid examination paper'; end if;

    select id into v_qid from public.questions where exam_id=v_exam and exam_course_id=v_paper and question_number=v_qn limit 1;
    v_new := v_qid is null;
    if v_new then
      insert into public.questions(exam_id,exam_course_id,question_number,question_text) values(v_exam,v_paper,v_qn,r->>'question_text') returning id into v_qid;
      n_new := n_new + 1;
    else
      update public.questions set question_text=r->>'question_text',updated_at=now() where id=v_qid;
      n_updated := n_updated + 1;
      delete from public.question_options where question_id=v_qid;
    end if;

    for v_key, v_opt in select * from (values ('A',r->>'option_a'),('B',r->>'option_b'),('C',r->>'option_c'),('D',r->>'option_d'),('E',r->>'option_e')) as opts(k,v) where coalesce(trim(v),'')<>'' loop
      insert into public.question_options(question_id,option_key,option_text,is_correct)
      values(v_qid,v_key,v_opt,upper(trim(r->>'correct_option'))=v_key);
    end loop;
  end loop;

  select count(*) into n_total from public.questions where exam_id = any(select distinct (value->>'exam_id')::uuid from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)));
  update public.exams e set question_count=(select count(*) from public.questions q where q.exam_id=e.id),updated_at=now()
  where e.id = any(select distinct (value->>'exam_id')::uuid from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)));

  return query select n_new,n_updated,n_total;
end;
$$;

revoke all on function public.superadmin_validate_question_import_v2(jsonb) from public;
revoke all on function public.superadmin_confirm_question_import_v2(jsonb) from public;
grant execute on function public.superadmin_validate_question_import_v2(jsonb) to authenticated;
grant execute on function public.superadmin_confirm_question_import_v2(jsonb) to authenticated;

-- ------------------------------------------------------------
-- MODE-AWARE SESSION STATE
-- ------------------------------------------------------------
create or replace function public.get_exam_session_state_v2(p_exam_session_id uuid)
returns table(
  exam_session_id uuid,
  exam_id uuid,
  mode text,
  session_status text,
  started_at timestamptz,
  global_expires_at timestamptz,
  active_exam_session_course_id uuid,
  active_exam_course_id uuid,
  paper_expires_at timestamptz,
  papers jsonb
)
language plpgsql
security definer
set search_path=public
as $$
declare
  v_student_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_student_id := public.current_student_id();
  return query
  select es.id, es.exam_id, e.mode, es.status, es.started_at, es.global_expires_at,
    active.id, active.exam_course_id, active.paper_expires_at,
    coalesce((select jsonb_agg(jsonb_build_object(
      'id',esc.id,'examCourseId',esc.exam_course_id,'status',esc.status,
      'paperExpiresAt',esc.paper_expires_at,'paperOrder',ec.paper_order,
      'courseCode',c.code,'courseTitle',c.title
    ) order by ec.paper_order) from public.exam_session_courses esc
      join public.exam_courses ec on ec.id=esc.exam_course_id
      join public.courses c on c.id=ec.course_id
      where esc.exam_session_id=es.id),'[]'::jsonb)
  from public.exam_sessions es
  join public.exams e on e.id=es.exam_id
  left join lateral (
    select esc.* from public.exam_session_courses esc
    where esc.exam_session_id=es.id and esc.status='active'
    order by esc.created_at limit 1
  ) active on true
  where es.id=p_exam_session_id and es.student_id=v_student_id;
  if not found then raise exception 'Exam session does not belong to this student'; end if;
end;
$$;

revoke all on function public.get_exam_session_state_v2(uuid) from public;
grant execute on function public.get_exam_session_state_v2(uuid) to authenticated;
