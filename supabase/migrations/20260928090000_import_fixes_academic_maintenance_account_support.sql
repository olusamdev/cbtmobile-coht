-- ============================================================
-- Import hardening, academic structure edit/delete, and student
-- account provisioning support.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Safe parsing for imports
-- ------------------------------------------------------------
-- A bad value in one row must produce a row-level validation error, never an
-- uncaught cast or CHECK-constraint failure that aborts the whole import.

create or replace function public.import_int(p text)
returns integer
language sql
immutable
as $$
  select case
    when nullif(trim(coalesce(p, '')), '') ~ '^[0-9]{1,9}$' then trim(p)::integer
    else null
  end
$$;

create or replace function public.import_semester(p text)
returns integer
language sql
immutable
as $$
  select case lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'))
    when '1' then 1 when '1st' then 1 when 'first' then 1
    when 'semester 1' then 1 when '1st semester' then 1 when 'first semester' then 1
    when '2' then 2 when '2nd' then 2 when 'second' then 2
    when 'semester 2' then 2 when '2nd semester' then 2 when 'second semester' then 2
    else null
  end
$$;

-- ------------------------------------------------------------
-- 2. superadmin_validate_import with row-level semester/level/credit checks
-- ------------------------------------------------------------

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
  v_sem_raw text;
  v_sem int;
  v_lvl_raw text;
  v_credit_raw text;
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
      v_level := public.import_int(r->>'level');
      if nullif(trim(coalesce(r->>'level','')), '') is not null and v_level is null then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','level','severity','error','message','Level must be a whole number; found "' || trim(r->>'level') || '".')); v_error := true; end if;
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
      v_sem_raw := nullif(trim(coalesce(r->>'semester','')), '');
      v_sem := public.import_semester(v_sem_raw);
      if v_sem_raw is not null and v_sem is null then
        v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','semester','severity','error','message','Semester must be 1 (first) or 2 (second); found "' || v_sem_raw || '".')); v_error := true;
      end if;
      v_lvl_raw := nullif(trim(coalesce(r->>'level','')), '');
      if v_lvl_raw is not null and public.import_int(v_lvl_raw) is null then
        v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','level','severity','error','message','Level must be a whole number; found "' || v_lvl_raw || '".')); v_error := true;
      end if;
      v_credit_raw := nullif(trim(coalesce(r->>'credit_units','')), '');
      if v_credit_raw is not null and public.import_int(v_credit_raw) is null then
        v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','credit_units','severity','error','message','Credit units must be a whole number; found "' || v_credit_raw || '".')); v_error := true;
      end if;
      if not v_error then
        select exists(select 1 from public.courses c where upper(c.code)=v_course and c.department_id=v_dept_id and c.programme_id=v_prog_id) into v_exists;
        if v_exists then v_issues := v_issues || jsonb_build_array(jsonb_build_object('row',i,'field','code','severity','warning','message','Course already exists and will be updated.')); v_warning := true; end if;
        v_normalized := v_normalized || jsonb_build_array(jsonb_build_object('code',v_course,'title',v_title,'department_id',v_dept_id,'programme_id',v_prog_id,'level',public.import_int(r->>'level'),'semester',v_sem,'credit_units',public.import_int(r->>'credit_units')));
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

-- ------------------------------------------------------------
-- 3. Academic structure and session maintenance
-- ------------------------------------------------------------

create or replace function public.require_superadmin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_profile public.profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required.'; end if;
  select * into v_profile from public.profiles where id = auth.uid();
  if v_profile.role is distinct from 'superadmin' or not coalesce(v_profile.is_active, false) then
    raise exception 'SuperAdmin authorization required.';
  end if;
end;
$$;

revoke all on function public.require_superadmin() from public, anon;
grant execute on function public.require_superadmin() to authenticated;

create or replace function public.superadmin_update_academic_session(
  p_session_id uuid, p_name text, p_start_date date, p_end_date date
) returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Session name is required.'; end if;
  if p_start_date is not null and p_end_date is not null and p_end_date < p_start_date then
    raise exception 'The end date cannot be earlier than the start date.';
  end if;
  update public.academic_sessions
  set name = trim(p_name), start_date = p_start_date, end_date = p_end_date, updated_at = now()
  where id = p_session_id;
  if not found then raise exception 'Academic session not found.'; end if;
exception when unique_violation then
  raise exception 'An academic session with this name already exists.';
end;
$$;

create or replace function public.superadmin_delete_academic_session(p_session_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_current boolean;
begin
  perform public.require_superadmin();
  select is_current into v_current from public.academic_sessions where id = p_session_id;
  if not found then raise exception 'Academic session not found.'; end if;
  if v_current then raise exception 'This is the current session. Make another session current before deleting it.'; end if;
  delete from public.academic_sessions where id = p_session_id;
exception when foreign_key_violation then
  raise exception 'This session is used by examinations or registrations and cannot be deleted. Deactivate it instead.';
end;
$$;

create or replace function public.superadmin_update_department(p_department_id uuid, p_code text, p_name text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  if nullif(trim(coalesce(p_code, '')), '') is null then raise exception 'Department code is required.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Department name is required.'; end if;
  update public.departments
  set code = upper(trim(p_code)), name = trim(p_name), updated_at = now()
  where id = p_department_id;
  if not found then raise exception 'Department not found.'; end if;
exception when unique_violation then
  raise exception 'Another department already uses this code or name.';
end;
$$;

create or replace function public.superadmin_set_department_active(p_department_id uuid, p_is_active boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  update public.departments set is_active = p_is_active, updated_at = now() where id = p_department_id;
  if not found then raise exception 'Department not found.'; end if;
end;
$$;

create or replace function public.superadmin_delete_department(p_department_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  delete from public.departments where id = p_department_id;
  if not found then raise exception 'Department not found.'; end if;
exception when foreign_key_violation then
  raise exception 'This department still has programmes, courses or students and cannot be deleted. Deactivate it instead.';
end;
$$;

create or replace function public.superadmin_update_programme(
  p_programme_id uuid, p_code text, p_name text, p_duration_years integer
) returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  if nullif(trim(coalesce(p_code, '')), '') is null then raise exception 'Programme code is required.'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Programme name is required.'; end if;
  if p_duration_years is not null and p_duration_years <= 0 then raise exception 'Duration must be a positive number of years.'; end if;
  update public.programmes
  set code = upper(trim(p_code)), name = trim(p_name), duration_years = p_duration_years, updated_at = now()
  where id = p_programme_id;
  if not found then raise exception 'Programme not found.'; end if;
exception when unique_violation then
  raise exception 'Another programme in this department already uses this code.';
end;
$$;

create or replace function public.superadmin_set_programme_active(p_programme_id uuid, p_is_active boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  update public.programmes set is_active = p_is_active, updated_at = now() where id = p_programme_id;
  if not found then raise exception 'Programme not found.'; end if;
end;
$$;

create or replace function public.superadmin_delete_programme(p_programme_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.require_superadmin();
  delete from public.programmes where id = p_programme_id;
  if not found then raise exception 'Programme not found.'; end if;
exception when foreign_key_violation then
  raise exception 'This programme still has students or courses and cannot be deleted. Deactivate it instead.';
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'superadmin_update_academic_session(uuid,text,date,date)',
    'superadmin_delete_academic_session(uuid)',
    'superadmin_update_department(uuid,text,text)',
    'superadmin_set_department_active(uuid,boolean)',
    'superadmin_delete_department(uuid)',
    'superadmin_update_programme(uuid,text,text,integer)',
    'superadmin_set_programme_active(uuid,boolean)',
    'superadmin_delete_programme(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ------------------------------------------------------------
-- 4. Student Auth account provisioning support (edge function, service role)
-- ------------------------------------------------------------

create or replace function public.find_auth_user_id(p_email text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from auth.users where lower(email) = lower(trim(p_email)) limit 1
$$;

revoke all on function public.find_auth_user_id(text) from public, anon, authenticated;
grant execute on function public.find_auth_user_id(text) to service_role;
