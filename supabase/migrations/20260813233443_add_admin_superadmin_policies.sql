-- ============================================================
-- MIGRATION 7: ADMIN / SUPERADMIN POLICIES
-- ============================================================
--
-- Adds administrative read/monitoring access.
--
-- IMPORTANT:
-- This migration does NOT grant direct mutation privileges.
-- Sensitive operations such as pause, resume, force-submit,
-- strike clearing, result creation, and role management will
-- be implemented through controlled database functions later.
--
-- The question answer key remains protected because
-- question_options receives NO SELECT policy.
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
-- This does NOT expose is_correct because that column lives
-- in question_options, which deliberately has no SELECT policy.
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
-- Admin deliberately has NO SELECT access.
--
-- Superadmin is the first role permitted to directly inspect
-- examination results.
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
-- IMPORTANT SECURITY RULE
-- ============================================================
--
-- There is intentionally NO policy on question_options.
--
-- Therefore:
--
--     Student     → cannot read question_options
--     Admin       → cannot read question_options
--     Superadmin  → cannot directly read question_options
--
-- The authoritative answer key will only be accessed by secure
-- server/database functions when absolutely necessary.
-- ============================================================