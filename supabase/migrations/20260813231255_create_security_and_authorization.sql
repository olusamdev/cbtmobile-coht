-- ============================================================
-- MIGRATION 6: SECURITY AND AUTHORIZATION
-- PART 1: RLS FOUNDATION + STUDENT READ/WRITE BOUNDARIES
-- ============================================================
--
-- IMPORTANT:
-- This migration is intentionally being built in stages.
--
-- Part 1 establishes Row Level Security on the core tables and
-- gives authenticated students access only to records belonging
-- to their own authenticated identity.
--
-- Privileged Admin/Superadmin operations will be added only
-- after this foundation has been verified.
-- ============================================================


-- ============================================================
-- 1. ENABLE ROW LEVEL SECURITY
-- ============================================================

alter table public.profiles enable row level security;

alter table public.students enable row level security;

alter table public.student_course_registrations enable row level security;

alter table public.exams enable row level security;

alter table public.exam_courses enable row level security;

alter table public.questions enable row level security;

alter table public.question_options enable row level security;

alter table public.exam_sessions enable row level security;

alter table public.exam_session_courses enable row level security;

alter table public.answers enable row level security;

alter table public.strikes enable row level security;

alter table public.time_extensions enable row level security;

alter table public.supervisor_alerts enable row level security;

alter table public.exam_session_events enable row level security;

alter table public.exam_results enable row level security;

alter table public.result_events enable row level security;

alter table public.result_mail_requests enable row level security;

alter table public.result_access_events enable row level security;


-- ============================================================
-- 2. HELPER FUNCTION:
-- CURRENT PROFILE
-- ============================================================
-- Returns the application role for the authenticated user.
--
-- SECURITY DEFINER is used so the function can read the profile
-- without creating a circular dependency in profile policies.
--
-- search_path is deliberately restricted.
-- ============================================================

create or replace function public.current_user_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
    select role
    from public.profiles
    where id = auth.uid()
      and is_active = true
    limit 1;
$$;


-- ============================================================
-- 3. HELPER FUNCTION:
-- CURRENT STUDENT ID
-- ============================================================

create or replace function public.current_student_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select student_id
    from public.profiles
    where id = auth.uid()
      and role = 'student'
      and is_active = true
    limit 1;
$$;


-- ============================================================
-- 4. PROFILES
-- ============================================================
-- Students may read their own profile.
--
-- There is deliberately NO student INSERT/UPDATE/DELETE policy.
-- Therefore students cannot alter their own role or student_id.
-- ============================================================

create policy profiles_student_select_own
on public.profiles
for select
to authenticated
using (
    id = auth.uid()
);


-- ============================================================
-- 5. STUDENTS
-- ============================================================
-- Students may read only their own academic record.
--
-- No student INSERT/UPDATE/DELETE policy is created.
-- ============================================================

create policy students_student_select_own
on public.students
for select
to authenticated
using (
    id = public.current_student_id()
);


-- ============================================================
-- 6. STUDENT COURSE REGISTRATIONS
-- ============================================================

create policy registrations_student_select_own
on public.student_course_registrations
for select
to authenticated
using (
    student_id = public.current_student_id()
);


-- ============================================================
-- 7. EXAMS
-- ============================================================
-- Students may see active exams only when the exam is relevant
-- to a course they are registered for.
--
-- This is intentionally a read-only policy.
-- Students cannot create, modify, activate, or deactivate exams.
-- ============================================================

create policy exams_student_select_active
on public.exams
for select
to authenticated
using (
    is_active = true
    and exists (
        select 1
        from public.student_course_registrations scr
        join public.exam_courses ec
            on ec.course_id = scr.course_id
        where scr.student_id = public.current_student_id()
          and ec.exam_id = exams.id
    )
);


-- ============================================================
-- 8. EXAM COURSES
-- ============================================================

create policy exam_courses_student_select
on public.exam_courses
for select
to authenticated
using (
    exists (
        select 1
        from public.student_course_registrations scr
        where scr.student_id = public.current_student_id()
          and scr.course_id = exam_courses.course_id
    )
);


-- ============================================================
-- 9. QUESTIONS
-- ============================================================
-- Students may read questions belonging to an active exam they
-- are registered for.
--
-- IMPORTANT:
-- The questions table itself contains no answer key.
-- ============================================================

create policy questions_student_select
on public.questions
for select
to authenticated
using (
    exists (
        select 1
        from public.exams e
        join public.exam_courses ec
            on ec.exam_id = e.id
        join public.student_course_registrations scr
            on scr.course_id = ec.course_id
        where e.id = questions.exam_id
          and e.is_active = true
          and scr.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 10. QUESTION OPTIONS
-- ============================================================
-- CRITICAL SECURITY POINT:
--
-- We DO NOT create a normal SELECT policy on question_options.
--
-- A direct SELECT would expose:
--
--     is_correct
--
-- to the student client.
--
-- Student-facing question delivery will later use a secure
-- function/view that deliberately omits is_correct.
-- ============================================================


-- ============================================================
-- 11. EXAM SESSIONS
-- ============================================================
-- Students may read only their own sessions.
--
-- No direct student INSERT/UPDATE/DELETE policy is created.
-- Session creation and state transitions will be performed by
-- secure server-side operations.
-- ============================================================

create policy exam_sessions_student_select_own
on public.exam_sessions
for select
to authenticated
using (
    student_id = public.current_student_id()
);


-- ============================================================
-- 12. EXAM SESSION COURSES
-- ============================================================

create policy exam_session_courses_student_select_own
on public.exam_session_courses
for select
to authenticated
using (
    exists (
        select 1
        from public.exam_sessions es
        where es.id = exam_session_courses.exam_session_id
          and es.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 13. ANSWERS
-- ============================================================
-- Students may read their own answers.
--
-- Direct answer INSERT/UPDATE will be added through a controlled
-- operation so that answer ownership and session state can be
-- checked centrally.
-- ============================================================

create policy answers_student_select_own
on public.answers
for select
to authenticated
using (
    exists (
        select 1
        from public.exam_sessions es
        where es.id = answers.exam_session_id
          and es.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 14. STRIKES
-- ============================================================

create policy strikes_student_select_own
on public.strikes
for select
to authenticated
using (
    exists (
        select 1
        from public.exam_sessions es
        where es.id = strikes.exam_session_id
          and es.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 15. TIME EXTENSIONS
-- ============================================================
-- Students may see time extensions belonging to their own
-- examination sessions.
--
-- They cannot create or modify extensions themselves.
-- ============================================================

create policy time_extensions_student_select_own
on public.time_extensions
for select
to authenticated
using (
    exists (
        select 1
        from public.exam_sessions es
        where es.id = time_extensions.exam_session_id
          and es.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 16. SUPERVISOR ALERTS
-- ============================================================
-- Students may create an alert associated with their own session
-- later through a controlled operation.
--
-- For now, no direct INSERT policy is granted.
-- Students may only read their own alerts.
-- ============================================================

create policy supervisor_alerts_student_select_own
on public.supervisor_alerts
for select
to authenticated
using (
    exists (
        select 1
        from public.exam_sessions es
        where es.id = supervisor_alerts.exam_session_id
          and es.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 17. EXAM SESSION EVENTS
-- ============================================================
-- Events are audit records.
--
-- Students may read events associated with their own session,
-- but cannot directly create/modify/delete them.
-- ============================================================

create policy exam_session_events_student_select_own
on public.exam_session_events
for select
to authenticated
using (
    exists (
        select 1
        from public.exam_sessions es
        where es.id = exam_session_events.exam_session_id
          and es.student_id = public.current_student_id()
    )
);


-- ============================================================
-- 18. EXAM RESULTS
-- ============================================================
-- Students may read their own FINAL result only when the exam
-- allows instant result visibility.
--
-- This is deliberately restrictive.
--
-- Students cannot insert, update, or delete results.
-- ============================================================

create policy exam_results_student_select_own_when_allowed
on public.exam_results
for select
to authenticated
using (
    student_id = public.current_student_id()
    and status = 'final'
    and exists (
        select 1
        from public.exams e
        where e.id = exam_results.exam_id
          and e.show_instant_results = true
    )
);


-- ============================================================
-- 19. RESULT EVENTS
-- ============================================================
-- Students do not need direct access to internal result audit
-- events.
--
-- No student policy is created.
-- ============================================================


-- ============================================================
-- 20. RESULT MAIL REQUESTS
-- ============================================================
-- Students do not access lecturer result-mail workflows.
-- ============================================================


-- ============================================================
-- 21. RESULT ACCESS EVENTS
-- ============================================================
-- Students do not directly access audit records.
-- ============================================================


-- ============================================================
-- 22. COMMENTS
-- ============================================================

comment on function public.current_user_role() is
    'Returns the active application role of the authenticated user.';

comment on function public.current_student_id() is
    'Returns the academic student ID associated with the authenticated student account.'; 

-- ============================================================
-- MIGRATION 6: SECURITY AND AUTHORIZATION
-- PART 2: ADMIN / SUPERADMIN MONITORING ACCESS
-- ============================================================
--
-- This section grants read/monitoring access only.
--
-- Sensitive mutations such as:
--   - pause/resume
--   - force submit
--   - strike clearing
--   - result creation
--   - role changes
--   - exam configuration changes
--
-- will be performed through controlled security-definer
-- functions in the next stage.
--
-- IMPORTANT:
-- question_options deliberately remains without a SELECT policy.
-- This protects the authoritative answer key.
-- ============================================================


-- ============================================================
-- 1. PROFILES
-- ============================================================

create policy profiles_admin_select
on public.profiles
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 2. STUDENTS
-- ============================================================

create policy students_admin_select
on public.students
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 3. STUDENT COURSE REGISTRATIONS
-- ============================================================

create policy registrations_admin_select
on public.student_course_registrations
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 4. EXAMS
-- ============================================================

create policy exams_admin_select
on public.exams
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 5. EXAM COURSES
-- ============================================================

create policy exam_courses_admin_select
on public.exam_courses
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 6. QUESTIONS
-- ============================================================
-- Admins and Superadmins may inspect the question bank.
--
-- This does NOT expose the answer key because the answer key
-- lives in question_options.is_correct and question_options
-- has no direct SELECT policy.
-- ============================================================

create policy questions_admin_select
on public.questions
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 7. EXAM SESSIONS
-- ============================================================

create policy exam_sessions_admin_select
on public.exam_sessions
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 8. EXAM SESSION COURSES
-- ============================================================

create policy exam_session_courses_admin_select
on public.exam_session_courses
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 9. ANSWERS
-- ============================================================
-- Admins need this for examination monitoring.
--
-- This does NOT expose the correct answer because answers contain
-- student submissions, while the authoritative key remains
-- protected inside question_options.
-- ============================================================

create policy answers_admin_select
on public.answers
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 10. STRIKES
-- ============================================================

create policy strikes_admin_select
on public.strikes
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 11. TIME EXTENSIONS
-- ============================================================

create policy time_extensions_admin_select
on public.time_extensions
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 12. SUPERVISOR ALERTS
-- ============================================================

create policy supervisor_alerts_admin_select
on public.supervisor_alerts
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 13. EXAM SESSION EVENTS
-- ============================================================
-- Audit trail is visible to administrators for monitoring.
-- ============================================================

create policy exam_session_events_admin_select
on public.exam_session_events
for select
to authenticated
using (
    public.current_user_role() in ('admin', 'superadmin')
);


-- ============================================================
-- 14. EXAM RESULTS
-- ============================================================
-- IMPORTANT:
--
-- Admin has NO SELECT policy here.
--
-- Only Superadmin can directly read finalized results.
-- ============================================================

create policy exam_results_superadmin_select
on public.exam_results
for select
to authenticated
using (
    public.current_user_role() = 'superadmin'
);


-- ============================================================
-- 15. RESULT EVENTS
-- ============================================================

create policy result_events_superadmin_select
on public.result_events
for select
to authenticated
using (
    public.current_user_role() = 'superadmin'
);


-- ============================================================
-- 16. RESULT MAIL REQUESTS
-- ============================================================

create policy result_mail_requests_superadmin_select
on public.result_mail_requests
for select
to authenticated
using (
    public.current_user_role() = 'superadmin'
);


-- ============================================================
-- 17. RESULT ACCESS EVENTS
-- ============================================================

create policy result_access_events_superadmin_select
on public.result_access_events
for select
to authenticated
using (
    public.current_user_role() = 'superadmin'
);


-- ============================================================
-- 18. IMPORTANT SECURITY NOTE
-- ============================================================
--
-- There is intentionally NO policy here:
--
--     question_options_admin_select
--
-- or:
--
--     question_options_superadmin_select
--
-- The authoritative answer key must remain inaccessible through
-- direct client queries.
--
-- Controlled server-side/database functions will be responsible
-- for operations that legitimately require the answer key.
-- ============================================================