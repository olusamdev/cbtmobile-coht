-- Continuous mode end to end: one OTP across several papers, day ends with the last one.
begin;
select set_config('request.headers', '{"x-device-id":"cont-dev"}', true);
insert into public.system_settings(key,value) values ('require_student_photo','false'::jsonb) on conflict (key) do update set value='false'::jsonb;

do $$
declare
  v_su uuid := gen_random_uuid(); v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_ses uuid; v_c1 uuid; v_c2 uuid; v_e1 uuid; v_e2 uuid; v_ec1 uuid; v_ec2 uuid; v_q1 uuid; v_q2 uuid;
begin
  insert into auth.users(id,email,encrypted_password) values (v_su,'su@c.test',null),(v_u1,'c1@c.test',extensions.crypt('OLD1',extensions.gen_salt('bf'))),(v_u2,'c2@c.test',extensions.crypt('OLD2',extensions.gen_salt('bf')));
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super');
  insert into public.academic_sessions(name) values ('CONT/'||gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no,full_name) values ('C/1','Cont One') returning id into v_s1;
  insert into public.students(reg_no,full_name) values ('C/2','Cont Two') returning id into v_s2;
  insert into public.profiles(id,role,student_id) values (v_u1,'student',v_s1),(v_u2,'student',v_s2);
  insert into public.courses(code,title) values ('CNT1','First') returning id into v_c1;
  insert into public.courses(code,title) values ('CNT2','Second') returning id into v_c2;
  insert into public.student_course_registrations(student_id,course_id,academic_session_id) values (v_s1,v_c1,v_ses),(v_s1,v_c2,v_ses),(v_s2,v_c1,v_ses),(v_s2,v_c2,v_ses);
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active) values (v_ses,'Cont exam 1','continuous',30,true) returning id into v_e1;
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active) values (v_ses,'Cont exam 2','continuous',30,true) returning id into v_e2;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e1,v_c1,1) returning id into v_ec1;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e2,v_c2,1) returning id into v_ec2;
  insert into public.questions(exam_id,exam_course_id,question_number,question_text) values (v_e1,v_ec1,1,'Q1') returning id into v_q1;
  insert into public.questions(exam_id,exam_course_id,question_number,question_text) values (v_e2,v_ec2,1,'Q2') returning id into v_q2;
  insert into public.question_options(question_id,option_key,option_text,is_correct) values (v_q1,'A','a',true),(v_q2,'A','a',true);
  perform set_config('t.su',v_su::text,true); perform set_config('t.u1',v_u1::text,true); perform set_config('t.u2',v_u2::text,true);
  perform set_config('t.s1',v_s1::text,true); perform set_config('t.s2',v_s2::text,true);
  perform set_config('t.e1',v_e1::text,true); perform set_config('t.e2',v_e2::text,true);
  perform set_config('t.ec1',v_ec1::text,true); perform set_config('t.ec2',v_ec2::text,true);
end $$;

-- ===== Student 1: two papers, one OTP =====
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$
declare st record; r record; v_hash text;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e1')::uuid, current_setting('t.ec1')::uuid);
  perform set_config('t.sid1a', st.exam_session_id::text, true);
  select * into r from public.submit_exam_paper_for_student(st.exam_session_course_id, gen_random_uuid());
  assert r.all_papers_submitted = false and r.otp_rotation_required = false, 'first paper does not end the day';

  execute 'reset role';
  assert not exists (select 1 from public.exam_session_events where exam_session_id = st.exam_session_id and event_type = 'OTP_ROTATED'), 'OTP untouched after the first paper';
  assert (select status from public.exam_sessions where id = st.exam_session_id) = 'active', 'first sitting stays open until the day ends';
  execute 'set local role authenticated';

  select * into st from public.start_exam_paper_for_student(current_setting('t.e2')::uuid, current_setting('t.ec2')::uuid);
  perform set_config('t.sid1b', st.exam_session_id::text, true);
  select * into r from public.submit_exam_paper_for_student(st.exam_session_course_id, gen_random_uuid());
  assert r.all_papers_submitted = true and r.otp_rotation_required = true, 'last paper ends the day';

  execute 'reset role';
  assert exists (select 1 from public.exam_session_events where exam_session_id = st.exam_session_id and event_type = 'OTP_ROTATED'), 'OTP rotated once the day ended';
  assert (select count(*) from public.exam_sessions where student_id = current_setting('t.s1')::uuid and status = 'submitted') = 2, 'both sittings closed';
  assert not exists (select 1 from public.student_devices where student_id = current_setting('t.s1')::uuid), 'device released';
end $$;

-- ===== Student 2: the sweeper and force-submit follow the same day rule =====
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$
declare st record;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e1')::uuid, current_setting('t.ec1')::uuid);
  perform set_config('t.sid2a', st.exam_session_id::text, true);
  perform set_config('t.sc2a', st.exam_session_course_id::text, true);
end $$;
reset role;
update public.exam_session_courses set paper_expires_at = now() - interval '5 minutes' where id = current_setting('t.sc2a')::uuid;
do $$
begin
  assert public.sweep_expired_exam_sessions(60) = 1, 'expired Continuous paper swept';
  assert (select status from public.exam_session_courses where id = current_setting('t.sc2a')::uuid) = 'submitted';
  assert (select status from public.exam_sessions where id = current_setting('t.sid2a')::uuid) = 'active', 'another registered paper remains, so the day is not over';
  assert not exists (select 1 from public.exam_session_events where exam_session_id = current_setting('t.sid2a')::uuid and event_type = 'OTP_ROTATED'), 'no OTP rotation yet';
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$
declare st record;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e2')::uuid, current_setting('t.ec2')::uuid);
  perform set_config('t.sc2b', st.exam_session_course_id::text, true);
end $$;
reset role;
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
begin
  perform public.admin_force_submit_exam_paper(current_setting('t.sc2b')::uuid, 'continuous force submit');
  assert (select count(*) from public.exam_sessions where student_id = current_setting('t.s2')::uuid and status = 'submitted') = 2, 'force-submitting the last paper closes the day';
  assert exists (select 1 from public.exam_session_events e join public.exam_sessions s on s.id = e.exam_session_id where s.student_id = current_setting('t.s2')::uuid and e.event_type = 'OTP_ROTATED'), 'OTP rotated';
end $$;

select 'ALL CONTINUOUS MODE CHECKS PASSED' as result;
rollback;
