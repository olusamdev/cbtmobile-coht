-- ============================================================
-- MIGRATION 10: SECURE SUBMISSION AND SCORING
-- ============================================================
--
-- Authoritative paper submission and scoring.
--
-- IMPORTANT:
-- The answer key is read only inside this SECURITY DEFINER
-- function. It is never returned to the student.
--
-- submission_request_id makes submission idempotent.
-- A network retry therefore cannot create duplicate results.
-- ============================================================


-- ============================================================
-- 1. SUBMIT EXAM PAPER
-- ============================================================

create or replace function public.submit_exam_paper(
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
    submission_confirmed boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
    v_session_course public.exam_session_courses%rowtype;
    v_session public.exam_sessions%rowtype;

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
    -- STUDENT
    -- ========================================================

    v_student_id := public.current_student_id();

    if v_student_id is null then
        raise exception 'Authenticated user is not an active student';
    end if;


    -- ========================================================
    -- VALIDATE REQUEST ID
    -- ========================================================

    if p_submission_request_id is null then
        raise exception 'Submission request ID is required';
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
    -- LOCK PARENT SESSION
    -- ========================================================

    select *
    into v_session
    from public.exam_sessions
    where id = v_session_course.exam_session_id
    for update;


    if not found then
        raise exception 'Examination session does not exist';
    end if;


    -- ========================================================
    -- OWNERSHIP
    -- ========================================================

    if v_session.student_id <> v_student_id then
        raise exception 'This examination session does not belong to you';
    end if;


    -- ========================================================
    -- ALREADY SUBMITTED
    -- ========================================================
    --
    -- If a previous request already completed the submission,
    -- return the existing authoritative result.
    --
    -- This is what makes network retries safe.
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
    -- PREVENT CONCURRENT SUBMISSION
    -- ========================================================

    if v_session_course.status = 'submission_pending' then

        -- If this exact request is being retried, continue.
        if v_session_course.submission_request_id
            is distinct from p_submission_request_id then

            raise exception
                'A submission is already being processed for this paper';

        end if;

    elsif v_session_course.status <> 'active' then

        raise exception
            'This examination paper cannot currently be submitted';

    end if;


    -- ========================================================
    -- AUTHORITATIVE TIMESTAMP
    -- ========================================================

    v_now := now();


    -- ========================================================
    -- MARK SUBMISSION PENDING
    -- ========================================================

    update public.exam_session_courses
    set
        status = 'submission_pending',
        submission_request_id = p_submission_request_id,
        submission_started_at = coalesce(
            submission_started_at,
            v_now
        ),
        updated_at = v_now
    where id = p_exam_session_course_id
    returning *
    into v_session_course;


    -- ========================================================
    -- EXAM ID
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
    --
    -- The answer key is accessed here only.
    --
    -- Student answers are compared against
    -- question_options.is_correct.
    --
    -- No is_correct value is returned.
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


    -- ========================================================
    -- UNANSWERED
    -- ========================================================

    v_unanswered :=
        greatest(
            0,
            v_question_count
            - v_correct
            - v_wrong
        );


    -- ========================================================
    -- SCORE
    -- ========================================================
    --
    -- Each question currently carries equal weight.
    -- Therefore:
    --
    -- score = correct answers
    -- percentage = correct / total × 100
    --
    -- This can be replaced later if weighted questions are
    -- introduced.
    -- ========================================================

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
    -- CREATE AUTHORITATIVE RESULT
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


    -- ========================================================
    -- VERIFY RESULT PERSISTENCE
    -- ========================================================

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
    -- AUDIT
    -- ========================================================

    insert into public.exam_session_events (
        exam_session_id,
        event_type,
        event_data,
        performed_by
    )
    values (
        v_session.id,
        'SUBMISSION_CONFIRMED',
        jsonb_build_object(
            'exam_session_course_id',
            v_session_course.id,
            'result_id',
            v_result.id,
            'submission_request_id',
            p_submission_request_id,
            'score',
            v_result.score,
            'percentage',
            v_result.percentage
        ),
        auth.uid()
    );


    -- ========================================================
    -- RETURN ONLY CONFIRMED RESULT
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
-- 2. COMMENTS
-- ============================================================

comment on function public.submit_exam_paper(uuid, uuid) is
    'Authoritatively submits and scores one examination paper. Uses the protected answer key internally and returns only a persisted result.';


-- ============================================================
-- 3. FUNCTION PRIVILEGES
-- ============================================================

revoke all
on function public.submit_exam_paper(uuid, uuid)
from public;


grant execute
on function public.submit_exam_paper(uuid, uuid)
to authenticated;