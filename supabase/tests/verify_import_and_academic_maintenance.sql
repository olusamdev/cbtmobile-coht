-- Verifies import hardening and academic structure maintenance. Rolled back at the end.
begin;

do $$
declare v_admin uuid := gen_random_uuid(); v_dept uuid; v_prog uuid; v_session uuid; v_used uuid;
begin
  insert into auth.users(id, email) values (v_admin, 'su@test.local');
  insert into public.profiles(id, role) values (v_admin, 'superadmin');
  insert into public.departments(code, name) values ('PHT', 'Pharmacy Technician') returning id into v_dept;
  insert into public.programmes(department_id, code, name) values (v_dept, 'ND', 'National Diploma') returning id into v_prog;
  insert into public.academic_sessions(name) values ('2026/2027') returning id into v_session;
  insert into public.academic_sessions(name) values ('2025/2026') returning id into v_used;
  insert into public.exams(academic_session_id, title) values (v_used, 'Uses old session');
  perform set_config('test.admin', v_admin::text, true);
  perform set_config('test.dept', v_dept::text, true);
  perform set_config('test.prog', v_prog::text, true);
  perform set_config('test.session', v_session::text, true);
  perform set_config('test.used', v_used::text, true);
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
end $$;

-- 1. Courses: semester / level / credit validation produces row errors, never a crash
do $$
declare v jsonb; msgs text;
begin
  v := public.superadmin_validate_import('courses', jsonb_build_array(
    jsonb_build_object('code','PHT101','title','A','department_code','PHT','programme_code','ND','level','100','semester','1','credit_units','2'),
    jsonb_build_object('code','PHT102','title','B','department_code','PHT','programme_code','ND','level','100','semester','Second','credit_units','3'),
    jsonb_build_object('code','PHT103','title','C','department_code','PHT','programme_code','ND','level','100','semester','3','credit_units','2'),
    jsonb_build_object('code','PHT104','title','D','department_code','PHT','programme_code','ND','level','ND1','semester','1','credit_units','x'),
    jsonb_build_object('code','PHT105','title','E','department_code','PHT','programme_code','ND','level','','semester','','credit_units','')
  ));
  assert (v->>'errorRows')::int = 2, 'rows 3 and 4 must be errors, got ' || (v->>'errorRows');
  assert (v->>'validRows')::int = 3, 'three valid rows';
  select string_agg(e->>'message', ' | ') into msgs from jsonb_array_elements(v->'issues') e;
  assert msgs like '%Semester must be 1 (first) or 2 (second); found "3"%', 'semester 3 reported with its value';
  assert msgs like '%Level must be a whole number; found "ND1"%', 'level text reported';
  assert msgs like '%Credit units must be a whole number; found "x"%', 'credit units text reported';
  assert (v->'normalizedRows'->1->>'semester')::int = 2, 'Second normalises to 2';
  assert v->'normalizedRows'->2->>'semester' is null, 'blank semester stays null';
end $$;

-- 2. Confirm imports only the valid set and never trips the CHECK constraint
do $$
declare r jsonb;
begin
  r := public.superadmin_confirm_import('courses', jsonb_build_array(
    jsonb_build_object('code','PHT201','title','Ok','department_code','PHT','programme_code','ND','level','200','semester','2','credit_units','2')
  ));
  assert (r->>'imported')::int = 1, 'course imported';
  begin
    perform public.superadmin_confirm_import('courses', jsonb_build_array(
      jsonb_build_object('code','PHT202','title','Bad','department_code','PHT','programme_code','ND','semester','3')));
    raise exception 'confirm accepted semester 3';
  exception when others then
    assert sqlerrm like '%validation error%', 'confirm refuses with a clear message, got: ' || sqlerrm;
  end;
end $$;

-- 3. Students: level must be numeric
do $$
declare v jsonb;
begin
  v := public.superadmin_validate_import('students', jsonb_build_array(
    jsonb_build_object('reg_no','S1','full_name','A','department_code','PHT','programme_code','ND','level','ND1')));
  assert (v->>'errorRows')::int = 1, 'text level is a row error';
end $$;

-- 4. Academic maintenance
do $$
declare v_dept uuid := current_setting('test.dept')::uuid; v_prog uuid := current_setting('test.prog')::uuid;
        v_session uuid := current_setting('test.session')::uuid; v_used uuid := current_setting('test.used')::uuid;
begin
  perform public.superadmin_update_academic_session(v_session, '2026/2027 Edited', date '2026-09-01', date '2027-07-31');
  assert (select name from public.academic_sessions where id = v_session) = '2026/2027 Edited';

  begin perform public.superadmin_update_academic_session(v_session, '2025/2026', null, null); raise exception 'dup accepted';
  exception when others then assert sqlerrm = 'An academic session with this name already exists.', sqlerrm; end;

  begin perform public.superadmin_delete_academic_session(v_used); raise exception 'in-use delete accepted';
  exception when others then assert sqlerrm like '%cannot be deleted. Deactivate it instead.', sqlerrm; end;

  perform public.superadmin_delete_academic_session(v_session);
  assert not exists (select 1 from public.academic_sessions where id = v_session), 'unused session deleted';

  perform public.superadmin_update_department(v_dept, ' pht ', 'Pharmacy Technology');
  assert (select code || '|' || name from public.departments where id = v_dept) = 'PHT|Pharmacy Technology';

  perform public.superadmin_update_programme(v_prog, 'nd', 'National Diploma (ND)', 2);
  assert (select duration_years from public.programmes where id = v_prog) = 2;

  perform public.superadmin_set_programme_active(v_prog, false);
  perform public.superadmin_set_department_active(v_dept, false);
  assert not (select is_active from public.departments where id = v_dept);

  begin perform public.superadmin_delete_department(v_dept); raise exception 'dept delete accepted';
  exception when others then assert sqlerrm like '%cannot be deleted. Deactivate it instead.', sqlerrm; end;

  begin perform public.superadmin_delete_programme(v_prog); raise exception 'programme delete accepted';
  exception when others then assert sqlerrm like '%cannot be deleted. Deactivate it instead.', sqlerrm; end;
end $$;

-- 5. Non-superadmins are refused
do $$
declare v_plain uuid := gen_random_uuid();
begin
  insert into auth.users(id, email) values (v_plain, 'plain@test.local');
  insert into public.profiles(id, role) values (v_plain, 'admin');
  perform set_config('request.jwt.claim.sub', v_plain::text, true);
  begin perform public.superadmin_delete_department(current_setting('test.dept')::uuid); raise exception 'admin allowed';
  exception when others then assert sqlerrm = 'SuperAdmin authorization required.', sqlerrm; end;
end $$;

-- 6. Auth lookup helper
do $$
begin
  assert public.find_auth_user_id(' SU@test.local ') is not null, 'lookup is case/space insensitive';
  assert public.find_auth_user_id('nobody@test.local') is null;
end $$;

select 'ALL IMPORT/ACADEMIC CHECKS PASSED' as result;
rollback;
