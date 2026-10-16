-- Verifies archive, restore and delete of results for every scope. Rolled back at the end.
begin;

do $$
declare
  v_su uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid();
  v_d1 uuid; v_d2 uuid; v_p1 uuid; v_p2 uuid; v_ses uuid;
  v_c1 uuid; v_c2 uuid; v_e1 uuid; v_e2 uuid; v_ec1 uuid; v_ec2 uuid; v_ec3 uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; s uuid; ec uuid; e uuid; v_sess uuid; v_sc uuid; r record;
begin
  insert into auth.users(id,email) values (v_su,'su@r.test'),(v_ad,'ad@r.test');
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super'),(v_ad,'admin','Ada');
  insert into public.departments(code,name) values ('PHT','Pharmacy') returning id into v_d1;
  insert into public.departments(code,name) values ('NUR','Nursing') returning id into v_d2;
  insert into public.programmes(department_id,code,name) values (v_d1,'ND','ND Pharm') returning id into v_p1;
  insert into public.programmes(department_id,code,name) values (v_d2,'ND','ND Nursing') returning id into v_p2;
  insert into public.academic_sessions(name) values ('RES/2026') returning id into v_ses;
  insert into public.students(reg_no,full_name,programme_id) values ('R/1','Pharm One',v_p1) returning id into v_s1;
  insert into public.students(reg_no,full_name,programme_id) values ('R/2','Pharm Two',v_p1) returning id into v_s2;
  insert into public.students(reg_no,full_name,programme_id) values ('R/3','Nurse Three',v_p2) returning id into v_s3;
  insert into public.courses(code,title) values ('RC1','Course one') returning id into v_c1;
  insert into public.courses(code,title) values ('RC2','Course two') returning id into v_c2;
  insert into public.exams(academic_session_id,title,mode,duration_minutes) values (v_ses,'Exam A','regular',30) returning id into v_e1;
  insert into public.exams(academic_session_id,title,mode,duration_minutes) values (v_ses,'Exam B','continuous',30) returning id into v_e2;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e1,v_c1,1) returning id into v_ec1;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e2,v_c1,1) returning id into v_ec2;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e2,v_c2,2) returning id into v_ec3;

  -- results: Exam A/paper1: s1,s2,s3 ; Exam B/paper2: s1 ; Exam B/paper3: s1,s3   => 6 results
  for r in
    select * from (values (v_s1,v_e1,v_ec1),(v_s2,v_e1,v_ec1),(v_s3,v_e1,v_ec1),(v_s1,v_e2,v_ec2),(v_s1,v_e2,v_ec3),(v_s3,v_e2,v_ec3)) t(st,ex,pc)
  loop
    select id into v_sess from public.exam_sessions where exam_id = r.ex and student_id = r.st;
    if v_sess is null then
      insert into public.exam_sessions(exam_id,student_id,status) values (r.ex,r.st,'submitted') returning id into v_sess;
    end if;
    insert into public.exam_session_courses(exam_session_id,exam_course_id,status) values (v_sess,r.pc,'submitted') returning id into v_sc;
    insert into public.exam_results(exam_session_id,exam_session_course_id,student_id,exam_id,total_questions,answered_questions,correct_answers,wrong_answers,unanswered_questions,score,percentage,status)
    values (v_sess,v_sc,r.st,r.ex,10,10,7,3,0,7,70,'final');
  end loop;

  perform set_config('t.su',v_su::text,true); perform set_config('t.ad',v_ad::text,true);
  perform set_config('t.d1',v_d1::text,true); perform set_config('t.d2',v_d2::text,true);
  perform set_config('t.e1',v_e1::text,true); perform set_config('t.e2',v_e2::text,true);
  perform set_config('t.ec1',v_ec1::text,true); perform set_config('t.ec2',v_ec2::text,true); perform set_config('t.ec3',v_ec3::text,true);
end $$;

select set_config('request.jwt.claim.sub', current_setting('t.su'), true);

-- ===== summaries per scope =====
do $$
declare r record;
begin
  select * into r from public.superadmin_results_scope_summary('all');
  assert r.total = 6 and r.active = 6 and r.archived = 0, 'all: 6';
  select * into r from public.superadmin_results_scope_summary('department', current_setting('t.d1')::uuid);
  assert r.total = 4, 'department PHT: s1 x3 + s2 x1 = 4, got ' || r.total;
  select * into r from public.superadmin_results_scope_summary('department', current_setting('t.d2')::uuid);
  assert r.total = 2, 'department NUR: 2';
  select * into r from public.superadmin_results_scope_summary('examination', null, current_setting('t.e1')::uuid);
  assert r.total = 3, 'Exam A: 3';
  select * into r from public.superadmin_results_scope_summary('examination', null, current_setting('t.e2')::uuid);
  assert r.total = 3, 'Exam B: 3';
  select * into r from public.superadmin_results_scope_summary('paper', null, null, current_setting('t.ec3')::uuid);
  assert r.total = 2, 'paper 3: 2';
  begin perform * from public.superadmin_results_scope_summary('department'); raise exception 'no department accepted';
  exception when others then assert sqlerrm = 'Choose a department.', sqlerrm; end;
  begin perform * from public.superadmin_results_scope_summary('everything'); raise exception 'bad scope accepted';
  exception when others then assert sqlerrm like 'Unknown scope%', sqlerrm; end;
end $$;

-- ===== archive and restore =====
do $$
declare n integer; r record;
begin
  n := public.superadmin_archive_results('paper', null, null, current_setting('t.ec3')::uuid, 'term ended');
  assert n = 2, 'archived the two paper-3 results';
  select * into r from public.superadmin_results_scope_summary('all');
  assert r.active = 4 and r.archived = 2, 'counts after archive';
  assert public.superadmin_archive_results('paper', null, null, current_setting('t.ec3')::uuid) = 0, 'archiving again changes nothing';

  n := public.superadmin_archive_results('department', current_setting('t.d2')::uuid);
  assert n = 1, 'the NUR result not already archived';  -- s3 has two results, one already archived in paper 3
  assert public.superadmin_restore_results('examination', null, current_setting('t.e2')::uuid) = 2, 'restoring Exam B returns only its two archived paper-3 results';
  select * into r from public.superadmin_results_scope_summary('all');
  assert r.archived = 1 and r.active = 5, 'after restore: only the NUR Exam A result stays archived';
end $$;

-- ===== delete needs the confirmation word =====
do $$
declare n integer;
begin
  begin perform public.superadmin_delete_results('paper', null, null, current_setting('t.ec1')::uuid); raise exception 'deleted without confirmation';
  exception when others then assert sqlerrm like 'Type DELETE%', sqlerrm; end;
  begin perform public.superadmin_delete_results('paper', null, null, current_setting('t.ec1')::uuid, 'delete'); raise exception 'lowercase accepted';
  exception when others then assert sqlerrm like 'Type DELETE%', sqlerrm; end;

  n := public.superadmin_delete_results('paper', null, null, current_setting('t.ec1')::uuid, 'DELETE', 'wrong paper uploaded');
  assert n = 3, 'deleted the three paper-1 results (active and archived)';
  assert (select count(*) from public.exam_results) = 3, 'three results remain';
  assert (select count(*) from public.exam_sessions) = 5, 'all five sittings are untouched';

  n := public.superadmin_delete_results('all', null, null, null, 'DELETE');
  assert n = 3 and (select count(*) from public.exam_results) = 0, 'delete all clears the rest';
end $$;

-- ===== log =====
do $$
declare n integer;
begin
  select count(*) into n from public.superadmin_list_results_admin_log(50);
  assert n = 6, 'every action logged, got ' || n;
  assert exists (select 1 from public.superadmin_list_results_admin_log(50) where action = 'delete' and affected = 3 and reason = 'wrong paper uploaded' and scope_label like 'Paper RC1%');
end $$;

-- ===== admins cannot =====
select set_config('request.jwt.claim.sub', current_setting('t.ad'), true);
do $$ begin
  begin perform public.superadmin_archive_results('all'); raise exception 'admin archived';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
  begin perform public.superadmin_delete_results('all', null, null, null, 'DELETE'); raise exception 'admin deleted';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
  begin perform * from public.superadmin_list_results_admin_log(5); raise exception 'admin read the log';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
end $$;

select 'ALL RESULTS ARCHIVE/DELETE CHECKS PASSED' as result;
rollback;
