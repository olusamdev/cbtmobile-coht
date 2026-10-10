-- Verifies examiner emails, the close-time queue, claiming/completing jobs, and the result sheet rows.
begin;
insert into public.system_settings(key,value) values ('require_student_photo','false'::jsonb) on conflict (key) do update set value='false'::jsonb;

do $$
declare
  v_su uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid(); v_u1 uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_ses uuid; v_c1 uuid; v_c2 uuid; v_e uuid; v_ea uuid; v_eb uuid; v_q uuid;
  st record;
begin
  insert into auth.users(id,email) values (v_su,'su@m.test'),(v_ad,'ad@m.test'),(v_u1,'m1@m.test');
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super'),(v_ad,'admin','Ada');
  insert into public.academic_sessions(name) values ('MAIL/2026') returning id into v_ses;
  insert into public.students(reg_no,full_name,level) values ('M/1','Sat Student',100) returning id into v_s1;
  insert into public.students(reg_no,full_name,level) values ('M/2','Absent Student',100) returning id into v_s2;
  insert into public.students(reg_no,full_name,level) values ('M/3','Other Course',100) returning id into v_s3;
  insert into public.profiles(id,role,student_id) values (v_u1,'student',v_s1);
  insert into public.courses(code,title) values ('MAL1','Mail A') returning id into v_c1;
  insert into public.courses(code,title) values ('MAL2','Mail B') returning id into v_c2;
  insert into public.student_course_registrations(student_id,course_id,academic_session_id) values (v_s1,v_c1,v_ses),(v_s2,v_c1,v_ses),(v_s3,v_c2,v_ses);
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active) values (v_ses,'Mail exam','continuous',30,true) returning id into v_e;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c1,1) returning id into v_ea;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c2,2) returning id into v_eb;
  insert into public.questions(exam_id,exam_course_id,question_number,question_text) values (v_e,v_ea,1,'Q') returning id into v_q;
  insert into public.question_options(question_id,option_key,option_text,is_correct) values (v_q,'A','a',true);
  perform set_config('t.su',v_su::text,true); perform set_config('t.ad',v_ad::text,true); perform set_config('t.u1',v_u1::text,true);
  perform set_config('t.e',v_e::text,true); perform set_config('t.ea',v_ea::text,true); perform set_config('t.eb',v_eb::text,true);
  perform set_config('t.s1',v_s1::text,true); perform set_config('t.q',v_q::text,true);
  perform set_config('t.opt',(select id::text from public.question_options where question_id=v_q),true);
end $$;

-- 1. Examiner emails
select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
begin
  perform public.superadmin_set_paper_examiner_email(current_setting('t.ea')::uuid, '  Dr.Obi@School.edu.ng ,  second@school.edu.ng  ');
  assert (select examiner_email from public.exam_courses where id = current_setting('t.ea')::uuid) = 'dr.obi@school.edu.ng, second@school.edu.ng', 'normalised and joined';
  begin perform public.superadmin_set_paper_examiner_email(current_setting('t.ea')::uuid, 'not-an-email'); raise exception 'bad email accepted';
  exception when others then assert sqlerrm like 'Enter valid email address%', sqlerrm; end;
  begin perform public.superadmin_set_paper_examiner_email(current_setting('t.ea')::uuid, 'a@x.com,b@x.com,c@x.com,d@x.com'); raise exception 'four emails accepted';
  exception when others then assert sqlerrm like 'Enter valid email address%', sqlerrm; end;
  perform public.superadmin_set_paper_examiner_email(current_setting('t.eb')::uuid, null);
  assert (select examiner_email from public.exam_courses where id = current_setting('t.eb')::uuid) is null, 'cleared';
end $$;

-- 2. A student sits paper A (so there is a result), then the exam is closed
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
select set_config('request.headers', '{"x-device-id":"d1"}', true);
do $$
declare st record;
begin
  select * into st from public.start_exam_paper_for_student(current_setting('t.e')::uuid, current_setting('t.ea')::uuid);
  assert public.save_exam_answer_for_student(st.exam_session_id, st.exam_session_course_id, current_setting('t.q')::uuid, current_setting('t.opt')::uuid);
  perform * from public.submit_exam_paper_for_student(st.exam_session_course_id, gen_random_uuid());
end $$;
reset role;

do $$ begin
  assert (select count(*) from public.result_mail_queue) = 0, 'nothing queued while the exam is open';
  update public.exams set is_active = false where id = current_setting('t.e')::uuid;
  assert (select count(*) from public.result_mail_queue) = 1, 'closing queues one sheet for the paper that has an examiner email';
  assert (select exam_course_id from public.result_mail_queue) = current_setting('t.ea')::uuid;
  update public.exams set is_active = true where id = current_setting('t.e')::uuid;
  update public.exams set is_active = false where id = current_setting('t.e')::uuid;
  assert (select count(*) from public.result_mail_queue) = 1, 'a pending sheet is not queued twice';
end $$;

-- 3. Claim, complete, retry
do $$
declare j record; n integer;
begin
  select * into j from public.claim_result_mail_jobs(null, 10);
  assert j.course_code = 'MAL1' and j.exam_title = 'Mail exam' and j.session_name = 'MAIL/2026' and j.recipients like 'dr.obi@%', 'job details returned';
  assert (select count(*) from public.claim_result_mail_jobs(null, 10)) = 0, 'a claimed job is not handed out twice';
  perform public.complete_result_mail(j.id, false, 'GAS said no');
  assert (select status from public.result_mail_queue where id = j.id) = 'failed' and (select attempts from public.result_mail_queue where id = j.id) = 1;
  perform set_config('t.job', j.id::text, true);
end $$;

select set_config('request.jwt.claim.sub', current_setting('t.su'), true);
do $$
begin
  perform public.superadmin_requeue_result_mail(current_setting('t.job')::uuid);
  assert (select status from public.result_mail_queue where id = current_setting('t.job')::uuid) = 'pending';
  assert (select count(*) from public.superadmin_list_result_mail_queue(10)) = 1, 'queue is listed';
  begin perform public.superadmin_requeue_result_mail(current_setting('t.job')::uuid); raise exception 'requeued a pending job';
  exception when others then assert sqlerrm = 'Only failed deliveries can be retried.', sqlerrm; end;
  assert public.superadmin_queue_result_mail(current_setting('t.e')::uuid) = 0, 'manual queue skips papers already pending';
end $$;
reset role;
do $$
declare j record;
begin
  select * into j from public.claim_result_mail_jobs(current_setting('t.e')::uuid, 5);
  perform public.complete_result_mail(j.id, true, null);
  assert (select status from public.result_mail_queue where id = j.id) = 'sent' and (select sent_at from public.result_mail_queue where id = j.id) is not null;
end $$;

-- 4. The sheet lists every registered student, with absentees marked
do $$
declare r record; n integer := 0;
begin
  for r in select * from public.result_sheet_rows(current_setting('t.ea')::uuid) loop
    n := n + 1;
    if r.reg_no = 'M/1' then assert r.result_status = 'Submitted' and r.correct = 1 and r.percentage = 100 and r.total = 1, 'submitted student scored'; end if;
    if r.reg_no = 'M/2' then assert r.result_status = 'Absent' and r.percentage is null, 'absentee listed without a score'; end if;
  end loop;
  assert n = 2, 'only students registered for this paper appear, got ' || n;
end $$;

-- 5. Admins cannot use the SuperAdmin calls
select set_config('request.jwt.claim.sub', current_setting('t.ad'), true);
do $$ begin
  begin perform public.superadmin_set_paper_examiner_email(current_setting('t.ea')::uuid, 'x@y.com'); raise exception 'admin set email';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
  begin perform * from public.superadmin_list_result_mail_queue(5); raise exception 'admin listed queue';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
end $$;

select 'ALL RESULT MAIL CHECKS PASSED' as result;
rollback;
