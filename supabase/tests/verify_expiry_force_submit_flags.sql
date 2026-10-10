-- Verifies the expiry sweeper, the corrected force-submit, and persistent flags.
-- Run against a scratch database; everything is rolled back at the end.
begin;
select set_config('request.headers', '{"x-device-id":"test-device"}', true);
insert into public.system_settings(key,value) values ('require_student_photo','false'::jsonb) on conflict (key) do update set value='false'::jsonb;

do $$
declare
  v_ses uuid; v_s1 uuid; v_s2 uuid; v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid(); v_adm uuid := gen_random_uuid();
  v_c1 uuid; v_c2 uuid; v_e1 uuid; v_e2 uuid; v_ec1 uuid; v_ec2a uuid; v_ec2b uuid;
  v_q1 uuid; v_qa1 uuid; v_qa2 uuid; v_qb1 uuid;
begin
  insert into public.academic_sessions(name) values ('EXP/' || gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no, full_name) values ('EXP/001', 'One') returning id into v_s1;
  insert into public.students(reg_no, full_name) values ('EXP/002', 'Two') returning id into v_s2;
  insert into auth.users(id, email, encrypted_password) values
    (v_u1, 'exp/001@student.coht.local', extensions.crypt('OLD1', extensions.gen_salt('bf'))),
    (v_u2, 'exp/002@student.coht.local', extensions.crypt('OLD2', extensions.gen_salt('bf'))),
    (v_adm, 'adm@test.local', null);
  insert into public.profiles(id, role, student_id) values (v_u1, 'student', v_s1), (v_u2, 'student', v_s2);
  insert into public.profiles(id, role) values (v_adm, 'admin');

  insert into public.courses(code, title) values ('EXPA1', 'Course A') returning id into v_c1;
  insert into public.courses(code, title) values ('EXPB2', 'Course B') returning id into v_c2;
  insert into public.student_course_registrations(student_id, course_id, academic_session_id) values
    (v_s1, v_c1, v_ses), (v_s1, v_c2, v_ses), (v_s2, v_c1, v_ses);

  -- Regular exam, one question
  insert into public.exams(academic_session_id, title, mode, duration_minutes, is_active) values (v_ses, 'Regular', 'regular', 60, true) returning id into v_e1;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_e1, v_c1, 1) returning id into v_ec1;
  insert into public.questions(exam_id, exam_course_id, question_number, question_text) values (v_e1, v_ec1, 1, 'Q?') returning id into v_q1;
  insert into public.question_options(question_id, option_key, option_text, is_correct) values (v_q1, 'A', 'yes', true), (v_q1, 'B', 'no', false);

  -- Pharmacy exam, paper A has 2 questions, paper B has 1
  insert into public.exams(academic_session_id, title, mode, duration_minutes, is_active) values (v_ses, 'Pharmacy', 'pharmacy_prenational', 120, true) returning id into v_e2;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_e2, v_c1, 1) returning id into v_ec2a;
  insert into public.exam_courses(exam_id, course_id, paper_order) values (v_e2, v_c2, 2) returning id into v_ec2b;
  insert into public.questions(exam_id, exam_course_id, question_number, question_text) values (v_e2, v_ec2a, 1, 'A1?') returning id into v_qa1;
  insert into public.questions(exam_id, exam_course_id, question_number, question_text) values (v_e2, v_ec2a, 2, 'A2?') returning id into v_qa2;
  insert into public.questions(exam_id, exam_course_id, question_number, question_text) values (v_e2, v_ec2b, 1, 'B1?') returning id into v_qb1;
  insert into public.question_options(question_id, option_key, option_text, is_correct)
    select q, 'A', 'right', true from unnest(array[v_qa1, v_qa2, v_qb1]) q;
  insert into public.question_options(question_id, option_key, option_text, is_correct)
    select q, 'B', 'wrong', false from unnest(array[v_qa1, v_qa2, v_qb1]) q;

  perform set_config('t.u1', v_u1::text, true); perform set_config('t.u2', v_u2::text, true); perform set_config('t.adm', v_adm::text, true);
  perform set_config('t.s1', v_s1::text, true);  perform set_config('t.s2', v_s2::text, true);
  perform set_config('t.e1', v_e1::text, true);  perform set_config('t.e2', v_e2::text, true);
  perform set_config('t.ec1', v_ec1::text, true); perform set_config('t.ec2a', v_ec2a::text, true); perform set_config('t.ec2b', v_ec2b::text, true);
  perform set_config('t.q1', v_q1::text, true); perform set_config('t.qa1', v_qa1::text, true); perform set_config('t.qb1', v_qb1::text, true);
  perform set_config('t.q1A', (select id::text from public.question_options where question_id = v_q1 and option_key = 'A'), true);
  perform set_config('t.qa1A', (select id::text from public.question_options where question_id = v_qa1 and option_key = 'A'), true);
end $$;

-- ---- A. Student 1 sits the regular exam and answers correctly
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$
declare st record;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e1')::uuid, current_setting('t.ec1')::uuid);
  perform set_config('t.sid1', st.exam_session_id::text, true);
  perform set_config('t.sc1', st.exam_session_course_id::text, true);
  assert public.save_exam_answer_for_student(st.exam_session_id, st.exam_session_course_id, current_setting('t.q1')::uuid, current_setting('t.q1A')::uuid);
end $$;
reset role;

-- Inside the grace period nothing happens
update public.exam_session_courses set paper_expires_at = now() - interval '30 seconds' where id = current_setting('t.sc1')::uuid;
do $$ begin
  assert public.sweep_expired_exam_sessions(60) = 0, 'a paper 30s past its deadline is inside the 60s grace';
  assert (select status from public.exam_session_courses where id = current_setting('t.sc1')::uuid) = 'active';
end $$;

-- Well past the deadline: swept, scored, session ended, OTP rotated
update public.exam_session_courses set paper_expires_at = now() - interval '5 minutes' where id = current_setting('t.sc1')::uuid;
do $$
declare r public.exam_results%rowtype;
begin
  assert public.sweep_expired_exam_sessions(60) = 1, 'one overdue session swept';
  select * into r from public.exam_results where exam_session_course_id = current_setting('t.sc1')::uuid;
  assert r.exam_id = current_setting('t.e1')::uuid and r.exam_session_id = current_setting('t.sid1')::uuid, 'result carries exam and session ids';
  assert r.total_questions = 1 and r.answered_questions = 1 and r.correct_answers = 1 and r.percentage = 100, 'scored 1/1';
  assert (select status from public.exam_sessions where id = current_setting('t.sid1')::uuid) = 'submitted', 'session submitted';
  assert (select status from public.exam_session_courses where id = current_setting('t.sc1')::uuid) = 'submitted', 'paper submitted';
  assert exists (select 1 from public.exam_session_events where exam_session_id = current_setting('t.sid1')::uuid and event_type = 'AUTO_SUBMISSION_EXPIRED');
  assert exists (select 1 from public.exam_session_events where exam_session_id = current_setting('t.sid1')::uuid and event_type = 'OTP_ROTATED'), 'OTP rotated on auto-submission';
  assert public.sweep_expired_exam_sessions(60) = 0, 'a second sweep finds nothing';
end $$;

-- ---- B. A paused session is never swept
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$
declare st record;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e1')::uuid, current_setting('t.ec1')::uuid);
  perform set_config('t.sid2', st.exam_session_id::text, true);
  perform set_config('t.sc2', st.exam_session_course_id::text, true);
end $$;
reset role;
update public.exam_session_courses set paper_expires_at = now() - interval '5 minutes' where id = current_setting('t.sc2')::uuid;
update public.exam_sessions set status = 'paused', paused_at = now() - interval '10 minutes' where id = current_setting('t.sid2')::uuid;
do $$ begin
  assert public.sweep_expired_exam_sessions(60) = 0, 'paused sessions are skipped';
end $$;

-- ---- C. Admin force-submit now fills the result fully and ends the session
update public.exam_sessions set status = 'active', paused_at = null where id = current_setting('t.sid2')::uuid;
select set_config('request.jwt.claim.sub', current_setting('t.adm'), true);
do $$
declare f record; r public.exam_results%rowtype;
begin
  select * into f from public.admin_force_submit_exam_paper(current_setting('t.sc2')::uuid, 'test force submit');
  assert f.submission_confirmed and f.percentage = 0, 'unanswered paper scores 0';
  select * into r from public.exam_results where exam_session_course_id = current_setting('t.sc2')::uuid;
  assert r.exam_id = current_setting('t.e1')::uuid and r.exam_session_id = current_setting('t.sid2')::uuid and r.answered_questions = 0, 'force-submit result is complete';
  assert (select status from public.exam_sessions where id = current_setting('t.sid2')::uuid) = 'submitted', 'force-submit ends the session';
  assert exists (select 1 from public.exam_session_events where exam_session_id = current_setting('t.sid2')::uuid and event_type = 'ADMIN_FORCE_SUBMISSION');
  begin perform public.admin_force_submit_exam_paper(current_setting('t.sc2')::uuid, '  '); raise exception 'blank reason accepted';
  exception when others then assert sqlerrm = 'A reason is required for force submission', sqlerrm; end;
end $$;

-- ---- D. Pharmacy PreNational: per-paper scoring, whole sitting ends
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$
declare st record; v_sc_a uuid; v_sc_b uuid;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e2')::uuid, current_setting('t.ec2a')::uuid);
  perform set_config('t.sid3', st.exam_session_id::text, true);
  select id into v_sc_a from public.exam_session_courses where exam_session_id = st.exam_session_id and exam_course_id = current_setting('t.ec2a')::uuid;
  select id into v_sc_b from public.exam_session_courses where exam_session_id = st.exam_session_id and exam_course_id = current_setting('t.ec2b')::uuid;
  perform set_config('t.sc3a', v_sc_a::text, true); perform set_config('t.sc3b', v_sc_b::text, true);
  assert public.save_exam_answer_for_student(st.exam_session_id, v_sc_a, current_setting('t.qa1')::uuid, current_setting('t.qa1A')::uuid);

  -- ---- E. Flags
  perform public.set_exam_question_flag(st.exam_session_id, current_setting('t.qa1')::uuid, true);
  perform public.set_exam_question_flag(st.exam_session_id, current_setting('t.qa1')::uuid, true);
  assert (select count(*) from public.get_exam_flags(st.exam_session_id)) = 1, 'flag stored once';
  begin perform public.set_exam_question_flag(st.exam_session_id, current_setting('t.q1')::uuid, true); raise exception 'foreign question flagged';
  exception when others then assert sqlerrm = 'Question does not belong to this examination', sqlerrm; end;
  perform public.set_exam_question_flag(st.exam_session_id, current_setting('t.qa1')::uuid, false);
  assert (select count(*) from public.get_exam_flags(st.exam_session_id)) = 0, 'flag cleared';
  perform public.set_exam_question_flag(st.exam_session_id, current_setting('t.qa1')::uuid, true);
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$ begin
  begin perform public.get_exam_flags(current_setting('t.sid3')::uuid); raise exception 'other student read flags';
  exception when others then assert sqlerrm = 'Exam session does not exist', sqlerrm; end;
  begin perform public.set_exam_question_flag(current_setting('t.sid3')::uuid, current_setting('t.qa1')::uuid, true); raise exception 'other student set flag';
  exception when others then assert sqlerrm = 'Exam session does not exist', sqlerrm; end;
end $$;
reset role;

select set_config('request.jwt.claim.sub', current_setting('t.adm'), true);
do $$
declare ra public.exam_results%rowtype; rb public.exam_results%rowtype;
begin
  perform public.admin_force_submit_exam_paper(current_setting('t.sc3a')::uuid, 'pharmacy force submit');
  select * into ra from public.exam_results where exam_session_course_id = current_setting('t.sc3a')::uuid;
  select * into rb from public.exam_results where exam_session_course_id = current_setting('t.sc3b')::uuid;
  assert ra.total_questions = 2 and ra.correct_answers = 1 and ra.percentage = 50, 'paper A scored against its own 2 questions, got total ' || ra.total_questions;
  assert rb.total_questions = 1 and rb.answered_questions = 0 and rb.percentage = 0, 'paper B scored against its own question';
  assert (select count(*) from public.exam_session_courses where exam_session_id = current_setting('t.sid3')::uuid and status = 'submitted') = 2, 'both papers submitted';
  assert (select status from public.exam_sessions where id = current_setting('t.sid3')::uuid) = 'submitted', 'sitting ended';
end $$;

-- Flags are frozen once the paper is no longer active
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
set local role authenticated;
do $$ begin
  begin perform public.set_exam_question_flag(current_setting('t.sid3')::uuid, current_setting('t.qa1')::uuid, false); raise exception 'flag changed after submit';
  exception when others then assert sqlerrm = 'Flags can only be changed while the paper is active', sqlerrm; end;
end $$;
reset role;

-- ---- F. The SuperAdmin wrapper requires a SuperAdmin
do $$ begin
  perform set_config('request.jwt.claim.sub', current_setting('t.adm'), true);
  begin perform public.superadmin_sweep_expired_exam_sessions(); raise exception 'admin ran the sweep';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
end $$;

select 'ALL EXPIRY/FORCE-SUBMIT/FLAG CHECKS PASSED' as result;
rollback;
