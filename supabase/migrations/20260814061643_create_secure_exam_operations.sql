-- ============================================================
-- MIGRATION 8: SECURE EXAM OPERATIONS
-- PART 1: SESSION START + ANSWER PERSISTENCE
-- ============================================================
--
-- These functions are the controlled entry points for the
-- student examination client.
--
-- Direct INSERT/UPDATE access to these tables is intentionally
-- not granted to students through RLS.
--
-- The database validates ownership and relationships here.
-- ============================================================


-- ============================================================
-- 1. START / RECOVER EXAM SESSION
-- ============================================================
--
-- Starts a student's examination session for one paper.
--
-- If the student already has an existing session for the exam:
--   - active/paused/submission_pending → recover it
--   - submitted → reject starting it again
--
-- The function also creates the corresponding
-- exam_session_courses record.
--
-- IMPORTANT:
-- The browser does NOT determine the authoritative start time.
-- PostgreSQL sets it using now().
-- ============================================================

create or replace function public.start_exam_session(
    p_exam_id uuid,
    p_exam_course_id uuid
)
returns table (
    exam_session_id uuid,
    exam_session_course_id uuid,
    session_status text,
    paper_status text,
    started_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
    v_exam public.exams%rowtype;
    v_exam_course public.exam_courses%rowtype;
    v_session public.exam_sessions%rowtype;
    v_session_course public.exam_session_courses%rowtype;
begin

    -- --------------------------------------------------------
    -- AUTHENTICATION
    -- --------------------------------------------------------

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    -- --------------------------------------------------------
    -- STUDENT ID
    -- --------------------------------------------------------

    v_student_id := public.current_student_id();

    if v_student_id is null then
        raise exception 'Authenticated user is not an active student';
    end if;


    -- --------------------------------------------------------
    -- EXAM
    -- --------------------------------------------------------

    select *
    into v_exam
    from public.exams
    where id = p_exam_id
      and is_active = true;

    if not found then
        raise exception 'Exam is not active or does not exist';
    end if;


    -- --------------------------------------------------------
    -- EXAM COURSE / PAPER
    -- --------------------------------------------------------

    select *
    into v_exam_course
    from public.exam_courses
    where id = p_exam_course_id
      and exam_id = p_exam_id;

    if not found then
        raise exception 'Exam paper does not belong to this examination';
    end if;


    -- --------------------------------------------------------
    -- STUDENT REGISTRATION
    -- --------------------------------------------------------
    --
    -- The student must actually be registered for the course
    -- attached to this examination paper.
    -- --------------------------------------------------------

    if not exists (
        select 1
        from public.student_course_registrations scr
        where scr.student_id = v_student_id
          and scr.course_id = v_exam_course.course_id
          and scr.is_active = true
    ) then
        raise exception 'Student is not registered for this course';
    end if;


    -- --------------------------------------------------------
    -- EXISTING SESSION
    -- --------------------------------------------------------

    select *
    into v_session
    from public.exam_sessions
    where exam_id = p_exam_id
      and student_id = v_student_id
    for update;


    -- --------------------------------------------------------
    -- CREATE SESSION IF NONE EXISTS
    -- --------------------------------------------------------

    if not found then

        insert into public.exam_sessions (
            exam_id,
            student_id,
            status,
            started_at
        )
        values (
            p_exam_id,
            v_student_id,
            'active',
            now()
        )
        returning *
        into v_session;

        -- Record the paper being taken.
        insert into public.exam_session_courses (
            exam_session_id,
            exam_course_id,
            status,
            started_at
        )
        values (
            v_session.id,
            p_exam_course_id,
            'active',
            v_session.started_at
        )
        returning *
        into v_session_course;


        -- ----------------------------------------------------
        -- AUDIT
        -- ----------------------------------------------------

        insert into public.exam_session_events (
            exam_session_id,
            event_type,
            event_data,
            performed_by
        )
        values (
            v_session.id,
            'SESSION_STARTED',
            jsonb_build_object(
                'exam_id', p_exam_id,
                'exam_course_id', p_exam_course_id
            ),
            auth.uid()
        );

    else

        -- ----------------------------------------------------
        -- EXISTING SESSION ALREADY SUBMITTED
        -- ----------------------------------------------------

        if v_session.status = 'submitted' then
            raise exception 'This examination session has already been submitted';
        end if;


        -- ----------------------------------------------------
        -- EXISTING PAPER
        -- ----------------------------------------------------

        select *
        into v_session_course
        from public.exam_session_courses
        where exam_session_id = v_session.id
          and exam_course_id = p_exam_course_id
        for update;


        -- ----------------------------------------------------
        -- CREATE PAPER RECORD IF NEEDED
        -- ----------------------------------------------------

        if not found then

            insert into public.exam_session_courses (
                exam_session_id,
                exam_course_id,
                status,
                started_at
            )
            values (
                v_session.id,
                p_exam_course_id,
                'active',
                now()
            )
            returning *
            into v_session_course;

        elsif v_session_course.status = 'submitted' then

            raise exception 'This examination paper has already been submitted';

        else

            -- Recover an available paper.
            update public.exam_session_courses
            set status = 'active',
                started_at = coalesce(started_at, now())
            where id = v_session_course.id
            returning *
            into v_session_course;

        end if;

    end if;


    -- --------------------------------------------------------
    -- RETURN AUTHORITATIVE STATE
    -- --------------------------------------------------------

    return query
    select
        v_session.id,
        v_session_course.id,
        v_session.status,
        v_session_course.status,
        v_session.started_at;

end;
$$;


-- ============================================================
-- 2. SAVE EXAM ANSWER
-- ============================================================
--
-- The student can only save an answer:
--
--   - to their own session
--   - while the session is active
--   - for a question belonging to the same exam
--   - where the selected option belongs to that question
--
-- The answer key is never returned.
-- ============================================================

create or replace function public.save_exam_answer(
    p_exam_session_id uuid,
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
begin

    -- --------------------------------------------------------
    -- AUTHENTICATION
    -- --------------------------------------------------------

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    v_student_id := public.current_student_id();

    if v_student_id is null then
        raise exception 'Authenticated user is not an active student';
    end if;


    -- --------------------------------------------------------
    -- SESSION OWNERSHIP + STATE
    -- --------------------------------------------------------

    select exam_id
    into v_exam_id
    from public.exam_sessions
    where id = p_exam_session_id
      and student_id = v_student_id
      and status = 'active';

    if not found then
        raise exception 'Exam session is not active or does not belong to this student';
    end if;


    -- --------------------------------------------------------
    -- QUESTION MUST BELONG TO THE EXAM
    -- --------------------------------------------------------

    if not exists (
        select 1
        from public.questions q
        where q.id = p_question_id
          and q.exam_id = v_exam_id
    ) then
        raise exception 'Question does not belong to this examination';
    end if;


    -- --------------------------------------------------------
    -- SELECTED OPTION MUST BELONG TO QUESTION
    -- --------------------------------------------------------

    if not exists (
        select 1
        from public.question_options qo
        where qo.id = p_selected_option_id
          and qo.question_id = p_question_id
    ) then
        raise exception 'Selected option does not belong to this question';
    end if;


    -- --------------------------------------------------------
    -- UPSERT ANSWER
    -- --------------------------------------------------------

    insert into public.answers (
        exam_session_id,
        question_id,
        selected_option_id,
        answered_at
    )
    values (
        p_exam_session_id,
        p_question_id,
        p_selected_option_id,
        now()
    )
    on conflict (exam_session_id, question_id)
    do update
    set selected_option_id = excluded.selected_option_id,
        answered_at = excluded.answered_at,
        updated_at = now();


    -- --------------------------------------------------------
    -- AUDIT
    -- --------------------------------------------------------

    insert into public.exam_session_events (
        exam_session_id,
        event_type,
        event_data,
        performed_by
    )
    values (
        p_exam_session_id,
        'ANSWER_SAVED',
        jsonb_build_object(
            'question_id', p_question_id
        ),
        auth.uid()
    );


    return true;

end;
$$;


-- ============================================================
-- 3. UPDATE CURRENT QUESTION
-- ============================================================
--
-- This persists the student's position so that refresh,
-- reconnect, or device recovery can restore the interface.
-- ============================================================

create or replace function public.update_exam_position(
    p_exam_session_id uuid,
    p_question_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
    v_exam_id uuid;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    v_student_id := public.current_student_id();

    if v_student_id is null then
        raise exception 'Authenticated user is not an active student';
    end if;


    select exam_id
    into v_exam_id
    from public.exam_sessions
    where id = p_exam_session_id
      and student_id = v_student_id
      and status = 'active';

    if not found then
        raise exception 'Exam session is not active or does not belong to this student';
    end if;


    if not exists (
        select 1
        from public.questions
        where id = p_question_id
          and exam_id = v_exam_id
    ) then
        raise exception 'Question does not belong to this examination';
    end if;


    update public.exam_sessions
    set current_question_id = p_question_id,
        updated_at = now()
    where id = p_exam_session_id;


    return true;

end;
$$;


-- ============================================================
-- 4. FUNCTION COMMENTS
-- ============================================================

comment on function public.start_exam_session(uuid, uuid) is
    'Securely starts or recovers a student examination session and paper.';

comment on function public.save_exam_answer(uuid, uuid, uuid) is
    'Securely persists a student answer after validating session ownership and question/option relationships.';

comment on function public.update_exam_position(uuid, uuid) is
    'Persists the current question for recovery after refresh, reconnect, logout, or device interruption.';


-- ============================================================
-- 5. REVOKE DIRECT PUBLIC ACCESS
-- ============================================================
--
-- Explicitly prevent anonymous users from invoking these
-- functions.
-- ============================================================

revoke all on function public.start_exam_session(uuid, uuid)
from public;

revoke all on function public.save_exam_answer(uuid, uuid, uuid)
from public;

revoke all on function public.update_exam_position(uuid, uuid)
from public;


-- Authenticated users will invoke these through Supabase RPC.
grant execute on function public.start_exam_session(uuid, uuid)
to authenticated;

grant execute on function public.save_exam_answer(uuid, uuid, uuid)
to authenticated;

grant execute on function public.update_exam_position(uuid, uuid)
to authenticated;