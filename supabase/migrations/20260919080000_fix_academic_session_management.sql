-- COHT CBT: academic session management RPCs
-- Creates the RPCs required by the SuperAdmin Academic Structure page.

create or replace function public.superadmin_list_academic_sessions()
returns table (
  id uuid,
  name text,
  start_date date,
  end_date date,
  is_current boolean,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'superadmin'
      and p.is_active = true
  ) then
    raise exception 'SuperAdmin authorization required';
  end if;

  return query
    select s.id, s.name, s.start_date, s.end_date,
           s.is_current, s.is_active, s.created_at, s.updated_at
    from public.academic_sessions s
    order by s.is_current desc, s.start_date desc nulls last, s.name;
end;
$$;

create or replace function public.superadmin_create_academic_session(
  p_name text,
  p_start_date date default null,
  p_end_date date default null,
  p_is_current boolean default false
)
returns public.academic_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.academic_sessions;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'superadmin'
      and p.is_active = true
  ) then
    raise exception 'SuperAdmin authorization required';
  end if;

  if nullif(trim(p_name), '') is null then
    raise exception 'Session name is required';
  end if;

  if p_end_date is not null and p_start_date is not null and p_end_date < p_start_date then
    raise exception 'End date cannot be before start date';
  end if;

  if p_is_current then
    update public.academic_sessions
      set is_current = false, updated_at = now()
      where is_current = true;
  end if;

  insert into public.academic_sessions(name, start_date, end_date, is_current, is_active)
  values (trim(p_name), p_start_date, p_end_date, p_is_current, true)
  returning * into v_session;

  return v_session;
exception
  when unique_violation then
    raise exception 'An academic session with that name already exists';
end;
$$;

create or replace function public.superadmin_set_academic_session_current(
  p_session_id uuid
)
returns public.academic_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.academic_sessions;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'superadmin'
      and p.is_active = true
  ) then
    raise exception 'SuperAdmin authorization required';
  end if;

  update public.academic_sessions
    set is_current = false, updated_at = now()
    where is_current = true;

  update public.academic_sessions
    set is_current = true, is_active = true, updated_at = now()
    where id = p_session_id
    returning * into v_session;

  if not found then
    raise exception 'Academic session not found';
  end if;

  return v_session;
end;
$$;

create or replace function public.superadmin_set_academic_session_active(
  p_session_id uuid,
  p_active boolean
)
returns public.academic_sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.academic_sessions;
begin
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role = 'superadmin'
      and p.is_active = true
  ) then
    raise exception 'SuperAdmin authorization required';
  end if;

  if not p_active and exists (
    select 1 from public.academic_sessions s
    where s.id = p_session_id and s.is_current = true
  ) then
    raise exception 'The current academic session cannot be deactivated';
  end if;

  update public.academic_sessions
    set is_active = p_active, updated_at = now()
    where id = p_session_id
    returning * into v_session;

  if not found then
    raise exception 'Academic session not found';
  end if;

  return v_session;
end;
$$;

revoke all on function public.superadmin_list_academic_sessions() from public;
revoke all on function public.superadmin_create_academic_session(text,date,date,boolean) from public;
revoke all on function public.superadmin_set_academic_session_current(uuid) from public;
revoke all on function public.superadmin_set_academic_session_active(uuid,boolean) from public;
grant execute on function public.superadmin_list_academic_sessions() to authenticated;
grant execute on function public.superadmin_create_academic_session(text,date,date,boolean) to authenticated;
grant execute on function public.superadmin_set_academic_session_current(uuid) to authenticated;
grant execute on function public.superadmin_set_academic_session_active(uuid,boolean) to authenticated;
