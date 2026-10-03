-- COHT CBT: SuperAdmin scoped data-clear actions.
-- These actions are deliberately narrower than superadmin_reset_application_data().
-- They never truncate the application schema and never touch departments/programmes.

create or replace function public.superadmin_clear_registrations()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_count integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  delete from public.student_course_registrations;
  get diagnostics v_count = row_count;

  return jsonb_build_object('status','cleared','deleted',v_count);
end;
$$;
revoke all on function public.superadmin_clear_registrations() from public;
grant execute on function public.superadmin_clear_registrations() to authenticated;

create or replace function public.superadmin_clear_courses()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_count integer;
  v_registered integer;
  v_exam_papers integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select count(*) into v_registered
  from public.student_course_registrations;

  select count(*) into v_exam_papers
  from public.exam_courses;

  -- Courses are intentionally NOT cascaded into registrations or examination papers.
  -- This prevents a correction action from silently destroying operational data.
  if v_registered > 0 or v_exam_papers > 0 then
    raise exception 'Courses cannot be cleared while registrations (%) or examination papers (%) exist. Clear those dependent records first.', v_registered, v_exam_papers;
  end if;

  delete from public.courses;
  get diagnostics v_count = row_count;

  return jsonb_build_object('status','cleared','deleted',v_count);
end;
$$;
revoke all on function public.superadmin_clear_courses() from public;
grant execute on function public.superadmin_clear_courses() to authenticated;

create or replace function public.superadmin_clear_question_bank()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_questions integer;
  v_answers integer;
  v_options integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select count(*) into v_answers
  from public.answers a
  where a.question_id in (select q.id from public.questions q);

  -- A question bank correction must never erase student answers from an exam session.
  if v_answers > 0 then
    raise exception 'Question Bank cannot be cleared because % student answer record(s) reference the questions. Clear/finish those examination sessions first.', v_answers;
  end if;

  delete from public.question_options
  where question_id in (select id from public.questions);
  get diagnostics v_options = row_count;

  delete from public.questions;
  get diagnostics v_questions = row_count;

  return jsonb_build_object('status','cleared','questions_deleted',v_questions,'options_deleted',v_options);
end;
$$;
revoke all on function public.superadmin_clear_question_bank() from public;
grant execute on function public.superadmin_clear_question_bank() to authenticated;

create or replace function public.superadmin_clear_students()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_students uuid[];
  v_student_count integer := 0;
  v_auth_count integer := 0;
  v_reg_count integer := 0;
  v_result_count integer := 0;
  v_mail_count integer := 0;
  v_otp_count integer := 0;
  v_attendance_count integer := 0;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]), count(*)
    into v_students, v_student_count
  from public.students;

  if v_student_count = 0 then
    return jsonb_build_object('status','cleared','students_deleted',0,'student_auth_accounts_removed',0);
  end if;

  -- Remove result mail requests first because they intentionally use ON DELETE RESTRICT.
  delete from public.result_mail_requests
  where exam_result_id in (
    select er.id from public.exam_results er where er.student_id = any(v_students)
  );
  get diagnostics v_mail_count = row_count;

  -- Results are retained only for active application data; deleting them cascades their audit rows.
  delete from public.exam_results
  where student_id = any(v_students);
  get diagnostics v_result_count = row_count;

  -- Exam-session child tables cascade from exam_sessions. Answers are included in that cascade.
  delete from public.exam_sessions
  where student_id = any(v_students);

  delete from public.student_exam_otps
  where student_id = any(v_students);
  get diagnostics v_otp_count = row_count;

  delete from public.exam_attendance
  where student_id = any(v_students);
  get diagnostics v_attendance_count = row_count;

  delete from public.student_course_registrations
  where student_id = any(v_students);
  get diagnostics v_reg_count = row_count;

  -- Remove student Auth accounts where they exist. Their public profiles cascade away.
  delete from auth.users
  where id in (
    select p.id from public.profiles p
    where p.role = 'student' and p.student_id = any(v_students)
  );
  get diagnostics v_auth_count = row_count;

  -- Handle imported student rows without an Auth account/profile as well.
  delete from public.profiles
  where role = 'student' and student_id = any(v_students);

  delete from public.students
  where id = any(v_students);

  return jsonb_build_object(
    'status','cleared',
    'students_deleted',v_student_count,
    'student_auth_accounts_removed',v_auth_count,
    'registrations_deleted',v_reg_count,
    'results_deleted',v_result_count,
    'result_mail_requests_deleted',v_mail_count,
    'student_otps_deleted',v_otp_count,
    'attendance_deleted',v_attendance_count
  );
end;
$$;
revoke all on function public.superadmin_clear_students() from public;
grant execute on function public.superadmin_clear_students() to authenticated;
