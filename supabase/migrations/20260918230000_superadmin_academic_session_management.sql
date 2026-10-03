create or replace function public.superadmin_list_academic_sessions()
returns setof public.academic_sessions
language sql security definer set search_path=public as $$
  select s.* from public.academic_sessions s
  where public.current_user_role() = 'superadmin'
  order by s.is_active desc, s.is_current desc, s.start_date desc nulls last, s.name desc;
$$;

create or replace function public.superadmin_create_academic_session(
  p_name text, p_start_date date default null, p_end_date date default null, p_is_current boolean default false
) returns public.academic_sessions
language plpgsql security definer set search_path=public as $$
declare v_session public.academic_sessions;
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'Academic session name is required'; end if;
  if p_end_date is not null and p_start_date is not null and p_end_date < p_start_date then raise exception 'End date cannot be before start date'; end if;
  if p_is_current then update public.academic_sessions set is_current=false, updated_at=now() where is_current=true; end if;
  insert into public.academic_sessions(name,start_date,end_date,is_current,is_active)
  values(trim(p_name),p_start_date,p_end_date,p_is_current,true)
  returning * into v_session;
  return v_session;
exception when unique_violation then raise exception 'An academic session with this name already exists';
end; $$;

create or replace function public.superadmin_set_current_academic_session(p_session_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  if not exists(select 1 from public.academic_sessions where id=p_session_id and is_active) then raise exception 'Only an active academic session can be made current'; end if;
  update public.academic_sessions set is_current=false, updated_at=now();
  update public.academic_sessions set is_current=true, updated_at=now() where id=p_session_id;
end; $$;

create or replace function public.superadmin_set_academic_session_active(p_session_id uuid, p_is_active boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
  if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
  if not p_is_active and exists(select 1 from public.academic_sessions where id=p_session_id and is_current) then raise exception 'Set another session as current before deactivating this session'; end if;
  update public.academic_sessions set is_active=p_is_active, updated_at=now() where id=p_session_id;
  if not found then raise exception 'Academic session not found'; end if;
end; $$;

grant execute on function public.superadmin_list_academic_sessions() to authenticated;
grant execute on function public.superadmin_create_academic_session(text,date,date,boolean) to authenticated;
grant execute on function public.superadmin_set_current_academic_session(uuid) to authenticated;
grant execute on function public.superadmin_set_academic_session_active(uuid,boolean) to authenticated;
