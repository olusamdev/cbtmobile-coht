-- ============================================================
-- MIGRATION 4: RESULTS AND SCORING
-- ============================================================
-- Creates the authoritative examination result layer.
--
-- Results belong to an individual examination paper/session
-- rather than simply to the student's overall login session.
--
-- This supports:
--   - Regular mode
--   - Pharmacy PreNational multi-course mode
--   - Continuous mode
--   - Instant result visibility
--   - Superadmin result access
--   - Result mailing authorization
--   - Result audit trail
--
-- IMPORTANT:
-- Scoring must ultimately be performed by trusted server-side
-- operations. Student-facing queries must never expose the
-- question answer key.
-- ============================================================


-- ============================================================
-- 1. INSTANT RESULT SETTING
-- ============================================================
-- Superadmin can control whether students are allowed to see
-- their result immediately after submission.
--
-- This is deliberately stored on the examination definition
-- because different examinations may have different policies.
-- ============================================================

alter table public.exams
add column show_instant_results boolean not null default false;


comment on column public.exams.show_instant_results is
    'Controls whether students may view their result immediately after a confirmed paper submission.';


-- ============================================================
-- 2. EXAM RESULTS
-- ============================================================
-- One result belongs to one student's examination paper.
--
-- For a multi-course examination:
--
--   Student
--      └── Exam Session
--             ├── Paper A → Result A
--             ├── Paper B → Result B
--             └── Paper C → Result C
--
-- The result is created only after authoritative scoring has
-- completed successfully.
-- ============================================================

create table public.exam_results (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete restrict,

    exam_session_course_id uuid not null
        references public.exam_session_courses(id)
        on delete restrict,

    student_id uuid not null
        references public.students(id)
        on delete restrict,

    exam_id uuid not null
        references public.exams(id)
        on delete restrict,

    -- Number of questions in the submitted paper.
    total_questions integer not null
        check (total_questions >= 0),

    -- Number of questions for which the student selected an answer.
    answered_questions integer not null default 0
        check (
            answered_questions >= 0
            and answered_questions <= total_questions
        ),

    -- Number answered correctly.
    correct_answers integer not null default 0
        check (
            correct_answers >= 0
            and correct_answers <= total_questions
        ),

    -- Number answered incorrectly.
    wrong_answers integer not null default 0
        check (
            wrong_answers >= 0
            and wrong_answers <= total_questions
        ),

    -- Number left unanswered.
    unanswered_questions integer not null default 0
        check (
            unanswered_questions >= 0
            and unanswered_questions <= total_questions
        ),

    -- Raw score.
    score numeric(10,2) not null default 0
        check (score >= 0),

    -- Percentage score.
    percentage numeric(6,2) not null default 0
        check (
            percentage >= 0
            and percentage <= 100
        ),

    -- Result lifecycle.
    status text not null default 'final'
        check (
            status in (
                'pending',
                'final',
                'voided'
            )
        ),

    -- When authoritative scoring was completed.
    scored_at timestamptz,

    -- Who/what authorized a void if a result must be invalidated.
    voided_at timestamptz,

    voided_by uuid,

    void_reason text,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- A paper can have only one authoritative result.
    unique (exam_session_course_id)
);


-- ============================================================
-- 3. RESULT EVENTS
-- ============================================================
-- Keeps a history of important result operations.
--
-- Examples:
--
--   RESULT_CREATED
--   RESULT_SCORED
--   RESULT_VIEWED
--   RESULT_DOWNLOADED
--   RESULT_MAIL_AUTHORIZED
--   RESULT_MAIL_SENT
--   RESULT_VOIDED
-- ============================================================

create table public.result_events (
    id uuid primary key default gen_random_uuid(),

    exam_result_id uuid not null
        references public.exam_results(id)
        on delete cascade,

    event_type text not null,

    event_data jsonb not null default '{}'::jsonb,

    performed_by uuid,

    created_at timestamptz not null default now()
);


-- ============================================================
-- 4. RESULT MAIL REQUESTS
-- ============================================================
-- A lecturer may submit an email address requesting that a
-- result/result set be mailed.
--
-- IMPORTANT:
-- Submitting the lecturer's email does NOT authorize mailing.
--
-- The request remains pending until the Superadmin authorizes it.
-- ============================================================

create table public.result_mail_requests (
    id uuid primary key default gen_random_uuid(),

    exam_result_id uuid not null
        references public.exam_results(id)
        on delete restrict,

    lecturer_name text,

    lecturer_email text not null,

    status text not null default 'pending'
        check (
            status in (
                'pending',
                'authorized',
                'sent',
                'rejected',
                'cancelled'
            )
        ),

    requested_at timestamptz not null default now(),

    authorized_at timestamptz,

    authorized_by uuid,

    sent_at timestamptz,

    rejected_at timestamptz,

    rejected_by uuid,

    rejection_reason text,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()
);


-- ============================================================
-- 5. RESULT ACCESS EVENTS
-- ============================================================
-- Records access to results separately from result changes.
--
-- This will help us audit:
--
--   - who downloaded a result
--   - when it happened
--   - whether it was a student, admin, or superadmin
--
-- The actual authorization will be enforced later through
-- authentication/RLS/server-side policies.
-- ============================================================

create table public.result_access_events (
    id uuid primary key default gen_random_uuid(),

    exam_result_id uuid not null
        references public.exam_results(id)
        on delete cascade,

    access_type text not null
        check (
            access_type in (
                'view',
                'download'
            )
        ),

    accessed_by uuid,

    accessed_at timestamptz not null default now(),

    metadata jsonb not null default '{}'::jsonb
);


-- ============================================================
-- INDEXES
-- ============================================================

create index idx_exam_results_exam_session_id
    on public.exam_results(exam_session_id);

create index idx_exam_results_exam_session_course_id
    on public.exam_results(exam_session_course_id);

create index idx_exam_results_student_id
    on public.exam_results(student_id);

create index idx_exam_results_exam_id
    on public.exam_results(exam_id);

create index idx_exam_results_status
    on public.exam_results(status);

create index idx_result_events_exam_result_id
    on public.result_events(exam_result_id);

create index idx_result_events_created_at
    on public.result_events(created_at);

create index idx_result_mail_requests_exam_result_id
    on public.result_mail_requests(exam_result_id);

create index idx_result_mail_requests_status
    on public.result_mail_requests(status);

create index idx_result_access_events_exam_result_id
    on public.result_access_events(exam_result_id);

create index idx_result_access_events_accessed_at
    on public.result_access_events(accessed_at);


-- ============================================================
-- UPDATED_AT TRIGGERS
-- ============================================================

create trigger exam_results_set_updated_at
before update on public.exam_results
for each row
execute function public.set_updated_at();


create trigger result_mail_requests_set_updated_at
before update on public.result_mail_requests
for each row
execute function public.set_updated_at();


-- ============================================================
-- COMMENTS
-- ============================================================

comment on table public.exam_results is
    'Authoritative scored result for one student examination paper.';

comment on table public.result_events is
    'Audit history of important result operations.';

comment on table public.result_mail_requests is
    'Lecturer requests for result delivery requiring Superadmin authorization.';

comment on table public.result_access_events is
    'Audit record of result viewing and downloading.';

comment on column public.exam_results.score is
    'Authoritative raw examination score generated by the trusted scoring operation.';

comment on column public.exam_results.percentage is
    'Authoritative percentage generated by the trusted scoring operation.';