-- Verifies that students only see results when the examination allows it.
begin;

do $$
declare
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_ses uuid; v_c uuid; v_e uuid; v_ec uuid; v_q uuid; v_opt uuid; st record;
begin
  insert into auth.users(id,email) values (v_u1,'r1@t.test'),(v_u2,'r2@t.test');
  insert into public.academic_sessions(name) values ('RV/'||gen_random_uuid()) returning id into v_ses;
  insert into public.students(reg_no,full_name) values ('RV/1','One') returning id into v_s1;
  insert into public.students(reg_no,full_name) values ('RV/2','Two') returning id into v_s2;
  insert into public.profiles(id,role,student_id) values (v_u1,'student',v_s1),(v_u2,'student',v_s2);
  insert into public.courses(code,title) values ('RVC1','Visibility') returning id into v_c;
  insert into public.student_course_registrations(student_id,course_id,academic_session_id) values (v_s1,v_c,v_ses),(v_s2,v_c,v_ses);
  insert into public.exams(academic_session_id,title,mode,duration_minutes,is_active,show_instant_results) values (v_ses,'Visibility','regular',30,true,false) returning id into v_e;
  insert into public.exam_courses(exam_id,course_id,paper_order) values (v_e,v_c,1) returning id into v_ec;
  insert into public.questions(exam_id,exam_course_id,question_number,question_text) values (v_e,v_ec,1,'Q') returning id into v_q;
  insert into public.question_options(question_id,option_key,option_text,is_correct) values (v_q,'A','a',true),(v_q,'B','b',false);
  select id into v_opt from public.question_options where question_id = v_q and option_key = 'A';
  perform set_config('t.u1',v_u1::text,true); perform set_config('t.u2',v_u2::text,true);
  perform set_config('t.e',v_e::text,true); perform set_config('t.ec',v_ec::text,true);
  perform set_config('t.q',v_q::text,true); perform set_config('t.opt',v_opt::text,true);
end $$;

-- Student 1 sits and submits through the student wrapper
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$
declare st record; r record;
begin
  select * into st from public.start_exam_paper_v2(current_setting('t.e')::uuid, current_setting('t.ec')::uuid);
  perform set_config('t.sid', st.exam_session_id::text, true);
  assert public.save_exam_answer_v2(st.exam_session_id, st.exam_session_course_id, current_setting('t.q')::uuid, current_setting('t.opt')::uuid);

  begin perform public.submit_exam_paper_v2(st.exam_session_course_id, gen_random_uuid()); raise exception 'direct v2 submit allowed';
  exception when insufficient_privilege then null; end;

  select * into r from public.submit_exam_paper_for_student(st.exam_session_course_id, gen_random_uuid());
  assert r.answered_questions = 1 and r.total_questions = 1 and r.all_papers_submitted, 'wrapper returns counts and progress';
  assert not exists (select 1 from jsonb_object_keys(to_jsonb(r)) k where k in ('score','percentage','correct_answers','wrong_answers')), 'wrapper never returns marks';
end $$;

-- Flag off: the student sees nothing
do $$ begin
  assert (select count(*) from public.exam_results where exam_session_id = current_setting('t.sid')::uuid) = 0, 'no result visible while the flag is off';
end $$;
reset role;

-- Flag on: the student sees exactly their own result, with the course joinable
update public.exams set show_instant_results = true where id = current_setting('t.e')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.u1'), true);
do $$
declare r record;
begin
  select r2.percentage, r2.correct_answers, c.code into r
  from public.exam_results r2
  join public.exam_session_courses esc on esc.id = r2.exam_session_course_id
  join public.exam_courses ec on ec.id = esc.exam_course_id
  join public.courses c on c.id = ec.course_id
  where r2.exam_session_id = current_setting('t.sid')::uuid;
  assert r.percentage = 100 and r.correct_answers = 1 and r.code = 'RVC1', 'own result visible with course details when the flag is on';
end $$;

-- Another student never sees it
select set_config('request.jwt.claim.sub', current_setting('t.u2'), true);
do $$ begin
  assert (select count(*) from public.exam_results) = 0, 'other students cannot read the result';
end $$;
reset role;

select 'ALL RESULT VISIBILITY CHECKS PASSED' as result;
rollback;
