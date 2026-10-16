-- ============================================================
-- Archive, restore and delete examination results by scope
-- ============================================================
-- Scopes: all results, one department, one examination, or one paper.
-- Archiving hides results from the Results screen (and exports) without losing
-- them; deleting removes the result rows permanently. Sittings, answers and the
-- audit trail of each sitting are not touched by either.

alter table public.exam_results
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid;

create index if not exists exam_results_archived_at_idx on public.exam_results(archived_at) where archived_at is not null;

create table if not exists public.results_admin_log (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('archive', 'restore', 'delete')),
  scope text not null,
  scope_label text not null,
  affected integer not null,
  reason text,
  performed_by uuid,
  created_at timestamptz not null default now()
);

alter table public.results_admin_log enable row level security;
revoke all on public.results_admin_log from anon, authenticated;

-- Internal: the result ids a scope covers.
create or replace function public.results_in_scope(
  p_scope text, p_department_id uuid, p_exam_id uuid, p_exam_course_id uuid
) returns table(result_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if p_scope = 'all' then
    return query select r.id from public.exam_results r;
  elsif p_scope = 'department' then
    if p_department_id is null then raise exception 'Choose a department.'; end if;
    return query
    select r.id from public.exam_results r
    join public.students s on s.id = r.student_id
    join public.programmes p on p.id = s.programme_id
    where p.department_id = p_department_id;
  elsif p_scope = 'examination' then
    if p_exam_id is null then raise exception 'Choose an examination.'; end if;
    return query select r.id from public.exam_results r where r.exam_id = p_exam_id;
  elsif p_scope = 'paper' then
    if p_exam_course_id is null then raise exception 'Choose a paper.'; end if;
    return query
    select r.id from public.exam_results r
    join public.exam_session_courses esc on esc.id = r.exam_session_course_id
    where esc.exam_course_id = p_exam_course_id;
  else
    raise exception 'Unknown scope. Use all, department, examination or paper.';
  end if;
end;
$$;

revoke all on function public.results_in_scope(text, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.results_scope_label(
  p_scope text, p_department_id uuid, p_exam_id uuid, p_exam_course_id uuid
) returns text
language sql
stable
security definer
set search_path = public
as $$
  select case p_scope
    when 'all' then 'All results'
    when 'department' then 'Department ' || coalesce((select d.code || ' · ' || d.name from public.departments d where d.id = p_department_id), '?')
    when 'examination' then 'Examination ' || coalesce((select e.title from public.exams e where e.id = p_exam_id), '?')
    when 'paper' then 'Paper ' || coalesce((
      select c.code || ' · ' || e.title
      from public.exam_courses ec join public.courses c on c.id = ec.course_id join public.exams e on e.id = ec.exam_id
      where ec.id = p_exam_course_id), '?')
    else p_scope
  end
$$;

revoke all on function public.results_scope_label(text, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.superadmin_results_scope_summary(
  p_scope text, p_department_id uuid default null, p_exam_id uuid default null, p_exam_course_id uuid default null
) returns table(total integer, active integer, archived integer)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.require_superadmin();
  return query
  select count(*)::integer,
         count(*) filter (where r.archived_at is null)::integer,
         count(*) filter (where r.archived_at is not null)::integer
  from public.exam_results r
  where r.id in (select x.result_id from public.results_in_scope(p_scope, p_department_id, p_exam_id, p_exam_course_id) x);
end;
$$;

create or replace function public.superadmin_archive_results(
  p_scope text, p_department_id uuid default null, p_exam_id uuid default null, p_exam_course_id uuid default null,
  p_reason text default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  perform public.require_superadmin();
  with moved as (
    update public.exam_results r
    set archived_at = now(), archived_by = auth.uid()
    where r.archived_at is null
      and r.id in (select x.result_id from public.results_in_scope(p_scope, p_department_id, p_exam_id, p_exam_course_id) x)
    returning 1
  )
  select count(*) into n from moved;

  insert into public.results_admin_log(action, scope, scope_label, affected, reason, performed_by)
  values ('archive', p_scope, public.results_scope_label(p_scope, p_department_id, p_exam_id, p_exam_course_id), n, nullif(trim(coalesce(p_reason, '')), ''), auth.uid());
  return n;
end;
$$;

create or replace function public.superadmin_restore_results(
  p_scope text, p_department_id uuid default null, p_exam_id uuid default null, p_exam_course_id uuid default null,
  p_reason text default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  perform public.require_superadmin();
  with moved as (
    update public.exam_results r
    set archived_at = null, archived_by = null
    where r.archived_at is not null
      and r.id in (select x.result_id from public.results_in_scope(p_scope, p_department_id, p_exam_id, p_exam_course_id) x)
    returning 1
  )
  select count(*) into n from moved;

  insert into public.results_admin_log(action, scope, scope_label, affected, reason, performed_by)
  values ('restore', p_scope, public.results_scope_label(p_scope, p_department_id, p_exam_id, p_exam_course_id), n, nullif(trim(coalesce(p_reason, '')), ''), auth.uid());
  return n;
end;
$$;

-- Permanent. The caller must send the word DELETE so a stray API call cannot remove results.
create or replace function public.superadmin_delete_results(
  p_scope text, p_department_id uuid default null, p_exam_id uuid default null, p_exam_course_id uuid default null,
  p_confirm text default null, p_reason text default null
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
  v_ids uuid[];
begin
  perform public.require_superadmin();
  if p_confirm is distinct from 'DELETE' then
    raise exception 'Type DELETE to confirm that these results are removed permanently.';
  end if;

  select coalesce(array_agg(x.result_id), '{}') into v_ids
  from public.results_in_scope(p_scope, p_department_id, p_exam_id, p_exam_course_id) x;

  delete from public.result_mail_requests where exam_result_id = any(v_ids);
  delete from public.exam_results where id = any(v_ids);
  get diagnostics n = row_count;

  insert into public.results_admin_log(action, scope, scope_label, affected, reason, performed_by)
  values ('delete', p_scope, public.results_scope_label(p_scope, p_department_id, p_exam_id, p_exam_course_id), n, nullif(trim(coalesce(p_reason, '')), ''), auth.uid());
  return n;
end;
$$;

create or replace function public.superadmin_list_results_admin_log(p_limit integer default 10)
returns table(id uuid, action text, scope_label text, affected integer, reason text, performed_by_name text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.require_superadmin();
  return query
  select l.id, l.action, l.scope_label, l.affected, l.reason, coalesce(p.display_name, 'SuperAdmin'), l.created_at
  from public.results_admin_log l
  left join public.profiles p on p.id = l.performed_by
  order by l.created_at desc
  limit greatest(1, least(coalesce(p_limit, 10), 50));
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'superadmin_results_scope_summary(text,uuid,uuid,uuid)',
    'superadmin_archive_results(text,uuid,uuid,uuid,text)',
    'superadmin_restore_results(text,uuid,uuid,uuid,text)',
    'superadmin_delete_results(text,uuid,uuid,uuid,text,text)',
    'superadmin_list_results_admin_log(integer)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
