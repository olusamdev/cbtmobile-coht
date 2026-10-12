-- Verifies single-student creation and one-by-one course registration. Rolled back at the end.
begin;

do $$
declare
  v_su uuid := gen_random_uuid(); v_ad uuid := gen_random_uuid();
  v_d1 uuid; v_d2 uuid; v_p1 uuid; v_p2 uuid; v_p3 uuid; v_ses uuid; v_old uuid;
begin
  insert into auth.users(id,email) values (v_su,'su@add.test'),(v_ad,'ad@add.test');
  insert into public.profiles(id,role,display_name) values (v_su,'superadmin','Super'),(v_ad,'admin','Ada');
  insert into public.departments(code,name) values ('PHT','Pharmacy Technician') returning id into v_d1;
  insert into public.departments(code,name) values ('GNS','General Studies') returning id into v_d2;
  insert into public.programmes(department_id,code,name) values (v_d1,'ND','National Diploma') returning id into v_p1;
  insert into public.programmes(department_id,code,name) values (v_d1,'HND','Higher National Diploma') returning id into v_p2;
  insert into public.programmes(department_id,code,name,is_active) values (v_d1,'OLD','Retired cadre',false) returning id into v_p3;
  insert into public.academic_sessions(name,is_current) values ('ADD/2026',true) returning id into v_ses;
  insert into public.academic_sessions(name,is_active) values ('ADD/OLD',false) returning id into v_old;
  insert into public.courses(code,title,department_id,programme_id,level) values
    ('PHT101','Pharmacology I',v_d1,v_p1,100),('PHT201','Pharmacology II',v_d1,v_p1,200),
    ('PHT301','HND Dispensing',v_d1,v_p2,300),('GNS101','Use of English',v_d2,null,100);
  insert into public.courses(code,title,department_id,programme_id,is_active) values ('PHT999','Retired course',v_d1,v_p1,false);
  perform set_config('t.su',v_su::text,true); perform set_config('t.ad',v_ad::text,true);
  perform set_config('t.p1',v_p1::text,true); perform set_config('t.p3',v_p3::text,true);
  perform set_config('t.ses',v_ses::text,true); perform set_config('t.old',v_old::text,true);
end $$;

select set_config('request.jwt.claim.sub', current_setting('t.su'), true);

-- ===== create student =====
do $$
declare v_id uuid;
begin
  v_id := public.superadmin_create_student('  COHT/ND/001 ', '  Ada   Obi  ', current_setting('t.p1')::uuid, 100);
  assert (select reg_no || '|' || full_name || '|' || level from public.students where id = v_id) = 'COHT/ND/001|Ada Obi|100', 'trimmed and normalised';
  perform set_config('t.st', v_id::text, true);

  begin perform public.superadmin_create_student('cohT/nd/001', 'Dup', current_setting('t.p1')::uuid, null); raise exception 'duplicate accepted';
  exception when others then assert sqlerrm = 'A student with this registration number already exists.', sqlerrm; end;
  begin perform public.superadmin_create_student('COHT ND 002', 'Spaces', current_setting('t.p1')::uuid, null); raise exception 'spaces accepted';
  exception when others then assert sqlerrm = 'Matriculation number cannot contain spaces.', sqlerrm; end;
  begin perform public.superadmin_create_student('', 'Blank', current_setting('t.p1')::uuid, null); raise exception 'blank accepted';
  exception when others then assert sqlerrm = 'Matriculation number is required.', sqlerrm; end;
  begin perform public.superadmin_create_student('X/1', 'A', current_setting('t.p1')::uuid, null); raise exception 'short name accepted';
  exception when others then assert sqlerrm like 'Enter the student%', sqlerrm; end;
  begin perform public.superadmin_create_student('X/2', 'Valid Name', current_setting('t.p3')::uuid, null); raise exception 'inactive programme accepted';
  exception when others then assert sqlerrm = 'Choose an active programme (cadre).', sqlerrm; end;
  begin perform public.superadmin_create_student('X/3', 'Valid Name', null, null); raise exception 'no programme accepted';
  exception when others then assert sqlerrm = 'Choose an active programme (cadre).', sqlerrm; end;
  begin perform public.superadmin_create_student('X/4', 'Valid Name', current_setting('t.p1')::uuid, 0); raise exception 'level 0 accepted';
  exception when others then assert sqlerrm = 'Level must be a positive number.', sqlerrm; end;
end $$;

-- ===== list courses for the student =====
do $$
declare n integer; r record;
begin
  select count(*) into n from public.superadmin_list_courses_for_student(current_setting('t.st')::uuid);
  assert n = 3, 'department courses only (inactive and other departments excluded), got ' || n;
  select * into r from public.superadmin_list_courses_for_student(current_setting('t.st')::uuid) limit 1;
  assert r.matches_programme and r.code = 'PHT101', 'own programme first, lowest level first';
  assert (select count(*) from public.superadmin_list_courses_for_student(current_setting('t.st')::uuid) where code = 'PHT301' and not matches_programme) = 1, 'other cadre of the department is flagged';
  assert (select count(*) from public.superadmin_list_courses_for_student(current_setting('t.st')::uuid, null, true)) = 4, 'all departments option adds service courses';
end $$;

-- ===== register several at once =====
do $$
declare r record; v_p101 uuid; v_p201 uuid; v_gns uuid;
begin
  select id into v_p101 from public.courses where code = 'PHT101';
  select id into v_p201 from public.courses where code = 'PHT201';
  select id into v_gns from public.courses where code = 'GNS101';

  select * into r from public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[v_p101, v_p201, v_p101], current_setting('t.ses')::uuid, 'regular');
  assert r.added = 2 and r.skipped = 0, 'two distinct courses added, got ' || r.added || '/' || r.skipped;

  select * into r from public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[v_p101, v_gns], current_setting('t.ses')::uuid, 'carry_over');
  assert r.added = 1 and r.skipped = 1, 'an existing registration is left unchanged';
  assert (select registration_type from public.student_course_registrations where student_id = current_setting('t.st')::uuid and course_id = v_p101) = 'regular', 'existing registration keeps its type';
  assert (select registration_type from public.student_course_registrations where student_id = current_setting('t.st')::uuid and course_id = v_gns) = 'carry_over', 'new registration takes the chosen type';

  assert (select count(*) from public.superadmin_list_courses_for_student(current_setting('t.st')::uuid) where already_registered) = 2, 'already registered courses are marked';

  begin perform public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[v_p201], current_setting('t.ses')::uuid, 'bogus'); raise exception 'bad type accepted';
  exception when others then assert sqlerrm like 'Registration type must be%', sqlerrm; end;
  begin perform public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[v_p201], current_setting('t.old')::uuid, 'regular'); raise exception 'inactive session accepted';
  exception when others then assert sqlerrm = 'Choose an active academic session.', sqlerrm; end;
  begin perform public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[]::uuid[], current_setting('t.ses')::uuid, 'regular'); raise exception 'empty selection accepted';
  exception when others then assert sqlerrm = 'Select at least one course.', sqlerrm; end;
  begin perform public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[(select id from public.courses where code = 'PHT999')], current_setting('t.ses')::uuid, 'regular'); raise exception 'inactive course accepted';
  exception when others then assert sqlerrm like 'One or more selected courses%', sqlerrm; end;
  begin perform public.superadmin_register_student_courses(gen_random_uuid(), array[v_p201], current_setting('t.ses')::uuid, 'regular'); raise exception 'unknown student accepted';
  exception when others then assert sqlerrm = 'Student not found or inactive.', sqlerrm; end;
end $$;

-- the new student appears in the registry with their courses
do $$ begin
  assert (select count(*) from public.superadmin_list_registered_students(null) where reg_no = 'COHT/ND/001') = 1, 'new student listed';
end $$;

-- ===== admins cannot use any of it =====
select set_config('request.jwt.claim.sub', current_setting('t.ad'), true);
do $$ begin
  begin perform public.superadmin_create_student('Z/1', 'Not Allowed', current_setting('t.p1')::uuid, null); raise exception 'admin created a student';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
  begin perform * from public.superadmin_list_courses_for_student(current_setting('t.st')::uuid); raise exception 'admin listed courses';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
  begin perform * from public.superadmin_register_student_courses(current_setting('t.st')::uuid, array[gen_random_uuid()], current_setting('t.ses')::uuid, 'regular'); raise exception 'admin registered';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
end $$;

select 'ALL ADD STUDENT/COURSE CHECKS PASSED' as result;
rollback;
