-- Verifies the photo limit, SuperAdmin clearance, photo gate, device binding and storage access.
begin;

do $$
declare
  v_su uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid(); v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_ses uuid; v_c uuid; v_e uuid; v_ec uuid;
begin
  insert into auth.users(id,email) values (v_su,'su@p.test'),(v_ad,'ad@p.test'),(v_u1,'p1@p.test'),(v_u2,'p2@p.test');
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super'),(v_ad,'admin','Ada');
  insert into public.academic_sessions(name) values ('PD/'||gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no,full_name) values ('PD/1','Photo One') returning id into v_s1;
  insert into public.students(reg_no,full_name) values ('PD/2','Photo Two') returning id into v_s2;
  insert into public.profiles(id,role,student_id) values (v_u1,'student',v_s1),(v_u2,'student',v_s2);
  insert into public.courses(code,title) values ('PDC1','Photo course') returning id into v_c;
  insert into public.student_course_registrations(student_id,course_id,academic_session_id) values (v_s1,v_c,v_ses),(v_s2,v_c,v_ses);
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active) values (v_ses,'PD exam','regular',30,true) returning id into v_e;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c,1) returning id into v_ec;
  insert into public.questions(exam_id,exam_course_id,question_number,question_text) select v_e,v_ec,1,'Q';
  insert into public.question_options(question_id,option_key,option_text,is_correct) select q.id,'A','a',true from public.questions q where q.exam_id=v_e;
  perform set_config('t.su',v_su::text,true); perform set_config('t.ad',v_ad::text,true);
  perform set_config('t.u1',v_u1::text,true); perform set_config('t.u2',v_u2::text,true);
  perform set_config('t.s1',v_s1::text,true); perform set_config('t.s2',v_s2::text,true);
  perform set_config('t.e',v_e::text,true); perform set_config('t.ec',v_ec::text,true);
end $$;

-- ===== PHOTOS =====
do $$
declare v_s1 uuid := current_setting('t.s1')::uuid;
begin
  assert public.student_photo_next_index(v_s1) = 1, 'first upload is index 1';
  perform public.record_student_photo(v_s1, v_s1 || '/1.jpg', 'female');
  assert public.student_photo_next_index(v_s1) = 2, 'one self-service change allowed';
  perform public.record_student_photo(v_s1, v_s1 || '/2.jpg', 'female');
  begin perform public.student_photo_next_index(v_s1); raise exception 'third upload allowed';
  exception when others then assert sqlerrm like 'Photo changes are locked%', sqlerrm; end;
  begin perform public.record_student_photo(v_s1, v_s1 || '/3.jpg', 'female'); raise exception 'third record allowed';
  exception when others then assert sqlerrm like 'Photo changes are locked%', sqlerrm; end;
end $$;

-- student view and clearance request
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$
declare st record;
begin
  select * into st from public.get_my_photo_status();
  assert st.upload_count = 2 and not st.can_upload and not st.request_pending, 'locked after the change';
  perform public.request_photo_change_clearance('Wrong picture uploaded');
  begin perform public.request_photo_change_clearance('again'); raise exception 'duplicate request allowed';
  exception when others then assert sqlerrm like 'Your request is already waiting%', sqlerrm; end;
  select * into st from public.get_my_photo_status();
  assert st.request_pending, 'request shows as pending';
end $$;

-- student 2 has no photo: cannot request, and sees can_upload
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$
declare st record;
begin
  select * into st from public.get_my_photo_status();
  assert st.can_upload and st.upload_count = 0 and st.photo_path is null;
  begin perform public.request_photo_change_clearance('x'); raise exception 'request without photo allowed';
  exception when others then assert sqlerrm = 'Upload your photo first.', sqlerrm; end;
end $$;
reset role;

-- SuperAdmin decides
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
declare v_req uuid;
begin
  select request_id into v_req from public.superadmin_list_photo_requests();
  assert v_req is not null, 'pending request listed';
  perform public.superadmin_decide_photo_request(v_req, true);
  assert (select extra_uploads from public.student_photos where student_id = current_setting('t.s1')::uuid) = 1, 'approval grants one more upload';
  assert public.student_photo_next_index(current_setting('t.s1')::uuid) = 3, 'a further upload is now allowed';
  perform public.record_student_photo(current_setting('t.s1')::uuid, current_setting('t.s1') || '/3.jpg', 'female');
  begin perform public.student_photo_next_index(current_setting('t.s1')::uuid); raise exception 'extra upload not consumed';
  exception when others then assert sqlerrm like 'Photo changes are locked%', sqlerrm; end;

  perform public.superadmin_grant_photo_change(current_setting('t.s1')::uuid);
  assert public.student_photo_next_index(current_setting('t.s1')::uuid) = 4, 'direct grant works';
  begin perform public.superadmin_grant_photo_change(current_setting('t.s2')::uuid); raise exception 'grant without photo allowed';
  exception when others then assert sqlerrm = 'This student has not uploaded a photo yet.', sqlerrm; end;
end $$;

-- decline path
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$ begin
  -- consume the direct grant so the student is locked again, then request and be declined
  perform set_config('t.dummy','1',true);
end $$;
reset role;
do $$ begin
  perform public.record_student_photo(current_setting('t.s1')::uuid, current_setting('t.s1') || '/4.jpg', 'female');
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
select public.request_photo_change_clearance('please');
reset role;
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
declare v_req uuid;
begin
  select request_id into v_req from public.superadmin_list_photo_requests();
  perform public.superadmin_decide_photo_request(v_req, false);
  assert (select status from public.photo_change_requests where id = v_req) = 'declined';
  begin perform public.student_photo_next_index(current_setting('t.s1')::uuid); raise exception 'declined request granted upload';
  exception when others then assert sqlerrm like 'Photo changes are locked%', sqlerrm; end;
end $$;

-- storage: a student reads only their own folder; staff read all
insert into storage.objects(bucket_id, name) values
  ('student-photos', current_setting('t.s1') || '/3.jpg'),
  ('student-photos', current_setting('t.s2') || '/1.jpg');
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$ begin
  assert (select count(*) from storage.objects where bucket_id = 'student-photos') = 1, 'student sees only their own photo';
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.ad'), true);
do $$ begin
  assert (select count(*) from storage.objects where bucket_id = 'student-photos') = 2, 'admin sees every photo';
  assert (select count(*) from public.get_student_photo_paths(array[current_setting('t.s1')::uuid, current_setting('t.s2')::uuid])) = 1, 'photo paths listed for staff';
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$ begin
  begin perform * from public.get_student_photo_paths(array[current_setting('t.s1')::uuid]); raise exception 'student read photo paths';
  exception when others then assert sqlerrm = 'Administrative authorization required', sqlerrm; end;
end $$;
reset role;

-- ===== PHOTO GATE + DEVICES =====
insert into public.system_settings(key,value) values ('require_student_photo','true'::jsonb) on conflict (key) do update set value='true'::jsonb;
select set_config('request.headers', '{"x-device-id":"device-A"}', true);

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$ begin
  begin perform * from public.start_exam_paper_for_student(current_setting('t.e')::uuid, current_setting('t.ec')::uuid); raise exception 'started without a photo';
  exception when others then assert sqlerrm = 'Upload your identifier photo before starting your first paper.', sqlerrm; end;
end $$;
reset role;
insert into public.student_photos(student_id, photo_path) values (current_setting('t.s2')::uuid, current_setting('t.s2') || '/1.jpg');

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$
declare st record;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e')::uuid, current_setting('t.ec')::uuid);
  perform set_config('t.sid2', st.exam_session_id::text, true);
  perform set_config('t.sc2', st.exam_session_course_id::text, true);
  perform public.student_device_ping('Chrome on Android');
end $$;

-- device B is refused while A is active, for pings and every exam call
select set_config('request.headers', '{"x-device-id":"device-B"}', true);
do $$
declare v_msg constant text := 'This account is active on another device. Close it there, or ask the SuperAdmin to release it.';
begin
  begin perform public.student_device_ping(null); raise exception 'second device pinged';
  exception when others then assert sqlerrm = v_msg, sqlerrm; end;
  begin perform * from public.get_exam_questions_for_student(current_setting('t.sid2')::uuid, current_setting('t.sc2')::uuid); raise exception 'second device read questions';
  exception when others then assert sqlerrm = v_msg, sqlerrm; end;
  begin perform public.save_exam_answer_for_student(current_setting('t.sid2')::uuid, current_setting('t.sc2')::uuid, gen_random_uuid(), gen_random_uuid()); raise exception 'second device saved';
  exception when others then assert sqlerrm = v_msg, sqlerrm; end;
  begin perform * from public.submit_exam_paper_for_student(current_setting('t.sc2')::uuid, gen_random_uuid()); raise exception 'second device submitted';
  exception when others then assert sqlerrm = v_msg, sqlerrm; end;
end $$;

-- missing header is refused
select set_config('request.headers', '{}', true);
do $$ begin
  begin perform public.student_device_ping(null); raise exception 'ping without a header';
  exception when others then assert sqlerrm like 'Device identification is missing%', sqlerrm; end;
end $$;

-- the original device carries on
select set_config('request.headers', '{"x-device-id":"device-A"}', true);
do $$ begin perform public.student_device_ping(null); end $$;
reset role;

-- after 3 minutes without a sign of life, another device may take over; the old one is then refused
update public.student_devices set last_seen_at = now() - interval '4 minutes' where student_id = current_setting('t.s2')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
select set_config('request.headers', '{"x-device-id":"device-B"}', true);
do $$ begin
  perform public.student_device_ping('Safari on iPhone');
  execute 'reset role';
  assert (select device_id from public.student_devices where student_id = current_setting('t.s2')::uuid) = 'device-B', 'takeover after inactivity';
  execute 'set local role authenticated';
end $$;
select set_config('request.headers', '{"x-device-id":"device-A"}', true);
do $$ begin
  begin perform public.student_device_ping(null); raise exception 'old device still accepted';
  exception when others then assert sqlerrm like 'This account is active on another device%', sqlerrm; end;
end $$;

-- signing out releases the binding
select set_config('request.headers', '{"x-device-id":"device-B"}', true);
do $$ begin
  perform public.release_student_device();
  execute 'reset role';
  assert not exists (select 1 from public.student_devices where student_id = current_setting('t.s2')::uuid), 'sign-out frees the device';
  execute 'set local role authenticated';
end $$;
reset role;

-- SuperAdmin release + find, and the binding clears when a sitting ends
select set_config('request.headers', '{"x-device-id":"device-A"}', true);
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
select public.student_device_ping('Chrome on Windows');
reset role;
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
declare r record;
begin
  select * into r from public.superadmin_find_student_identity('PD/2');
  assert r.device_active and r.device_label = 'Chrome on Windows', 'identity lookup shows the active device';
  perform public.superadmin_release_student_device(current_setting('t.s2')::uuid);
  assert not exists (select 1 from public.student_devices where student_id = current_setting('t.s2')::uuid), 'SuperAdmin released the device';

  insert into public.student_devices(student_id, device_id) values (current_setting('t.s2')::uuid, 'device-A');
  update public.exam_sessions set status = 'submitted' where id = current_setting('t.sid2')::uuid;
  assert not exists (select 1 from public.student_devices where student_id = current_setting('t.s2')::uuid), 'a finished sitting frees the device';

end $$;

-- direct calls to the unguarded functions are gone for students
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$ begin
  begin perform * from public.start_exam_paper_v2(current_setting('t.e')::uuid, current_setting('t.ec')::uuid); raise exception 'direct v2 start allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

select 'ALL PHOTO/DEVICE CHECKS PASSED' as result;
rollback;
