-- ============================================================
-- MIGRATION 11: EXAM RECOVERY & ADMIN OPERATIONS
-- ============================================================
--
-- Provides controlled recovery and administrative intervention
-- without exposing the answer key to the client.
--
-- Operations:
--
--   1. get_exam_session_state()
--   2. admin_get_exam_session_state()
--   3. admin_extend_exam_time()
--   4. admin_force_submit_exam_paper()
--
-- IMPORTANT:
-- Student recovery only returns safe session information.
-- The answer key is never returned.
-- ============================================================


-- ============================================================
-- 1. STUDENT EXAM SESSION STATE
-- ============================================================
--
-- Used after:
--
--   - network reconnection
--   - browser refresh
--   - device recovery
--   - accidental page reload
--
-- The client receives the authoritative state from PostgreSQL.
-- ============================================================

create or replace function public.get_exam_session_state(
    p_exam_session_id uuid
)
returns table (
    exam_session_id uuid,
    exam_id uuid,
    session_status text,
    started_at timestamptz,
    paused_at timestamptz,
    total_paused_seconds integer,
    total_extension_seconds integer,
    current_question_id uuid,
    exam_session_course_id uuid,
    paper_status text,
    submission_request_id uuid,
    submission_started_at timestamptz,
    submitted_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    v_student_id := public.current_student_id();

    if v_student_id is null then
        raise exception 'Authenticated user is not an active student';
    end if;


    return query
    select
        es.id,
        es.exam_id,
        es.status,
        es.started_at,
        es.paused_at,
        coalesce(es.total_paused_seconds, 0),
        coalesce(es.total_extension_seconds, 0),
        es.current_question_id,
        esc.id,
        esc.status,
        esc.submission_request_id,
        esc.submission_started_at,
        esc.submitted_at
    from public.exam_sessions es
    left join public.exam_session_courses esc
        on esc.exam_session_id = es.id
    where es.id = p_exam_session_id
      and es.student_id = v_student_id;

    if not found then
        raise exception 'Exam session does not belong to this student';
    end if;

end;
$$;


-- ============================================================
-- 2. ADMIN EXAM SESSION STATE
-- ============================================================
--
-- Admin/Superadmin monitoring function.
--
-- This deliberately returns operational state only.
-- No answer key is exposed.
-- ============================================================

create or replace function public.admin_get_exam_session_state(
    p_exam_session_id uuid
)
returns table (
    exam_session_id uuid,
    exam_id uuid,
    student_id uuid,
    session_status text,
    started_at timestamptz,
    paused_at timestamptz,
    total_paused_seconds integer,
    total_extension_seconds integer,
    current_question_id uuid,
    exam_session_course_id uuid,
    paper_status text,
    submission_request_id uuid,
    submission_started_at timestamptz,
    submitted_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role text;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    v_role := public.current_user_role();

    if v_role not in ('admin', 'superadmin') then
        raise exception 'Administrative authorization required';
    end if;


    return query
    select
        es.id,
        es.exam_id,
        es.student_id,
        es.status,
        es.started_at,
        es.paused_at,
        coalesce(es.total_paused_seconds, 0),
        coalesce(es.total_extension_seconds, 0),
        es.current_question_id,
        esc.id,
        esc.status,
        esc.submission_request_id,
        esc.submission_started_at,
        esc.submitted_at
    from public.exam_sessions es
    left join public.exam_session_courses esc
        on esc.exam_session_id = es.id
    where es.id = p_exam_session_id;

    if not found then
        raise exception 'Exam session does not exist';
    end if;

end;
$$;


-- ============================================================
-- 3. ADMIN EXTEND EXAM TIME
-- ============================================================
--
-- Adds time to the authoritative session.
--
-- The extension is stored in total_extension_seconds.
-- The student's device cannot modify this value.
-- ============================================================

create or replace function public.admin_extend_exam_time(
    p_exam_session_id uuid,
    p_extension_seconds integer,
    p_reason text default null
)
returns table (
    exam_session_id uuid,
    total_extension_seconds integer,
    updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_role text;
    v_session public.exam_sessions%rowtype;
    v_now timestamptz;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    v_role := public.current_user_role();

    if v_role not in ('admin', 'superadmin') then
        raise exception 'Administrative authorization required';
    end if;


    if p_extension_seconds <= 0 then
        raise exception 'Extension must be greater than zero seconds';
    end if;


    select *
    into v_session
    from public.exam_sessions
    where id = p_exam_session_id
    for update;

    if not found then
        raise exception 'Exam session does not exist';
    end if;


    if v_session.status not in ('active', 'paused') then
        raise exception
            'Time can only be extended for an active or paused examination';
    end if;


    v_now := now();


    update public.exam_sessions
    set
        total_extension_seconds =
            coalesce(total_extension_seconds, 0)
            + p_extension_seconds,
        updated_at = v_now
    where id = p_exam_session_id
    returning *
    into v_session;


    insert into public.exam_session_events (
        exam_session_id,
        event_type,
        event_data,
        performed_by
    )
    values (
        p_exam_session_id,
        'TIME_EXTENDED',
        jsonb_build_object(
            'extension_seconds', p_extension_seconds,
            'reason', p_reason,
            'updated_at', v_now
        ),
        auth.uid()
    );


    return query
    select
        v_session.id,
        v_session.total_extension_seconds,
        v_now;

end;
$$;


-- ============================================================
-- 4. ADMIN FORCE-SUBMIT EXAM PAPER
-- ============================================================
--
-- This is intentionally separate from the student
-- submit_exam_paper() function.
--
-- The Admin is not pretending to be the student.
--
-- The function:
--
--   - verifies administrative authority
--   - locks the paper
--   - scores using the same protected answer key
--   - persists the authoritative result
--   - marks the paper submitted
--   - records the intervention
--
-- It does NOT expose is_correct.
-- ============================================================

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
declare
    v_role text;
    v_session_course public.exam_session_courses%rowtype;
    v_session public.exam_sessions%rowtype;
    v_student_id uuid;

    v_exam_id uuid;
    v_question_count integer;

    v_correct integer := 0;
    v_wrong integer := 0;
    v_unanswered integer := 0;

    v_score numeric := 0;
    v_percentage numeric := 0;

    v_result public.exam_results%rowtype;
    v_existing_result public.exam_results%rowtype;

    v_now timestamptz;
begin

    -- ========================================================
    -- AUTHENTICATION
    -- ========================================================

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    -- ========================================================
    -- AUTHORIZATION
    -- ========================================================

    v_role := public.current_user_role();

    if v_role not in ('admin', 'superadmin') then
        raise exception 'Administrative authorization required';
    end if;


    if nullif(trim(p_reason), '') is null then
        raise exception 'A reason is required for force submission';
    end if;


    -- ========================================================
    -- LOCK PAPER
    -- ========================================================

    select *
    into v_session_course
    from public.exam_session_courses
    where id = p_exam_session_course_id
    for update;

    if not found then
        raise exception 'Examination paper session does not exist';
    end if;


    -- ========================================================
    -- PARENT SESSION
    -- ========================================================

    select *
    into v_session
    from public.exam_sessions
    where id = v_session_course.exam_session_id
    for update;

    if not found then
        raise exception 'Examination session does not exist';
    end if;


    v_student_id := v_session.student_id;


    -- ========================================================
    -- ALREADY SUBMITTED
    -- ========================================================

    if v_session_course.status = 'submitted' then

        select *
        into v_existing_result
        from public.exam_results
        where exam_session_course_id = p_exam_session_course_id;

        if found then

            return query
            select
                v_existing_result.id,
                v_existing_result.exam_session_course_id,
                v_existing_result.score,
                v_existing_result.percentage,
                v_existing_result.correct_answers,
                v_existing_result.wrong_answers,
                v_existing_result.unanswered_questions,
                v_existing_result.status,
                true;

            return;

        else
            raise exception
                'Paper is marked submitted but no result exists';
        end if;

    end if;


    -- ========================================================
    -- VALID PAPER STATE
    -- ========================================================

    if v_session_course.status not in (
        'active',
        'paused',
        'submission_pending'
    ) then
        raise exception
            'This examination paper cannot be force-submitted';
    end if;


    -- ========================================================
    -- AUTHORITATIVE TIMESTAMP
    -- ========================================================

    v_now := now();


    -- ========================================================
    -- EXAM
    -- ========================================================

    v_exam_id := v_session.exam_id;


    -- ========================================================
    -- QUESTION COUNT
    -- ========================================================

    select count(*)
    into v_question_count
    from public.questions q
    where q.exam_id = v_exam_id;


    if v_question_count = 0 then
        raise exception 'This examination contains no questions';
    end if;


    -- ========================================================
    -- SCORE
    -- ========================================================

    select
        count(*) filter (
            where qo.is_correct = true
        ),
        count(*) filter (
            where qo.is_correct = false
        )
    into
        v_correct,
        v_wrong
    from public.questions q
    left join public.answers a
        on a.question_id = q.id
       and a.exam_session_id = v_session.id
    left join public.question_options qo
        on qo.id = a.selected_option_id
       and qo.question_id = q.id
    where q.exam_id = v_exam_id
      and a.selected_option_id is not null;


    v_unanswered :=
        greatest(
            0,
            v_question_count
            - v_correct
            - v_wrong
        );


    v_score := v_correct;

    v_percentage :=
        round(
            (
                v_correct::numeric
                / nullif(v_question_count, 0)
            ) * 100,
            2
        );


    -- ========================================================
    -- CREATE / RECOVER RESULT
    -- ========================================================

    insert into public.exam_results (
        exam_session_course_id,
        student_id,
        total_questions,
        correct_answers,
        wrong_answers,
        unanswered_questions,
        score,
        percentage,
        status,
        scored_at
    )
    values (
        v_session_course.id,
        v_student_id,
        v_question_count,
        v_correct,
        v_wrong,
        v_unanswered,
        v_score,
        v_percentage,
        'final',
        v_now
    )
    on conflict (exam_session_course_id)
    do update
    set
        total_questions = excluded.total_questions,
        correct_answers = excluded.correct_answers,
        wrong_answers = excluded.wrong_answers,
        unanswered_questions = excluded.unanswered_questions,
        score = excluded.score,
        percentage = excluded.percentage,
        status = excluded.status,
        scored_at = excluded.scored_at
    returning *
    into v_result;


    if v_result.id is null then
        raise exception 'Result could not be persisted';
    end if;


    -- ========================================================
    -- MARK PAPER SUBMITTED
    -- ========================================================

    update public.exam_session_courses
    set
        status = 'submitted',
        submitted_at = v_now,
        updated_at = v_now
    where id = v_session_course.id;


    -- ========================================================
    -- ADMIN AUDIT
    -- ========================================================

    insert into public.exam_session_events (
        exam_session_id,
        event_type,
        event_data,
        performed_by
    )
    values (
        v_session.id,
        'ADMIN_FORCE_SUBMISSION',
        jsonb_build_object(
            'exam_session_course_id',
            v_session_course.id,
            'result_id',
            v_result.id,
            'reason',
            p_reason,
            'score',
            v_result.score,
            'percentage',
            v_result.percentage
        ),
        auth.uid()
    );


    -- ========================================================
    -- RETURN CONFIRMED RESULT
    -- ========================================================

    return query
    select
        v_result.id,
        v_result.exam_session_course_id,
        v_result.score,
        v_result.percentage,
        v_result.correct_answers,
        v_result.wrong_answers,
        v_result.unanswered_questions,
        v_result.status,
        true;

end;
$$;


-- ============================================================
-- 5. COMMENTS
-- ============================================================

comment on function public.get_exam_session_state(uuid) is
    'Returns safe authoritative examination state for the authenticated student who owns the session.';

comment on function public.admin_get_exam_session_state(uuid) is
    'Returns operational examination state to an authorized Admin or Superadmin without exposing answer keys.';

comment on function public.admin_extend_exam_time(uuid, integer, text) is
    'Adds server-authoritative examination time for an active or paused session and records the intervention.';

comment on function public.admin_force_submit_exam_paper(uuid, text) is
    'Allows an authorized Admin or Superadmin to force-submit and securely score an examination paper.';


-- ============================================================
-- 6. PRIVILEGES
-- ============================================================

revoke all
on function public.get_exam_session_state(uuid)
from public;

revoke all
on function public.admin_get_exam_session_state(uuid)
from public;

revoke all
on function public.admin_extend_exam_time(uuid, integer, text)
from public;

revoke all
on function public.admin_force_submit_exam_paper(uuid, text)
from public;


grant execute
on function public.get_exam_session_state(uuid)
to authenticated;

grant execute
on function public.admin_get_exam_session_state(uuid)
to authenticated;

grant execute
on function public.admin_extend_exam_time(uuid, integer, text)
to authenticated;

grant execute
on function public.admin_force_submit_exam_paper(uuid, text)
to authenticated;