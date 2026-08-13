-- ============================================================
-- MIGRATION 3: EXAMINATION EXECUTION
-- ============================================================
-- Records a student's actual examination attempt.
--
-- This layer is responsible for:
--   - persistent exam sessions
--   - answer persistence
--   - pause/resume state
--   - submission state
--   - strikes
--   - time extensions
--   - supervisor alerts
--   - administrative actions
--   - complete session history
--
-- Existing migrations are NOT modified.
-- ============================================================


-- ============================================================
-- 1. EXAM SESSIONS
-- ============================================================
-- One row represents one student's attempt at an examination.
--
-- IMPORTANT:
-- The browser is NOT the authoritative source of exam state.
-- This row is the authoritative server-side session state.
-- ============================================================

create table public.exam_sessions (
    id uuid primary key default gen_random_uuid(),

    exam_id uuid not null
        references public.exams(id)
        on delete restrict,

    student_id uuid not null
        references public.students(id)
        on delete restrict,

    -- Current lifecycle state of the examination.
    status text not null default 'active'
        check (
            status in (
                'active',
                'paused',
                'submission_pending',
                'submitted'
            )
        ),

    -- Which question the student was viewing most recently.
    current_question_id uuid
        references public.questions(id)
        on delete set null,

    -- Authoritative timing information.
    started_at timestamptz not null default now(),

    paused_at timestamptz,

    submitted_at timestamptz,

    -- Total amount of time spent paused.
    -- Stored in seconds to allow accurate reconstruction.
    total_paused_seconds bigint not null default 0
        check (total_paused_seconds >= 0),

    -- Additional time granted by an authorized administrator.
    total_extension_seconds bigint not null default 0
        check (total_extension_seconds >= 0),

    -- Used to prevent accidental duplicate submission processing.
    submission_request_id uuid,

    -- The final score/result is intentionally not stored here.
    -- Result data will be handled by the results layer.

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- A student should not have multiple simultaneous attempts
    -- for the exact same exam.
    unique (exam_id, student_id)
);


-- ============================================================
-- 2. EXAM SESSION COURSES
-- ============================================================
-- Records which course/paper the student's session is currently
-- associated with.
--
-- This is especially important for Pharmacy PreNational mode,
-- where one examination can contain multiple papers.
-- ============================================================

create table public.exam_session_courses (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete cascade,

    exam_course_id uuid not null
        references public.exam_courses(id)
        on delete restrict,

    status text not null default 'available'
        check (
            status in (
                'available',
                'active',
                'submitted'
            )
        ),

    started_at timestamptz,

    submitted_at timestamptz,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    unique (exam_session_id, exam_course_id)
);


-- ============================================================
-- 3. ANSWERS
-- ============================================================
-- Stores the student's current answer to each question.
--
-- selected_option_id points directly to question_options.
--
-- This is preferable to storing only "A", "B", etc. because
-- the database can verify the selected option belongs to the
-- corresponding question.
-- ============================================================

create table public.answers (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete cascade,

    question_id uuid not null
        references public.questions(id)
        on delete restrict,

    selected_option_id uuid
        references public.question_options(id)
        on delete restrict,

    answered_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    unique (exam_session_id, question_id)
);


-- ============================================================
-- 4. STRIKES
-- ============================================================
-- Every strike is preserved as an individual record.
--
-- We do NOT simply maintain a "strike_count" number because
-- we need an audit trail showing:
--
--   - what happened
--   - when it happened
--   - who issued it
--   - whether it was cleared
--   - who cleared it
-- ============================================================

create table public.strikes (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete cascade,

    strike_number integer not null
        check (strike_number > 0),

    reason text not null,

    issued_at timestamptz not null default now(),

    issued_by uuid,

    cleared_at timestamptz,

    cleared_by uuid,

    clear_reason text,

    created_at timestamptz not null default now()
);


-- ============================================================
-- 5. TIME EXTENSIONS
-- ============================================================
-- Every extension is recorded separately.
--
-- The total_extension_seconds column on exam_sessions provides
-- a convenient current total, while this table provides the
-- complete audit trail.
-- ============================================================

create table public.time_extensions (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete cascade,

    extension_seconds integer not null
        check (extension_seconds > 0),

    reason text not null,

    granted_by uuid,

    granted_at timestamptz not null default now(),

    created_at timestamptz not null default now()
);


-- ============================================================
-- 6. SUPERVISOR ALERTS
-- ============================================================
-- Students can call the supervisor (Admin) for assistance.
--
-- The alert identifies the session/student and can be
-- acknowledged and resolved by the supervisor.
-- ============================================================

create table public.supervisor_alerts (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete cascade,

    message text,

    status text not null default 'open'
        check (
            status in (
                'open',
                'acknowledged',
                'resolved'
            )
        ),

    created_at timestamptz not null default now(),

    acknowledged_at timestamptz,

    resolved_at timestamptz,

    acknowledged_by uuid,

    resolved_by uuid
);


-- ============================================================
-- 7. EXAM SESSION EVENTS
-- ============================================================
-- Immutable-style audit history of important session actions.
--
-- Examples:
--
--   SESSION_STARTED
--   ANSWER_SAVED
--   STRIKE_ISSUED
--   SESSION_PAUSED
--   SESSION_RESUMED
--   STRIKE_CLEARED
--   TIME_EXTENSION_GRANTED
--   SUPERVISOR_CALLED
--   SUBMISSION_REQUESTED
--   SUBMISSION_CONFIRMED
--   FORCED_SUBMISSION
--   SUBMISSION_REVERSED
--
-- We keep this generic so new event types can be added without
-- redesigning the table.
-- ============================================================

create table public.exam_session_events (
    id uuid primary key default gen_random_uuid(),

    exam_session_id uuid not null
        references public.exam_sessions(id)
        on delete cascade,

    event_type text not null,

    event_data jsonb not null default '{}'::jsonb,

    performed_by uuid,

    created_at timestamptz not null default now()
);


-- ============================================================
-- INDEXES
-- ============================================================

create index idx_exam_sessions_exam_id
    on public.exam_sessions(exam_id);

create index idx_exam_sessions_student_id
    on public.exam_sessions(student_id);

create index idx_exam_sessions_status
    on public.exam_sessions(status);

create index idx_exam_session_courses_session_id
    on public.exam_session_courses(exam_session_id);

create index idx_exam_session_courses_exam_course_id
    on public.exam_session_courses(exam_course_id);

create index idx_answers_exam_session_id
    on public.answers(exam_session_id);

create index idx_answers_question_id
    on public.answers(question_id);

create index idx_strikes_exam_session_id
    on public.strikes(exam_session_id);

create index idx_time_extensions_exam_session_id
    on public.time_extensions(exam_session_id);

create index idx_supervisor_alerts_exam_session_id
    on public.supervisor_alerts(exam_session_id);

create index idx_supervisor_alerts_status
    on public.supervisor_alerts(status);

create index idx_exam_session_events_exam_session_id
    on public.exam_session_events(exam_session_id);

create index idx_exam_session_events_created_at
    on public.exam_session_events(created_at);


-- ============================================================
-- UPDATED_AT TRIGGERS
-- ============================================================

create trigger exam_sessions_set_updated_at
before update on public.exam_sessions
for each row
execute function public.set_updated_at();


create trigger exam_session_courses_set_updated_at
before update on public.exam_session_courses
for each row
execute function public.set_updated_at();


create trigger answers_set_updated_at
before update on public.answers
for each row
execute function public.set_updated_at();


-- ============================================================
-- COMMENTS
-- ============================================================

comment on table public.exam_sessions is
    'Authoritative server-side state for one student examination attempt.';

comment on table public.exam_session_courses is
    'Tracks the course/paper components of a student examination session.';

comment on table public.answers is
    'Persistent student answers for an examination session.';

comment on table public.strikes is
    'Individual examination misconduct/warning strike records with audit history.';

comment on table public.time_extensions is
    'Authorized additional examination time granted to a student session.';

comment on table public.supervisor_alerts is
    'Requests from students for supervisor/admin attention during an examination.';

comment on table public.exam_session_events is
    'Audit history of important actions and state transitions during an examination session.';