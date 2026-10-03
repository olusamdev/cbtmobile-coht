-- COHT CBT: safe SuperAdmin examination management
-- Adds management operations around the existing exams -> exam_courses model.
-- Does not change student exam execution or question delivery.

create or replace function public.superadmin_update_exam(
  p_exam_id uuid,
  p_title text,
  p_duration_minutes integer,
  p_is_active boolean,
  p_show_instant_results boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_exam public.exams%rowtype;
  v_papers integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select * into v_exam
  from public.exams
  where id = p_exam_id
  for update;

  if not found then
    raise exception 'Examination not found';
  end if;

  if nullif(trim(p_title), '') is null then
    raise exception 'Examination title is required';
  end if;
  if p_duration_minutes <= 0 then
    raise exception 'Duration must be greater than zero';
  end if;

  select count(*) into v_papers
  from public.exam_courses
  where exam_id = p_exam_id;

  if p_is_active and v_papers = 0 then
    raise exception 'An examination must have at least one paper before it can be activated';
  end if;

  -- Once live, only a status change or instant-result policy change is allowed.
  -- Definition/paper changes must happen while inactive.
  if v_exam.is_active and p_is_active then
    if trim(p_title) <> v_exam.title or p_duration_minutes <> v_exam.duration_minutes then
      raise exception 'Deactivate the examination before changing its title or duration';
    end if;
  end if;

  update public.exams
  set title = trim(p_title),
      duration_minutes = p_duration_minutes,
      is_active = coalesce(p_is_active, false),
      show_instant_results = coalesce(p_show_instant_results, false)
  where id = p_exam_id;
end;
$function$;

create or replace function public.superadmin_add_exam_paper(
  p_exam_id uuid,
  p_course_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_exam public.exams%rowtype;
  v_paper_id uuid;
  v_next_order integer;
  v_existing integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select * into v_exam
  from public.exams
  where id = p_exam_id
  for update;

  if not found then
    raise exception 'Examination not found';
  end if;
  if v_exam.is_active then
    raise exception 'Deactivate the examination before changing its papers';
  end if;
  if not exists (select 1 from public.courses where id = p_course_id and is_active) then
    raise exception 'Selected course is invalid or inactive';
  end if;
  if exists (select 1 from public.exam_courses where exam_id = p_exam_id and course_id = p_course_id) then
    raise exception 'This course is already attached to the examination';
  end if;

  select count(*) into v_existing from public.exam_courses where exam_id = p_exam_id;
  if v_exam.mode = 'regular' and v_existing >= 1 then
    raise exception 'Regular examinations can contain only one paper';
  end if;

  select coalesce(max(paper_order), 0) + 1 into v_next_order
  from public.exam_courses
  where exam_id = p_exam_id;

  insert into public.exam_courses(exam_id, course_id, paper_order)
  values (p_exam_id, p_course_id, v_next_order)
  returning id into v_paper_id;

  return v_paper_id;
end;
$function$;

create or replace function public.superadmin_remove_exam_paper(
  p_exam_course_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_exam_id uuid;
  v_active boolean;
  v_count integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select ec.exam_id, e.is_active
    into v_exam_id, v_active
  from public.exam_courses ec
  join public.exams e on e.id = ec.exam_id
  where ec.id = p_exam_course_id
  for update of e;

  if not found then
    raise exception 'Examination paper not found';
  end if;
  if v_active then
    raise exception 'Deactivate the examination before changing its papers';
  end if;

  select count(*) into v_count from public.exam_courses where exam_id = v_exam_id;
  -- Zero papers is allowed only while inactive, so a regular paper can be
  -- replaced safely: remove the old paper, then add the new one.
  delete from public.exam_courses where id = p_exam_course_id;

  -- Keep paper ordering contiguous after removal.
  with ordered as (
    select id, row_number() over (order by paper_order, id) as new_order
    from public.exam_courses
    where exam_id = v_exam_id
  )
  update public.exam_courses ec
  set paper_order = ordered.new_order
  from ordered
  where ec.id = ordered.id;
end;
$function$;

create or replace function public.superadmin_delete_exam(
  p_exam_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_active boolean;
  v_sessions integer;
  v_results integer;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  select is_active into v_active from public.exams where id = p_exam_id for update;
  if not found then
    raise exception 'Examination not found';
  end if;
  if v_active then
    raise exception 'Deactivate the examination before deleting it';
  end if;

  select count(*) into v_sessions from public.exam_sessions where exam_id = p_exam_id;
  select count(*) into v_results from public.exam_results where exam_id = p_exam_id;

  if v_sessions > 0 or v_results > 0 then
    raise exception 'This examination has student attempts or results and cannot be deleted. Deactivate it instead.';
  end if;

  delete from public.exams where id = p_exam_id;
end;
$function$;

revoke all on function public.superadmin_update_exam(uuid,text,integer,boolean,boolean) from public;
revoke all on function public.superadmin_add_exam_paper(uuid,uuid) from public;
revoke all on function public.superadmin_remove_exam_paper(uuid) from public;
revoke all on function public.superadmin_delete_exam(uuid) from public;

grant execute on function public.superadmin_update_exam(uuid,text,integer,boolean,boolean) to authenticated;
grant execute on function public.superadmin_add_exam_paper(uuid,uuid) to authenticated;
grant execute on function public.superadmin_remove_exam_paper(uuid) to authenticated;
grant execute on function public.superadmin_delete_exam(uuid) to authenticated;
