-- Verifies the active-only assignment list, bulk time extension, and removal of the global mode setting.
begin;
select set_config('request.headers', '{"x-device-id":"test-device"}', true);
insert into public.system_settings(key,value) values ('require_student_photo','false'::jsonb) on conflict (key) do update set value='false'::jsonb;

do $$
declare
  v_su uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid();
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid(); v_u3 uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_ses uuid; v_c1 uuid; v_c2 uuid; v_e uuid; v_ea uuid; v_eb uuid;
begin
  insert into auth.users(id,email) values (v_su,'su@t.test'),(v_ad,'ad@t.test'),(v_u1,'a@t.test'),(v_u2,'b@t.test'),(v_u3,'c@t.test');
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super'),(v_ad,'admin','Ada');
  insert into public.academic_sessions(name) values ('BULK/'||gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no,full_name) values ('B/1','One') returning id into v_s1;
  insert into public.students(reg_no,full_name) values ('B/2','Two') returning id into v_s2;
  insert into public.students(reg_no,full_name) values ('B/3','Three') returning id into v_s3;
  insert into public.profiles(id,role,student_id) values (v_u1,'student',v_s1),(v_u2,'student',v_s2),(v_u3,'student',v_s3);
  insert into public.courses(code,title) values ('BLKA','A') returning id into v_c1;
  insert into public.courses(code,title) values ('BLKB','B') returning id into v_c2;
  insert into public.student_course_registrations(student_id,course_id,academic_session_id) values (v_s1,v_c1,v_ses),(v_s2,v_c1,v_ses),(v_s3,v_c2,v_ses);
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active) values (v_ses,'Continuous day','continuous',60,true) returning id into v_e;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c1,1) returning id into v_ea;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c2,2) returning id into v_eb;
  perform set_config('t.su',v_su::text,true); perform set_config('t.ad',v_ad::text,true);
  perform set_config('t.u1',v_u1::text,true); perform set_config('t.u2',v_u2::text,true); perform set_config('t.u3',v_u3::text,true);
  perform set_config('t.e',v_e::text,true); perform set_config('t.ea',v_ea::text,true); perform set_config('t.eb',v_eb::text,true);
end $$;

-- 1. Assignment list shows active assignments only
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
declare v_id uuid;
begin
  v_id := public.superadmin_assign_admin_paper(current_setting('t.ad')::uuid, current_setting('t.ea')::uuid);
  assert (select count(*) from public.superadmin_list_admin_paper_assignments()) = 1, 'assignment listed';
  perform public.superadmin_unassign_admin_paper(v_id);
  assert (select count(*) from public.superadmin_list_admin_paper_assignments()) = 0, 'unassigned paper disappears from the list';
  perform public.superadmin_assign_admin_paper(current_setting('t.ad')::uuid, current_setting('t.ea')::uuid);
  assert (select count(*) from public.superadmin_list_admin_paper_assignments()) = 1, 're-assigning brings it back';
end $$;

-- 2. Three students start papers (two on paper A, one on paper B)
do $$
declare i int; u text; ec text; st record;
begin
  foreach u in array array['t.u1','t.u2','t.u3'] loop
    ec := case when u = 't.u3' then 't.eb' else 't.ea' end;
    perform set_config('request.jwt.claim.sub', current_setting(u), true);
    execute 'set local role authenticated';
    select * into st from public.start_exam_paper_for_student(current_setting('t.e')::uuid, current_setting(ec)::uuid);
    execute 'reset role';
    perform set_config('t.sid_' || u, st.exam_session_id::text, true);
  end loop;
end $$;

-- 3. Bulk extension
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
declare n integer;
begin
  n := public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, current_setting('t.ea')::uuid, 10, 'power outage');
  assert n = 2, 'paper A extension reaches its two candidates, got ' || n;
  assert (select total_extension_seconds from public.exam_sessions where id = current_setting('t.sid_t.u1')::uuid) = 600, 'u1 extended by 600s';
  assert (select total_extension_seconds from public.exam_sessions where id = current_setting('t.sid_t.u2')::uuid) = 600, 'u2 extended by 600s';
  assert coalesce((select total_extension_seconds from public.exam_sessions where id = current_setting('t.sid_t.u3')::uuid), 0) = 0, 'paper B candidate untouched';

  n := public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, null, 5, null);
  assert n = 3, 'whole-exam extension reaches everyone, got ' || n;
  assert (select total_extension_seconds from public.exam_sessions where id = current_setting('t.sid_t.u3')::uuid) = 300;
  assert (select total_extension_seconds from public.exam_sessions where id = current_setting('t.sid_t.u1')::uuid) = 900, 'extensions accumulate';

  update public.exam_sessions set status = 'submitted' where id = current_setting('t.sid_t.u2')::uuid;
  assert public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, null, 5, null) = 2, 'submitted sittings are skipped';

  begin perform public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, null, 0, null); raise exception 'zero accepted';
  exception when others then assert sqlerrm = 'Extension must be between 1 and 240 minutes.', sqlerrm; end;
  begin perform public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, null, 241, null); raise exception '241 accepted';
  exception when others then assert sqlerrm = 'Extension must be between 1 and 240 minutes.', sqlerrm; end;
  begin perform public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, gen_random_uuid(), 5, null); raise exception 'foreign paper accepted';
  exception when others then assert sqlerrm = 'That paper does not belong to this examination.', sqlerrm; end;
end $$;

-- 4. Admins cannot use it
select set_config('request.jwt.claim.sub', current_setting('t.ad'), true);
do $$ begin
  begin perform public.superadmin_extend_exam_time_bulk(current_setting('t.e')::uuid, null, 5, null); raise exception 'admin allowed';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
end $$;

-- 5. Global exam mode is gone
do $$ begin
  assert not exists (select 1 from pg_proc where proname = 'superadmin_set_exam_mode'), 'global mode function removed';
  assert not exists (select 1 from public.system_settings where key = 'exam_mode'), 'global mode row removed';
end $$;

select 'ALL SETTINGS/ASSIGNMENT CHECKS PASSED' as result;
rollback;
