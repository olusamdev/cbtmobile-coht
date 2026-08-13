-- ============================================================
-- MIGRATION 2: EXAMINATION DEFINITION
-- ============================================================
-- Defines examinations, the courses/papers belonging to them,
-- questions, and question options.
--
-- Existing academic foundation is NOT modified:
-- departments
-- programmes
-- academic_sessions
-- courses
-- students
-- student_course_registrations
-- ============================================================


-- ============================================================
-- 1. EXAMS
-- ============================================================
-- An exam represents an examination event/configuration.
--
-- A normal exam may contain one course.
-- A Pharmacy PreNational exam may contain multiple courses.
--
-- The relationship between exams and courses is handled by
-- exam_courses below.
-- ============================================================

create table public.exams (
    id uuid primary key default gen_random_uuid(),

    academic_session_id uuid not null
        references public.academic_sessions(id)
        on delete restrict,

    title text not null,

    mode text not null default 'regular'
        check (
            mode in (
                'regular',
                'pharmacy_prenational',
                'continuous'
            )
        ),

    duration_minutes integer not null default 60
        check (duration_minutes > 0),

    question_count integer not null default 0
        check (question_count >= 0),

    is_active boolean not null default false,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now()
);


-- ============================================================
-- 2. EXAM COURSES
-- ============================================================
-- Connects an examination to one or more courses.
--
-- Regular:
--     Exam → ANA 201
--
-- Pharmacy PreNational:
--     Exam → Course A
--          → Course B
--          → Course C
--
-- This also gives us a clean place to store the order of papers
-- when an examination contains multiple courses.
-- ============================================================

create table public.exam_courses (
    id uuid primary key default gen_random_uuid(),

    exam_id uuid not null
        references public.exams(id)
        on delete cascade,

    course_id uuid not null
        references public.courses(id)
        on delete restrict,

    paper_order integer not null default 1
        check (paper_order > 0),

    created_at timestamptz not null default now(),

    unique (exam_id, course_id),

    unique (exam_id, paper_order)
);


-- ============================================================
-- 3. QUESTIONS
-- ============================================================
-- Each question belongs to a specific examination.
--
-- We deliberately do NOT store A/B/C/D as separate columns.
-- Options are stored in question_options below.
-- ============================================================

create table public.questions (
    id uuid primary key default gen_random_uuid(),

    exam_id uuid not null
        references public.exams(id)
        on delete cascade,

    question_number integer not null
        check (question_number > 0),

    question_text text not null,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    unique (exam_id, question_number)
);


-- ============================================================
-- 4. QUESTION OPTIONS
-- ============================================================
-- The old GAS system currently uses A-D.
--
-- We allow A-E so that the new platform can support five-option
-- questions later without redesigning the table.
--
-- IMPORTANT:
-- is_correct is authoritative answer-key data.
-- It must NEVER be exposed through the student-facing API.
-- ============================================================

create table public.question_options (
    id uuid primary key default gen_random_uuid(),

    question_id uuid not null
        references public.questions(id)
        on delete cascade,

    option_key text not null
        check (
            option_key in (
                'A',
                'B',
                'C',
                'D',
                'E'
            )
        ),

    option_text text not null,

    is_correct boolean not null default false,

    created_at timestamptz not null default now(),

    unique (question_id, option_key)
);


-- ============================================================
-- INDEXES
-- ============================================================

create index idx_exams_academic_session_id
    on public.exams(academic_session_id);

create index idx_exams_active
    on public.exams(is_active);

create index idx_exam_courses_exam_id
    on public.exam_courses(exam_id);

create index idx_exam_courses_course_id
    on public.exam_courses(course_id);

create index idx_questions_exam_id
    on public.questions(exam_id);

create index idx_question_options_question_id
    on public.question_options(question_id);


-- ============================================================
-- UPDATED_AT TRIGGERS
-- ============================================================
-- The academic foundation already created the shared
-- set_updated_at() function.
-- We reuse it here.
-- ============================================================

create trigger exams_set_updated_at
before update on public.exams
for each row
execute function public.set_updated_at();


create trigger questions_set_updated_at
before update on public.questions
for each row
execute function public.set_updated_at();


-- ============================================================
-- COMMENTS
-- ============================================================

comment on table public.exams is
    'Defines an examination event/configuration for an academic session.';

comment on table public.exam_courses is
    'Associates one or more courses/papers with an examination.';

comment on table public.questions is
    'Questions belonging to a specific examination.';

comment on table public.question_options is
    'Answer options for examination questions. Correct answers must never be exposed to students.';

comment on column public.question_options.is_correct is
    'Authoritative answer key. Must only be accessible to trusted server-side scoring operations.';