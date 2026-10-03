-- Fix SuperAdmin student imports: resolve department_code + programme_code
-- to the real programme UUID during confirmation. Also repairs existing
-- students imported without a programme assignment.

create or replace function public.superadmin_confirm_import(p_entity text, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles%rowtype;
  r jsonb;
  v_imported int := 0; v_updated int := 0; v_skipped int := 0;
  v_student_id uuid; v_course_id uuid; v_session_id uuid; v_question_id uuid;
  v_existing boolean; v_validation jsonb;
  v_reg text; v_code text; v_type text; v_exam uuid; v_qnum int; v_correct text;
  v_dept_code text; v_prog_code text; v_programme_id uuid; v_level int;
begin
  if v_user is null then raise exception 'Authentication required.'; end if;
  select * into v_profile from public.profiles where id=v_user;
  if v_profile.role <> 'superadmin' or not v_profile.is_active then
    raise exception 'SuperAdmin authorization required.';
  end if;
  if p_entity not in ('students','courses','registrations','questions') then
    raise exception 'Unsupported import type: %',p_entity;
  end if;
  if jsonb_array_length(coalesce(p_rows,'[]'::jsonb)) > 5000 then
    raise exception 'Import is limited to 5,000 rows per confirmation batch.';
  end if;

  -- Re-run validation server-side. This both protects the operation and
  -- guarantees that department/programme references are valid at commit time.
  v_validation := public.superadmin_validate_import(p_entity, p_rows);
  if coalesce((v_validation->>'errorRows')::int, 0) > 0 then
    raise exception 'Import contains % validation error(s). Validate and correct the file before confirming.', (v_validation->>'errorRows')::int;
  end if;

  if p_entity='students' then
    for r in select value from jsonb_array_elements(p_rows) loop
      v_reg := trim(r->>'reg_no');
      v_dept_code := upper(trim(coalesce(r->>'department_code','')));
      v_prog_code := upper(trim(coalesce(r->>'programme_code','')));
      v_level := nullif(trim(coalesce(r->>'level','')), '')::int;

      -- IMPORTANT: CSV rows contain human-facing department/programme codes;
      -- never expect the browser to manufacture or supply UUIDs.
      select p.id into v_programme_id
      from public.programmes p
      join public.departments d on d.id = p.department_id
      where upper(d.code) = v_dept_code
        and upper(p.code) = v_prog_code
        and d.is_active and p.is_active;

      if v_programme_id is null then
        raise exception 'Student % could not be mapped to department % / programme %.',
          v_reg, v_dept_code, v_prog_code;
      end if;

      select id into v_student_id
      from public.students
      where lower(reg_no)=lower(v_reg);

      if v_student_id is null then
        insert into public.students(reg_no,full_name,programme_id,level,is_active)
        values(v_reg,r->>'full_name',v_programme_id,v_level,true);
        v_imported:=v_imported+1;
      else
        update public.students
        set full_name=r->>'full_name',
            programme_id=v_programme_id,
            level=v_level,
            is_active=true,
            updated_at=now()
        where id=v_student_id;
        v_updated:=v_updated+1;
      end if;
    end loop;

  elsif p_entity='courses' then
    for r in select value from jsonb_array_elements(p_rows) loop
      v_code := upper(trim(r->>'code'));
      select id into v_course_id from public.courses where upper(code)=v_code;
      if v_course_id is null then
        insert into public.courses(code,title,department_id,programme_id,level,semester,credit_units)
        values(v_code,r->>'title',(r->>'department_id')::uuid,(r->>'programme_id')::uuid,
               nullif(r->>'level','')::int,nullif(r->>'semester','')::int,nullif(r->>'credit_units','')::int);
        v_imported:=v_imported+1;
      else
        update public.courses set title=r->>'title',department_id=(r->>'department_id')::uuid,
          programme_id=(r->>'programme_id')::uuid,level=nullif(r->>'level','')::int,
          semester=nullif(r->>'semester','')::int,credit_units=nullif(r->>'credit_units','')::int,
          is_active=true,updated_at=now() where id=v_course_id;
        v_updated:=v_updated+1;
      end if;
    end loop;

  elsif p_entity='registrations' then
    for r in select value from jsonb_array_elements(p_rows) loop
      select id into v_student_id from public.students where lower(reg_no)=lower(trim(r->>'reg_no')) and is_active;
      v_course_id := (r->>'course_id')::uuid; v_session_id := (r->>'academic_session_id')::uuid;
      v_type := lower(coalesce(r->>'registration_type','regular'));
      select exists(select 1 from public.student_course_registrations
                    where student_id=v_student_id and course_id=v_course_id and academic_session_id=v_session_id)
      into v_existing;
      if v_existing then v_skipped:=v_skipped+1;
      else
        insert into public.student_course_registrations(student_id,course_id,academic_session_id,registration_type)
        values(v_student_id,v_course_id,v_session_id,v_type);
        v_imported:=v_imported+1;
      end if;
    end loop;

  else
    for r in select value from jsonb_array_elements(p_rows) loop
      v_exam := (r->>'exam_id')::uuid; v_qnum := (r->>'question_number')::int; v_correct := upper(r->>'correct_option');
      select id into v_question_id from public.questions where exam_id=v_exam and question_number=v_qnum;
      if v_question_id is null then
        insert into public.questions(exam_id,question_number,question_text)
        values(v_exam,v_qnum,r->>'question_text') returning id into v_question_id;
        v_imported:=v_imported+1;
      else
        update public.questions set question_text=r->>'question_text',updated_at=now() where id=v_question_id;
        v_updated:=v_updated+1;
      end if;
      delete from public.question_options where question_id=v_question_id;
      insert into public.question_options(question_id,option_key,option_text,is_correct)
      select v_question_id,x.k,x.v,x.k=v_correct
      from jsonb_each_text(jsonb_build_object('A',r->>'option_a','B',r->>'option_b','C',r->>'option_c','D',r->>'option_d','E',r->>'option_e')) x(k,v)
      where nullif(trim(x.v),'') is not null;
    end loop;
  end if;

  return jsonb_build_object('entity',p_entity,'imported',v_imported,'updated',v_updated,'skipped',v_skipped);
end;
$$;

grant execute on function public.superadmin_confirm_import(text,jsonb) to authenticated;
