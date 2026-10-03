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


-- Fix import confirmation to persist the server-normalized rows produced during validation.
-- The original confirmation path re-validated the raw CSV/JSON rows but then attempted
-- to read UUID fields (department_id/programme_id/course_id/session_id) that are not
-- present in the human-facing import file. This caused validated imports not to persist.
create or replace function public.superadmin_confirm_import(p_entity text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles%rowtype;
  r jsonb;
  v_imported int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_student_id uuid;
  v_course_id uuid;
  v_session_id uuid;
  v_question_id uuid;
  v_existing boolean;
  v_validation jsonb;
  v_normalized jsonb;
  v_reg text;
  v_code text;
  v_type text;
  v_exam uuid;
  v_qnum int;
  v_correct text;
begin
  if v_user is null then raise exception 'Authentication required.'; end if;
  select * into v_profile from public.profiles where id=v_user;
  if v_profile.role <> 'superadmin' or not v_profile.is_active then
    raise exception 'SuperAdmin authorization required.';
  end if;
  if p_entity not in ('students','courses','registrations','questions') then
    raise exception 'Unsupported import type: %',p_entity;
  end if;
  if jsonb_array_length(coalesce(p_rows,'[]'::jsonb)) > 5000 then
    raise exception 'Import is limited to 5,000 rows per confirmation batch.';
  end if;

  -- Validate the human-facing rows, then persist exactly the server-normalized rows.
  v_validation := public.superadmin_validate_import(p_entity, p_rows);
  if coalesce((v_validation->>'errorRows')::int, 0) > 0 then
    raise exception 'Import contains % validation error(s). Validate and correct the file before confirming.', (v_validation->>'errorRows')::int;
  end if;
  v_normalized := coalesce(v_validation->'normalizedRows','[]'::jsonb);

  if p_entity='students' then
    for r in select value from jsonb_array_elements(v_normalized) loop
      v_reg := trim(r->>'reg_no');
      select id into v_student_id from public.students where lower(reg_no)=lower(v_reg);
      if v_student_id is null then
        insert into public.students(reg_no,full_name,programme_id,level)
        values(v_reg,r->>'full_name',(r->>'programme_id')::uuid,nullif(r->>'level','')::int);
        v_imported:=v_imported+1;
      else
        update public.students
        set full_name=r->>'full_name', programme_id=(r->>'programme_id')::uuid,
            level=nullif(r->>'level','')::int, is_active=true, updated_at=now()
        where id=v_student_id;
        v_updated:=v_updated+1;
      end if;
    end loop;

  elsif p_entity='courses' then
    for r in select value from jsonb_array_elements(v_normalized) loop
      v_code := upper(trim(r->>'code'));
      select id into v_course_id from public.courses where upper(code)=v_code;
      if v_course_id is null then
        insert into public.courses(code,title,department_id,programme_id,level,semester,credit_units)
        values(v_code,r->>'title',(r->>'department_id')::uuid,(r->>'programme_id')::uuid,
               nullif(r->>'level','')::int,nullif(r->>'semester','')::int,nullif(r->>'credit_units','')::int);
        v_imported:=v_imported+1;
      else
        update public.courses
        set title=r->>'title', department_id=(r->>'department_id')::uuid,
            programme_id=(r->>'programme_id')::uuid, level=nullif(r->>'level','')::int,
            semester=nullif(r->>'semester','')::int, credit_units=nullif(r->>'credit_units','')::int,
            is_active=true, updated_at=now()
        where id=v_course_id;
        v_updated:=v_updated+1;
      end if;
    end loop;

  elsif p_entity='registrations' then
    for r in select value from jsonb_array_elements(v_normalized) loop
      select id into v_student_id from public.students
      where lower(reg_no)=lower(trim(r->>'reg_no')) and is_active;
      v_course_id := (r->>'course_id')::uuid;
      v_session_id := (r->>'academic_session_id')::uuid;
      v_type := lower(coalesce(r->>'registration_type','regular'));
      select exists(
        select 1 from public.student_course_registrations
        where student_id=v_student_id and course_id=v_course_id and academic_session_id=v_session_id
      ) into v_existing;
      if v_existing then
        v_skipped:=v_skipped+1;
      else
        insert into public.student_course_registrations(student_id,course_id,academic_session_id,registration_type)
        values(v_student_id,v_course_id,v_session_id,v_type);
        v_imported:=v_imported+1;
      end if;
    end loop;

  else
    for r in select value from jsonb_array_elements(v_normalized) loop
      v_exam := (r->>'exam_id')::uuid;
      v_qnum := (r->>'question_number')::int;
      v_correct := upper(r->>'correct_option');
      select id into v_question_id from public.questions where exam_id=v_exam and question_number=v_qnum;
      if v_question_id is null then
        insert into public.questions(exam_id,question_number,question_text)
        values(v_exam,v_qnum,r->>'question_text') returning id into v_question_id;
        v_imported:=v_imported+1;
      else
        update public.questions set question_text=r->>'question_text',updated_at=now() where id=v_question_id;
        v_updated:=v_updated+1;
      end if;
      delete from public.question_options where question_id=v_question_id;
      insert into public.question_options(question_id,option_key,option_text,is_correct)
      select v_question_id, x.k, x.v, x.k=v_correct
      from jsonb_each_text(jsonb_build_object(
        'A',r->>'option_a','B',r->>'option_b','C',r->>'option_c','D',r->>'option_d','E',r->>'option_e'
      )) x(k,v)
      where nullif(trim(x.v),'') is not null;
    end loop;
  end if;

  return jsonb_build_object('entity',p_entity,'imported',v_imported,'updated',v_updated,'skipped',v_skipped);
end;
$$;

grant execute on function public.superadmin_confirm_import(text,jsonb) to authenticated;
