-- Verifies server-side strikes, OTP rotation on submission, RLS and matric mapping.
-- Run against a scratch database; everything is rolled back at the end.
begin;

do $$
declare
  v_session uuid; v_exam uuid; v_student uuid; v_user uuid := gen_random_uuid();
  v_sid uuid; v_res record; v_before text; v_after text; v_otp text; v_n integer;
begin
  insert into public.academic_sessions(name) values ('TEST/' || gen_random_uuid()) returning id into v_session;
  insert into public.students(reg_no, full_name) values ('TEST/001', 'Test Student') returning id into v_student;
  insert into auth.users(id, email, encrypted_password) values (v_user, 'test/001@student.coht.local', extensions.crypt('OLDPW1', extensions.gen_salt('bf')));
  insert into public.profiles(id, role, student_id) values (v_user, 'student', v_student);
  insert into public.exams(academic_session_id, title) values (v_session, 'Test exam') returning id into v_exam;
  insert into public.exam_sessions(exam_id, student_id) values (v_exam, v_student) returning id into v_sid;
  perform set_config('test.sid', v_sid::text, true);
  perform set_config('test.exam', v_exam::text, true);
  perform set_config('test.student', v_student::text, true);
  perform set_config('test.user', v_user::text, true);
end $$;

-- 1. Strikes (as the student)
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.user'), true);

do $$
declare
  v_sid uuid; v_r record;
begin
  v_sid := current_setting('test.sid')::uuid;

  select * into v_r from public.record_security_event(v_sid, 'tab-hidden', 'Switched tab');
  assert v_r.strike_count = 1 and v_r.paused = false, 'strike 1 should not pause';

  select * into v_r from public.record_security_event(v_sid, 'window-blur', 'blur right after');
  assert v_r.strike_count = 1, 'debounce should suppress an immediate second strike';
end $$;

reset role;
update public.strikes set issued_at = issued_at - interval '10 seconds';
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.user'), true);

do $$
declare
  v_sid uuid; v_r record;
begin
  v_sid := current_setting('test.sid')::uuid;
  select * into v_r from public.record_security_event(v_sid, 'tab-hidden', 'two');
  assert v_r.strike_count = 2 and v_r.paused = false, 'strike 2 should not pause';
end $$;

reset role;
update public.strikes set issued_at = issued_at - interval '10 seconds';
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.user'), true);

do $$
declare
  v_sid uuid; v_r record;
begin
  v_sid := current_setting('test.sid')::uuid;
  select * into v_r from public.record_security_event(v_sid, 'tab-hidden', 'three');
  assert v_r.strike_count = 3 and v_r.paused = true and v_r.session_status = 'paused', 'strike 3 must pause';
  assert public.get_exam_strikes(v_sid) = 3, 'get_exam_strikes should return 3';
  select * into v_r from public.record_security_event(v_sid, 'tab-hidden', 'after pause');
  assert v_r.strike_count = 3, 'no strikes after pause';
end $$;

reset role;

do $$
begin
  assert (select status from public.exam_sessions where student_id = current_setting('test.student')::uuid) = 'paused', 'session must be paused';
  assert (select count(*) from public.exam_session_events where event_type = 'STRIKE_ISSUED') = 3, 'three STRIKE_ISSUED events';
  assert (select count(*) from public.supervisor_alerts where status = 'open') = 1, 'one open supervisor alert';
end $$;

-- 2. A different student cannot write strikes to this session
do $$
declare v_other uuid := gen_random_uuid(); v_s2 uuid; v_sid uuid;
begin
  insert into public.students(reg_no, full_name) values ('TEST/002', 'Other') returning id into v_s2;
  insert into auth.users(id, email) values (v_other, 'test/002@student.coht.local');
  insert into public.profiles(id, role, student_id) values (v_other, 'student', v_s2);
  v_sid := current_setting('test.sid')::uuid;
  perform set_config('request.jwt.claim.sub', v_other::text, true);
  begin
    perform public.record_security_event(v_sid, 'tab-hidden', 'x');
    raise exception 'cross-student strike was accepted';
  exception when others then
    assert sqlerrm = 'Exam session does not exist', 'unexpected error: ' || sqlerrm;
  end;
end $$;

-- 3. OTP rotates when the session becomes submitted
do $$
declare v_before text; v_after text; v_otp text; v_user uuid := current_setting('test.user')::uuid;
begin
  select encrypted_password into v_before from auth.users where id = v_user;
  update public.exam_sessions set status = 'submitted', submitted_at = now()
  where student_id = current_setting('test.student')::uuid;
  select encrypted_password into v_after from auth.users where id = v_user;
  select current_otp into v_otp from public.student_exam_otps where student_id = current_setting('test.student')::uuid;

  assert v_after is distinct from v_before, 'password hash must change on submission';
  assert v_otp ~ '^[A-Z0-9]{6}$', 'stored OTP must be 6 characters';
  assert extensions.crypt(v_otp, v_after) = v_after, 'stored OTP must be the new Auth password';
  assert extensions.crypt('OLDPW1', v_after) <> v_after, 'old password must stop working';
  assert exists (select 1 from public.exam_session_events where event_type = 'OTP_ROTATED'), 'OTP_ROTATED event';

  -- a second UPDATE that leaves status submitted must not rotate again
  update public.exam_sessions set updated_at = now() where student_id = current_setting('test.student')::uuid;
  assert (select count(*) from public.exam_session_events where event_type = 'OTP_ROTATED') = 1, 'no duplicate rotation';
end $$;

-- 4. RLS on reference tables
set local role anon;
do $$ begin
  begin perform 1 from public.departments limit 1; raise exception 'anon read allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

set local role authenticated;
do $$ begin
  perform 1 from public.departments limit 1;
  begin insert into public.departments(code, name) values ('ZZ', 'Zed'); raise exception 'authenticated insert allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- 5. Matric mapping does not reveal whether the student exists
set local role anon;
do $$ begin
  assert public.student_auth_email(' NOPE/999 ') = 'nope/999@student.coht.local';
end $$;
reset role;

select 'ALL CHECKS PASSED' as result;
rollback;
