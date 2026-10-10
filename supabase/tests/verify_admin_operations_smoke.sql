-- Calls every admin / supervision / superadmin function the app depends on, in a seeded
-- scenario, and fails on the first runtime error (ambiguous columns, type mismatches,
-- missing columns). Rolled back at the end.
begin;
select set_config('request.headers', '{"x-device-id":"test-device"}', true);
insert into public.system_settings(key,value) values ('require_student_photo','false'::jsonb) on conflict (key) do update set value='false'::jsonb;
create or replace function pg_temp.try(label text, q text) returns void language plpgsql as $$
begin execute q; raise notice 'OK    %', label;
exception when others then raise exception 'SMOKE FAILURE in %: %', label, sqlerrm; end $$;

do $$
declare
  v_su uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid(); v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_ses uuid; v_c uuid; v_e uuid; v_ec uuid; v_q uuid; st record; st2 record;
begin
  insert into auth.users(id,email) values (v_su,'su@s.test'),(v_ad,'ad@s.test'),(v_u1,'a@s.test'),(v_u2,'b@s.test');
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super'),(v_ad,'admin','Ada');
  insert into public.academic_sessions(name) values ('SM/'||gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no,full_name) values ('SM/1','One') returning id into v_s1;
  insert into public.students(reg_no,full_name) values ('SM/2','Two') returning id into v_s2;
  insert into public.profiles(id,role,student_id) values (v_u1,'student',v_s1),(v_u2,'student',v_s2);
  insert into public.courses(code,title) values ('SMK1','Smoke') returning id into v_c;
  insert into public.student_course_registrations(student_id,course_id,academic_session_id) values (v_s1,v_c,v_ses),(v_s2,v_c,v_ses);
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active) values (v_ses,'Smoke exam','regular',60,true) returning id into v_e;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c,1) returning id into v_ec;
  insert into public.questions(exam_id,exam_course_id,question_number,question_text) values (v_e,v_ec,1,'Q') returning id into v_q;
  insert into public.question_options(question_id,option_key,option_text,is_correct) values (v_q,'A','a',true),(v_q,'B','b',false);
  perform public.superadmin_assign_admin_paper(v_ad, v_ec) from (select set_config('request.jwt.claim.sub', v_su::text, true)) x;
  perform set_config('request.jwt.claim.sub', v_u1::text, true); select * into st from public.start_exam_paper_for_student(v_e, v_ec);
  perform set_config('request.jwt.claim.sub', v_u2::text, true); select * into st2 from public.start_exam_paper_for_student(v_e, v_ec);
  perform set_config('s.su', v_su::text, true); perform set_config('s.ad', v_ad::text, true);
  perform set_config('s.sid', st.exam_session_id::text, true); perform set_config('s.sc', st.exam_session_course_id::text, true);
  perform set_config('s.sid2', st2.exam_session_id::text, true); perform set_config('s.sc2', st2.exam_session_course_id::text, true);
  perform set_config('s.ec', v_ec::text, true); perform set_config('s.e', v_e::text, true); perform set_config('s.s1', v_s1::text, true);
end $$;

-- ADMIN calls
select set_config('request.jwt.claim.sub', current_setting('s.ad'), true);
select pg_temp.try('admin_list_assigned_papers', 'select * from public.admin_list_assigned_papers()');
select pg_temp.try('admin_list_paper_candidates', format('select * from public.admin_list_paper_candidates(%L)', current_setting('s.ec')));
select pg_temp.try('admin_list_active_attempts', 'select * from public.admin_list_active_attempts()');
select pg_temp.try('admin_get_exam_session_state', format('select * from public.admin_get_exam_session_state(%L)', current_setting('s.sid')));
select pg_temp.try('admin_flag_for_supervisor', format('select public.admin_flag_for_supervisor(%L, %L)', current_setting('s.sid'), 'check'));
select pg_temp.try('admin_pause_exam_session_scoped', format('select public.admin_pause_exam_session_scoped(%L, %L)', current_setting('s.sid'), 'pause'));
select pg_temp.try('admin_resume_exam_session_scoped', format('select public.admin_resume_exam_session_scoped(%L, %L)', current_setting('s.sid'), 'resume'));
-- Behaviour check: pause then resume really returns the sitting to active
do $$ begin
  assert (select status from public.exam_sessions where id = current_setting('s.sid')::uuid) = 'active', 'resume returns the sitting to active';
  perform public.admin_pause_exam_session_scoped(current_setting('s.sid')::uuid, 'again');
  assert (select status from public.exam_sessions where id = current_setting('s.sid')::uuid) = 'paused', 'paused';
  perform public.admin_resume_exam_session_scoped(current_setting('s.sid')::uuid, 'back');
  assert (select status from public.exam_sessions where id = current_setting('s.sid')::uuid) = 'active', 'resumed again';
end $$;
select pg_temp.try('admin_extend_exam_time', format('select * from public.admin_extend_exam_time(%L, 60, %L)', current_setting('s.sid'), 'x'));
select pg_temp.try('supervision_get_audit_trail', format('select * from public.supervision_get_audit_trail(%L)', current_setting('s.sid')));
select pg_temp.try('supervision_list_security_events', 'select * from public.supervision_list_security_events(null, null, 0)');
select pg_temp.try('admin_clear_student_into_paper', format('select public.admin_clear_student_into_paper(%L, %L, %L)', current_setting('s.ec'), current_setting('s.s1'), 'ok'));
select pg_temp.try('admin_force_submit_exam_paper_scoped', format('select * from public.admin_force_submit_exam_paper_scoped(%L, %L)', current_setting('s.sc'), 'smoke'));
select pg_temp.try('admin_wipe_exam_paper', format('select public.admin_wipe_exam_paper(%L, %L)', current_setting('s.sid2'), 'smoke wipe'));
select pg_temp.try('admin_cancel_exam_paper', format('select public.admin_cancel_exam_paper(%L, %L)', current_setting('s.sid2'), 'smoke cancel'));

-- SUPERADMIN calls
select set_config('request.jwt.claim.sub', current_setting('s.su'), true);
select pg_temp.try('superadmin_list_admins', 'select * from public.superadmin_list_admins()');
select pg_temp.try('superadmin_list_admin_paper_assignments', 'select * from public.superadmin_list_admin_paper_assignments()');
select pg_temp.try('superadmin_list_registered_students', 'select * from public.superadmin_list_registered_students(null)');
select pg_temp.try('superadmin_get_student_detail', format('select * from public.superadmin_get_student_detail(%L)', current_setting('s.s1')));
select pg_temp.try('superadmin_list_departments', 'select * from public.superadmin_list_departments()');
select pg_temp.try('superadmin_list_student_departments', 'select * from public.superadmin_list_student_departments()');
select pg_temp.try('superadmin_list_student_otps', 'select * from public.superadmin_list_student_otps(null, null)');
select pg_temp.try('superadmin_clear_strikes', format('select public.superadmin_clear_strikes(%L, %L)', current_setting('s.sid'), 'recover'));
select pg_temp.try('superadmin_list_exams_for_question_bank', 'select * from public.superadmin_list_exams_for_question_bank()');
select pg_temp.try('superadmin_update_exam (inactive path)', format($f$select public.superadmin_update_exam(%L, 'Smoke renamed', 45, false, true)$f$, current_setting('s.e')));

select 'ALL ADMIN OPERATION SMOKE CHECKS PASSED' as result;
rollback;
