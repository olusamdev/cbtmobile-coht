-- Verifies the v2 exam path: paper listing, authoritative clock, pause and
-- extension accounting, deadline enforcement and submission.
-- Run against a scratch database; everything is rolled back at the end.
begin;
select set_config('request.headers', '{"x-device-id":"test-device"}', true);
insert into public.system_settings(key,value) values ('require_student_photo','false'::jsonb) on conflict (key) do update set value='false'::jsonb;

do $$
declare
  v_ses uuid; v_exam uuid; v_stu uuid; v_user uuid := gen_random_uuid();
  v_course uuid; v_other_course uuid; v_ec uuid; v_q uuid; v_opt uuid;
begin
  insert into public.academic_sessions(name) values ('V2TEST/' || gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no, full_name) values ('V2/001', 'V2 Student') returning id into v_stu;
  insert into auth.users(id, email, encrypted_password) values (v_user, 'v2/001@student.coht.local', extensions.crypt('OLDPW1', extensions.gen_salt('bf')));
  insert into public.profiles(id, role, student_id) values (v_user, 'student', v_stu);

  insert into public.courses(code, title) values ('V2A101', 'Registered course') returning id into v_course;
  insert into public.courses(code, title) values ('V2B202', 'Unregistered course') returning id into v_other_course;
  insert into public.student_course_registrations(student_id, course_id, academic_session_id) values (v_stu, v_course, v_ses);

  insert into public.exams(academic_session_id, title, mode, duration_minutes, is_active)
  values (v_ses, 'V2 exam', 'regular', 60, true) returning id into v_exam;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_exam, v_course, 1) returning id into v_ec;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_exam, v_other_course, 2);

  insert into public.questions(exam_id, exam_course_id, question_number, question_text)
  values (v_exam, v_ec, 1, 'Q1?') returning id into v_q;
  insert into public.question_options(question_id, option_key, option_text, is_correct) values (v_q, 'A', 'yes', true);
  insert into public.question_options(question_id, option_key, option_text, is_correct) values (v_q, 'B', 'no', false);

  perform set_config('t.exam', v_exam::text, true);
  perform set_config('t.ec', v_ec::text, true);
  perform set_config('t.user', v_user::text, true);
  perform set_config('t.student', v_stu::text, true);
  perform set_config('t.q', v_q::text, true);
  perform set_config('t.optA', (select id::text from public.question_options where question_id = v_q and option_key = 'A'), true);
  perform set_config('t.optB', (select id::text from public.question_options where question_id = v_q and option_key = 'B'), true);
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.user'), true);

-- 1. Paper listing only shows registered papers
do $$
declare n integer; r record;
begin
  select count(*) into n from public.list_my_exam_papers(current_setting('t.exam')::uuid);
  assert n = 1, 'only the registered paper should be listed, got ' || n;
  select * into r from public.list_my_exam_papers(current_setting('t.exam')::uuid);
  assert r.course_code = 'V2A101' and r.paper_status = 'not_started', 'paper should be not_started';
end $$;

-- 2. Start and read the clock
do $$
declare s record; c record; started record;
begin
  select * into started from public.start_exam_paper_for_student(current_setting('t.exam')::uuid, current_setting('t.ec')::uuid);
  perform set_config('t.sid', started.exam_session_id::text, true);
  perform set_config('t.sc', started.exam_session_course_id::text, true);

  select * into c from public.get_exam_clock_v2(started.exam_session_id);
  assert c.session_status = 'active', 'session should be active';
  assert c.active_exam_session_course_id = started.exam_session_course_id, 'active paper id';
  assert c.expires_at - c.server_now between interval '59 minutes' and interval '60 minutes 1 second', 'about 60 minutes should remain';
  perform set_config('t.expires', c.expires_at::text, true);

  assert (select paper_status from public.list_my_exam_papers(current_setting('t.exam')::uuid) limit 1) = 'active', 'paper should now be active';
end $$;

-- 3. Saving works before the deadline
do $$
declare opt uuid;
begin
  opt := current_setting('t.optA')::uuid;
  assert public.save_exam_answer_for_student(current_setting('t.sid')::uuid, current_setting('t.sc')::uuid, current_setting('t.q')::uuid, opt), 'save should succeed';
end $$;

-- 4. Extension and pause accounting (superuser edits stand in for admin actions)
reset role;
update public.exam_sessions set total_extension_seconds = 600 where id = current_setting('t.sid')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.user'), true);
do $$
declare c record;
begin
  select * into c from public.get_exam_clock_v2(current_setting('t.sid')::uuid);
  assert abs(extract(epoch from c.expires_at - current_setting('t.expires')::timestamptz) - 600) < 2, 'extension must add 600 s';
end $$;

reset role;
update public.exam_sessions set status = 'paused', paused_at = now() - interval '120 seconds' where id = current_setting('t.sid')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.user'), true);
do $$
declare c record;
begin
  select * into c from public.get_exam_clock_v2(current_setting('t.sid')::uuid);
  assert c.session_status = 'paused', 'status should be paused';
  assert abs(extract(epoch from c.expires_at - current_setting('t.expires')::timestamptz) - 720) < 2, 'paused time must push the deadline (600 + 120)';
end $$;

reset role;
update public.exam_sessions set status = 'active', paused_at = null, total_paused_seconds = 120 where id = current_setting('t.sid')::uuid;

-- 5. Deadline enforcement
update public.exam_session_courses set paper_expires_at = now() - interval '5 minutes' where id = current_setting('t.sc')::uuid;
update public.exam_sessions set total_extension_seconds = 0, total_paused_seconds = 0 where id = current_setting('t.sid')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.user'), true);
do $$
declare opt uuid;
begin
  opt := current_setting('t.optB')::uuid;
  begin
    perform public.save_exam_answer_for_student(current_setting('t.sid')::uuid, current_setting('t.sc')::uuid, current_setting('t.q')::uuid, opt);
    raise exception 'save after the deadline was accepted';
  exception when others then
    assert sqlerrm = 'Time is up for this examination paper', 'unexpected error: ' || sqlerrm;
  end;
end $$;

-- an extension that covers the gap re-opens saving
reset role;
update public.exam_sessions set total_extension_seconds = 900 where id = current_setting('t.sid')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.user'), true);
do $$
declare opt uuid;
begin
  opt := current_setting('t.optB')::uuid;
  assert public.save_exam_answer_for_student(current_setting('t.sid')::uuid, current_setting('t.sc')::uuid, current_setting('t.q')::uuid, opt), 'save after extension should succeed';
end $$;

-- 6. Late submission is still scored; regular mode ends the session
do $$
declare r record;
begin
  -- students submit through submit_exam_paper_for_student; the scoring function is called directly here
  execute 'reset role';
  select * into r from public.submit_exam_paper_v2(current_setting('t.sc')::uuid, gen_random_uuid());
  execute 'set local role authenticated';
  assert r.all_papers_submitted = true and r.otp_rotation_required = true, 'regular submit ends the session';
  assert r.wrong_answers = 1 and r.correct_answers = 0, 'last saved answer (B, wrong) is scored';
end $$;

reset role;
do $$ begin
  assert (select status from public.exam_sessions where id = current_setting('t.sid')::uuid) = 'submitted', 'session submitted';
  assert exists (select 1 from public.exam_session_events where exam_session_id = current_setting('t.sid')::uuid and event_type = 'OTP_ROTATED'), 'OTP rotated on submission';
end $$;

-- 7. Pharmacy PreNational: concurrent papers, switching, one shared deadline, atomic submit
reset role;
do $$
declare
  v_ses uuid := (select academic_session_id from public.exams where id = current_setting('t.exam')::uuid);
  v_stu uuid := current_setting('t.student')::uuid;
  v_c1 uuid; v_c2 uuid; v_exam uuid; v_ec1 uuid; v_ec2 uuid; v_q1 uuid; v_q2 uuid;
begin
  insert into public.courses(code, title) values ('PN101', 'PN one') returning id into v_c1;
  insert into public.courses(code, title) values ('PN102', 'PN two') returning id into v_c2;
  insert into public.student_course_registrations(student_id, course_id, academic_session_id) values (v_stu, v_c1, v_ses), (v_stu, v_c2, v_ses);
  insert into public.exams(academic_session_id, title, mode, duration_minutes, is_active)
  values (v_ses, 'PN exam', 'pharmacy_prenational', 90, true) returning id into v_exam;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_exam, v_c1, 1) returning id into v_ec1;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_exam, v_c2, 2) returning id into v_ec2;
  insert into public.questions(exam_id, exam_course_id, question_number, question_text) values (v_exam, v_ec1, 1, 'P1Q1') returning id into v_q1;
  insert into public.question_options(question_id, option_key, option_text, is_correct) values (v_q1, 'A', 'a', true), (v_q1, 'B', 'b', false);
  insert into public.questions(exam_id, exam_course_id, question_number, question_text) values (v_exam, v_ec2, 1, 'P2Q1') returning id into v_q2;
  insert into public.question_options(question_id, option_key, option_text, is_correct) values (v_q2, 'A', 'a', true), (v_q2, 'B', 'b', false);
  perform set_config('t.pnexam', v_exam::text, true);
  perform set_config('t.pnec1', v_ec1::text, true);
  perform set_config('t.pnec2', v_ec2::text, true);
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.user'), true);
do $$
declare s1 record; s2 record; st record; n integer; r record; q_text text;
begin
  select * into s1 from public.start_exam_paper_for_student(current_setting('t.pnexam')::uuid, current_setting('t.pnec1')::uuid);
  assert s1.mode = 'pharmacy_prenational' and s1.global_expires_at is not null, 'prenational has a global deadline';
  select * into s2 from public.start_exam_paper_for_student(current_setting('t.pnexam')::uuid, current_setting('t.pnec2')::uuid);
  assert s2.exam_session_id = s1.exam_session_id, 'switching papers stays in the same session';
  assert s2.global_expires_at = s1.global_expires_at, 'the deadline is shared and does not reset on switch';

  select * into st from public.get_exam_session_state_v2(s1.exam_session_id);
  assert st.active_exam_session_course_id = s2.exam_session_course_id, 'second paper is now active';
  assert jsonb_array_length(st.papers) = 2, 'state lists both papers';

  select count(*), min(question_text) into n, q_text from public.get_exam_questions_for_student(s1.exam_session_id, s2.exam_session_course_id);
  assert q_text = 'P2Q1', 'questions are for the active paper only, got ' || coalesce(q_text, 'null');

  -- students submit through submit_exam_paper_for_student; the scoring function is called directly here
  execute 'reset role';
  select * into r from public.submit_exam_paper_v2(s2.exam_session_course_id, gen_random_uuid());
  execute 'set local role authenticated';
  assert r.all_papers_submitted = true, 'prenational submit ends every paper';
  perform set_config('t.pnsid', s1.exam_session_id::text, true);
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.exam_results where exam_session_id = current_setting('t.pnsid')::uuid) = 2, 'both papers scored';
end $$;

select 'ALL V2 CHECKS PASSED' as result;
rollback;
