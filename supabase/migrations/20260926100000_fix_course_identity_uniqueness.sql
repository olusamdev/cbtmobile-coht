-- COHT CBT: course identity correction.
--
-- Authoritative source: courses-template (1).csv (172 rows, 158 unique course codes).
-- Repeated codes are intentional: the same institutional code is taught in more than
-- one department/programme. The database identity of a course is courses.id; the code
-- is only the human-facing institutional label.
--
-- Scope (deliberately narrow):
--   1. uniqueness correction on public.courses
--   2. course identity logic of superadmin_validate_import()
--   3. course upsert key of superadmin_confirm_import()
-- Everything else is preserved verbatim. Registrations, exam papers, questions,
-- attempts and results already reference courses by id and are untouched.

-- ============================================================
-- 1. UNIQUENESS: global code -> department + programme + code
-- ============================================================
alter table public.courses
  drop constraint if exists courses_code_unique;

alter table public.courses
  add constraint courses_department_programme_code_unique
    unique (department_id, programme_id, code);

-- ============================================================
-- 2. superadmin_validate_import (course identity + registration disambiguation)
-- ============================================================

create or replace function public.superadmin_validate_import(
  p_entity text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_total int := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  v_valid int := 0;
  v_warning_rows int := 0;
  v_error_rows int := 0;
  v_duplicate_rows int := 0;
  v_issues jsonb := '[]'::jsonb;
  v_normalized jsonb := '[]'::jsonb;
  r jsonb;
  i int := 0;
  v_reg text;
  v_name text;
  v_dept text;
  v_prog text;
  v_level int;
  v_course text;
  v_title text;
  v_session text;
  v_type text;
  v_exam uuid;
  v_qnum int;
  v_qtext text;
  v_correct text;
  v_error boolean;
  v_warning boolean;
  v_exists boolean;
  v_dept_id uuid;
  v_prog_id uuid;
  v_course_id uuid;
  v_session_id uuid;
  v_exam_exists boolean;
  v_q_exists boolean;
  v_opts jsonb;
  v_match_count int;
begin
  if v_user is null then raise exception 'Authentication required.'; end if;
  select * into v_profile from public.profiles where id = v_user;
  if v_profile.role <> 'superadmin' or not v_profile.is_active then
    raise exception 'SuperAdmin authorization required.';
  end if;
  if p_entity not in ('students','courses','registrations','questions') then
    raise exception 'Unsupported import type: %', p_entity;
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' then
    raise exception 'Import rows must be a JSON array.';
  end if;
  if v_total > 5000 then raise exception 'Import is limited to 5,000 rows per validation batch.'; end if;

  for r in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    i := i + 1; v_error := false; v_warning := false;

    if p_entity = 'students' then
      v_reg := nullif(trim(coalesce(r->>'reg_no','')), '');
      v_name := nullif(trim(coalesce(r->>'full_name','')), '');
      v_dept := nullif(upper(trim(coalesce(r->>'department_code',''))), '');
      v_prog := nullif(upper(trim(coalesce(r->>'programme_code',''))), '');
      v_level := nullif(trim(coalesce(r->>'level','')), '')::int;
      if v_reg is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','reg_no','severity','error','message','Matriculation number is required.')); v_error := true; end if;
      if v_name is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','full_name','severity','error','message','Full name is required.')); v_error := true; end if;
      if v_dept is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','department_code','severity','error','message','Department code is required.')); v_error := true; end if;
      if v_prog is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','programme_code','severity','error','message','Programme code is required.')); v_error := true; end if;
      if v_level is not null and v_level <= 0 then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','level','severity','error','message','Level must be a positive number.')); v_error := true; end if;
      if not v_error then
        select d.id into v_dept_id from public.departments d where upper(d.code)=v_dept and d.is_active;
        if v_dept_id is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','department_code','severity','error','message','Department code does not exist.')); v_error := true; end if;
        select p.id into v_prog_id from public.programmes p where p.department_id=v_dept_id and upper(p.code)=v_prog and p.is_active;
        if v_prog_id is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','programme_code','severity','error','message','Programme code does not exist in the selected department.')); v_error := true; end if;
      end if;
      if not v_error then
        select exists(select 1 from public.students s where lower(s.reg_no)=lower(v_reg)) into v_exists;
        if v_exists then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','reg_no','severity','warning','message','Student already exists and will be updated.')); v_warning := true; end if;
        v_normalized := v_normalized || jsonb_build_array(jsonb_build_object('reg_no',v_reg,'full_name',v_name,'programme_id',v_prog_id,'level',v_level));
      end if;

    elsif p_entity = 'courses' then
      v_course := nullif(upper(trim(coalesce(r->>'code',''))), ''); v_title := nullif(trim(coalesce(r->>'title','')), '');
      v_dept := nullif(upper(trim(coalesce(r->>'department_code',''))), ''); v_prog := nullif(upper(trim(coalesce(r->>'programme_code',''))), '');
      if v_course is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','code','severity','error','message','Course code is required.')); v_error := true; end if;
      if v_title is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','title','severity','error','message','Course title is required.')); v_error := true; end if;
      if v_dept is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','department_code','severity','error','message','Department code is required.')); v_error := true; end if;
      if v_prog is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','programme_code','severity','error','message','Programme code is required.')); v_error := true; end if;
      if not v_error then
        select d.id into v_dept_id from public.departments d where upper(d.code)=v_dept and d.is_active;
        select p.id into v_prog_id from public.programmes p where p.department_id=v_dept_id and upper(p.code)=v_prog and p.is_active;
        if v_dept_id is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','department_code','severity','error','message','Department code does not exist.')); v_error := true; end if;
        if v_prog_id is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','programme_code','severity','error','message','Programme code does not exist in the selected department.')); v_error := true; end if;
      end if;
      if not v_error then
        select exists(select 1 from public.courses c where upper(c.code)=v_course and c.department_id=v_dept_id and c.programme_id=v_prog_id) into v_exists;
        if v_exists then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','code','severity','warning','message','Course already exists and will be updated.')); v_warning := true; end if;
        v_normalized := v_normalized || jsonb_build_array(jsonb_build_object('code',v_course,'title',v_title,'department_id',v_dept_id,'programme_id',v_prog_id,'level',nullif(trim(coalesce(r->>'level','')),'')::int,'semester',nullif(trim(coalesce(r->>'semester','')),'')::int,'credit_units',nullif(trim(coalesce(r->>'credit_units','')),'')::int));
      end if;

    elsif p_entity = 'registrations' then
      v_reg := nullif(trim(coalesce(r->>'reg_no','')), ''); v_course := nullif(upper(trim(coalesce(r->>'course_code',''))), ''); v_session := nullif(trim(coalesce(r->>'academic_session_name','')), ''); v_type := lower(nullif(trim(coalesce(r->>'registration_type','')), ''));
      if v_reg is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','reg_no','severity','error','message','Matriculation number is required.')); v_error := true; end if;
      if v_course is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','course_code','severity','error','message','Course code is required.')); v_error := true; end if;
      if v_session is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','academic_session_name','severity','error','message','Academic session is required.')); v_error := true; end if;
      if v_type is null then v_type := 'regular'; end if;
      if v_type not in ('regular','resit','carry_over','special') then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','registration_type','severity','error','message','Registration type must be regular, resit, carry_over or special.')); v_error := true; end if;
      if not v_error then
        select s.id into v_session_id from public.academic_sessions s where lower(s.name)=lower(v_session) and s.is_active;
        -- Course codes are no longer globally unique (uniqueness is department + programme + code),
        -- so a bare course_code may legitimately match several records. Resolve it explicitly;
        -- never select an arbitrary match. The student programme (students.programme_id -> programmes)
        -- is the only schema-backed academic context available to this import template.
        select count(*) into v_match_count from public.courses c where upper(c.code)=v_course and c.is_active;
        if coalesce(v_match_count,0) > 1 then
          select c.id into v_course_id from public.courses c
           where upper(c.code)=v_course and c.is_active
             and c.programme_id = (select s.programme_id from public.students s where lower(s.reg_no)=lower(v_reg) and s.is_active);
          -- Only report ambiguity when the student row itself is usable;
          -- otherwise the missing-student error is the sole relevant message.
          if v_course_id is null and exists(select 1 from public.students s where lower(s.reg_no)=lower(v_reg) and s.is_active) then
            v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','course_code','severity','error','message','Course code ' || v_course || ' matches ' || v_match_count || ' courses across different departments or programmes, and the student programme cannot resolve it. Registration import requires an academic-context disambiguator (department_code and/or programme_code). No course was selected.'));
            v_error := true;
          end if;
        else
          select c.id into v_course_id from public.courses c where upper(c.code)=v_course and c.is_active;
        end if;
        if not exists(select 1 from public.students s where lower(s.reg_no)=lower(v_reg) and s.is_active) then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','reg_no','severity','error','message','Student matriculation number does not exist.')); v_error := true; end if;
        if v_course_id is null and coalesce(v_match_count,0) = 0 then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','course_code','severity','error','message','Course code does not exist.')); v_error := true; end if;
        if v_session_id is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','academic_session_name','severity','error','message','Academic session does not exist.')); v_error := true; end if;
      end if;
      if not v_error then
        select exists(select 1 from public.student_course_registrations scr join public.students s on s.id=scr.student_id where lower(s.reg_no)=lower(v_reg) and scr.course_id=v_course_id and scr.academic_session_id=v_session_id) into v_exists;
        if v_exists then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','reg_no','severity','warning','message','This registration already exists and will be left unchanged.')); v_warning := true; v_duplicate_rows := v_duplicate_rows + 1; end if;
        v_normalized := v_normalized || jsonb_build_array(jsonb_build_object('reg_no',v_reg,'course_id',v_course_id,'academic_session_id',v_session_id,'registration_type',v_type));
      end if;

    elsif p_entity = 'questions' then
      begin v_exam := nullif(trim(coalesce(r->>'exam_id','')), '')::uuid; exception when others then v_exam := null; end;
      begin v_qnum := nullif(trim(coalesce(r->>'question_number','')), '')::int; exception when others then v_qnum := null; end;
      v_qtext := nullif(trim(coalesce(r->>'question_text','')), ''); v_correct := upper(nullif(trim(coalesce(r->>'correct_option','')), ''));
      if v_exam is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','exam_id','severity','error','message','A valid exam UUID is required.')); v_error := true; end if;
      if v_qnum is null or v_qnum <= 0 then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','question_number','severity','error','message','Question number must be a positive number.')); v_error := true; end if;
      if v_qtext is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','question_text','severity','error','message','Question text is required.')); v_error := true; end if;
      if v_correct not in ('A','B','C','D','E') then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','correct_option','severity','error','message','Correct option must be A, B, C, D or E.')); v_error := true; end if;
      if not v_error then
        select exists(select 1 from public.exams e where e.id=v_exam) into v_exam_exists;
        if not v_exam_exists then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','exam_id','severity','error','message','Exam does not exist.')); v_error := true; end if;
        v_opts := jsonb_build_object('A',nullif(trim(coalesce(r->>'option_a','')),''),'B',nullif(trim(coalesce(r->>'option_b','')),''),'C',nullif(trim(coalesce(r->>'option_c','')),''),'D',nullif(trim(coalesce(r->>'option_d','')),''),'E',nullif(trim(coalesce(r->>'option_e','')),''));
        if (v_opts->>'A') is null or (v_opts->>'B') is null or (v_opts->>'C') is null or (v_opts->>'D') is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','options','severity','error','message','Options A-D are required.')); v_error := true; end if;
      end if;
      if not v_error then
        select exists(select 1 from public.questions q where q.exam_id=v_exam and q.question_number=v_qnum) into v_q_exists;
        if v_q_exists then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','question_number','severity','warning','message','Question already exists and will be updated.')); v_warning := true; end if;
        v_normalized := v_normalized || jsonb_build_array(jsonb_build_object('exam_id',v_exam,'question_number',v_qnum,'question_text',v_qtext,'option_a',v_opts->>'A','option_b',v_opts->>'B','option_c',v_opts->>'C','option_d',v_opts->>'D','option_e',v_opts->>'E','correct_option',v_correct));
      end if;
    end if;

    if v_error then v_error_rows := v_error_rows + 1; else v_valid := v_valid + 1; end if;
    if v_warning then v_warning_rows := v_warning_rows + 1; end if;
  end loop;

  return jsonb_build_object('entity',p_entity,'totalRows',v_total,'validRows',v_valid,'warningRows',v_warning_rows,'errorRows',v_error_rows,'duplicateRows',v_duplicate_rows,'issues',v_issues,'normalizedRows',v_normalized);
end;
$$;

-- ============================================================
-- 3. superadmin_confirm_import (course upsert keyed by dept + programme + code)
-- ============================================================

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
  v_imported int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_student_id uuid;
  v_course_id uuid;
  v_session_id uuid;
  v_question_id uuid;
  v_existing boolean;
  v_validation jsonb;
  v_normalized jsonb;
  v_reg text;
  v_code text;
  v_type text;
  v_exam uuid;
  v_qnum int;
  v_correct text;
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

  -- Validate the human-facing rows, then persist exactly the server-normalized rows.
  v_validation := public.superadmin_validate_import(p_entity, p_rows);
  if coalesce((v_validation->>'errorRows')::int, 0) > 0 then
    raise exception 'Import contains % validation error(s). Validate and correct the file before confirming.', (v_validation->>'errorRows')::int;
  end if;
  v_normalized := coalesce(v_validation->'normalizedRows','[]'::jsonb);

  if p_entity='students' then
    for r in select value from jsonb_array_elements(v_normalized) loop
      v_reg := trim(r->>'reg_no');
      select id into v_student_id from public.students where lower(reg_no)=lower(v_reg);
      if v_student_id is null then
        insert into public.students(reg_no,full_name,programme_id,level)
        values(v_reg,r->>'full_name',(r->>'programme_id')::uuid,nullif(r->>'level','')::int);
        v_imported:=v_imported+1;
      else
        update public.students
        set full_name=r->>'full_name', programme_id=(r->>'programme_id')::uuid,
            level=nullif(r->>'level','')::int, is_active=true, updated_at=now()
        where id=v_student_id;
        v_updated:=v_updated+1;
      end if;
    end loop;

  elsif p_entity='courses' then
    for r in select value from jsonb_array_elements(v_normalized) loop
      v_code := upper(trim(r->>'code'));
      select id into v_course_id from public.courses
       where upper(code)=v_code
         and department_id is not distinct from (r->>'department_id')::uuid
         and programme_id is not distinct from (r->>'programme_id')::uuid;
      if v_course_id is null then
        insert into public.courses(code,title,department_id,programme_id,level,semester,credit_units)
        values(v_code,r->>'title',(r->>'department_id')::uuid,(r->>'programme_id')::uuid,
               nullif(r->>'level','')::int,nullif(r->>'semester','')::int,nullif(r->>'credit_units','')::int);
        v_imported:=v_imported+1;
      else
        update public.courses
        set title=r->>'title', department_id=(r->>'department_id')::uuid,
            programme_id=(r->>'programme_id')::uuid, level=nullif(r->>'level','')::int,
            semester=nullif(r->>'semester','')::int, credit_units=nullif(r->>'credit_units','')::int,
            is_active=true, updated_at=now()
        where id=v_course_id;
        v_updated:=v_updated+1;
      end if;
    end loop;

  elsif p_entity='registrations' then
    for r in select value from jsonb_array_elements(v_normalized) loop
      select id into v_student_id from public.students
      where lower(reg_no)=lower(trim(r->>'reg_no')) and is_active;
      v_course_id := (r->>'course_id')::uuid;
      v_session_id := (r->>'academic_session_id')::uuid;
      v_type := lower(coalesce(r->>'registration_type','regular'));
      select exists(
        select 1 from public.student_course_registrations
        where student_id=v_student_id and course_id=v_course_id and academic_session_id=v_session_id
      ) into v_existing;
      if v_existing then
        v_skipped:=v_skipped+1;
      else
        insert into public.student_course_registrations(student_id,course_id,academic_session_id,registration_type)
        values(v_student_id,v_course_id,v_session_id,v_type);
        v_imported:=v_imported+1;
      end if;
    end loop;

  else
    for r in select value from jsonb_array_elements(v_normalized) loop
      v_exam := (r->>'exam_id')::uuid;
      v_qnum := (r->>'question_number')::int;
      v_correct := upper(r->>'correct_option');
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
      select v_question_id, x.k, x.v, x.k=v_correct
      from jsonb_each_text(jsonb_build_object(
        'A',r->>'option_a','B',r->>'option_b','C',r->>'option_c','D',r->>'option_d','E',r->>'option_e'
      )) x(k,v)
      where nullif(trim(x.v),'') is not null;
    end loop;
  end if;

  return jsonb_build_object('entity',p_entity,'imported',v_imported,'updated',v_updated,'skipped',v_skipped);
end;
$$;

-- ============================================================
-- 4. Preserve the existing execute grants (idempotent).
-- ============================================================
grant execute on function public.superadmin_validate_import(text,jsonb) to authenticated;
grant execute on function public.superadmin_confirm_import(text,jsonb) to authenticated;
