-- COHT CBT: SuperAdmin academic structure management
-- Department -> Programme/Cadre maintenance. All writes are server-authorized.
create or replace function public.superadmin_list_academic_structure()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_role text; v_active boolean;
begin
  select role, is_active into v_role, v_active from public.profiles where id=v_user;
  if v_user is null or v_role <> 'superadmin' or not coalesce(v_active,false) then raise exception 'SuperAdmin authorization required.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'code',d.code,'name',d.name,'is_active',d.is_active,'programmes',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'department_id',p.department_id,'code',p.code,'name',p.name,'duration_years',p.duration_years,'is_active',p.is_active) order by p.name) from public.programmes p where p.department_id=d.id),'[]'::jsonb)) order by d.name) from public.departments d),'[]'::jsonb);
end; $$;
create or replace function public.superadmin_create_department(p_code text,p_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_role text; v_active boolean; v_id uuid; v_code text:=upper(trim(p_code)); v_name text:=trim(p_name);
begin
 select role,is_active into v_role,v_active from public.profiles where id=v_user;
 if v_user is null or v_role<>'superadmin' or not coalesce(v_active,false) then raise exception 'SuperAdmin authorization required.'; end if;
 if v_code='' or v_name='' then raise exception 'Department code and name are required.'; end if;
 if length(v_code)>20 then raise exception 'Department code is too long.'; end if;
 if exists(select 1 from public.departments where upper(code)=v_code) then raise exception 'A department with code % already exists.',v_code; end if;
 if exists(select 1 from public.departments where lower(name)=lower(v_name)) then raise exception 'A department with this name already exists.'; end if;
 insert into public.departments(code,name,is_active) values(v_code,v_name,true) returning id into v_id;
 return jsonb_build_object('id',v_id,'code',v_code,'name',v_name,'is_active',true,'programmes','[]'::jsonb);
end; $$;
create or replace function public.superadmin_create_programme(p_department_id uuid,p_code text,p_name text,p_duration_years integer default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_role text; v_active boolean; v_id uuid; v_code text:=upper(trim(p_code)); v_name text:=trim(p_name);
begin
 select role,is_active into v_role,v_active from public.profiles where id=v_user;
 if v_user is null or v_role<>'superadmin' or not coalesce(v_active,false) then raise exception 'SuperAdmin authorization required.'; end if;
 if not exists(select 1 from public.departments where id=p_department_id and is_active) then raise exception 'Selected department does not exist or is inactive.'; end if;
 if v_code='' or v_name='' then raise exception 'Programme code and name are required.'; end if;
 if p_duration_years is not null and p_duration_years<=0 then raise exception 'Duration must be a positive number of years.'; end if;
 if exists(select 1 from public.programmes where department_id=p_department_id and upper(code)=v_code) then raise exception 'This programme code already exists in the selected department.'; end if;
 insert into public.programmes(department_id,code,name,duration_years,is_active) values(p_department_id,v_code,v_name,p_duration_years,true) returning id into v_id;
 return jsonb_build_object('id',v_id,'department_id',p_department_id,'code',v_code,'name',v_name,'duration_years',p_duration_years,'is_active',true);
end; $$;
grant execute on function public.superadmin_list_academic_structure() to authenticated;
grant execute on function public.superadmin_create_department(text,text) to authenticated;
grant execute on function public.superadmin_create_programme(uuid,text,text,integer) to authenticated;
