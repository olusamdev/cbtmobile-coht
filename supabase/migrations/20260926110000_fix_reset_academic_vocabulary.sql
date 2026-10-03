-- COHT CBT: correct the academic vocabulary restored by the controlled application-data reset.
--
-- Authoritative course source: courses-template (1).csv (172 rows) and AGENTS.md both
-- require the Community Health programme codes CHEW / JCHEW. The previous definition
-- (20260923220000) restored DCH / CCH instead, so any future reset would recreate a
-- structure the course importer cannot match (106 of 172 rows depend on CHS/CHEW and
-- CHS/JCHEW).
--
-- Scope is deliberately narrow:
--   * CREATE OR REPLACE the reset function with its body byte-identical except for
--     four literals (DCH->CHEW, CCH->JCHEW, and two return-count corrections).
--   * No historical migration is edited.
--   * This migration does NOT execute the reset and writes NO academic data.

create or replace function public.superadmin_reset_application_data()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  preserved_count integer;
  student_auth_count integer := 0;
  tables_sql text;
  d_id uuid;
begin
  if public.current_user_role() <> 'superadmin' then
    raise exception 'SuperAdmin authorization required';
  end if;

  create temporary table coht_preserved_staff on commit drop as
    select * from public.profiles where role in ('admin','superadmin');

  select count(*) into preserved_count from coht_preserved_staff;

  -- Remove student Auth accounts first. Their profiles cascade away.
  -- Staff Auth accounts are deliberately untouched.
  delete from auth.users
  where id in (
    select id from public.profiles where role = 'student'
  );
  get diagnostics student_auth_count = row_count;

  select string_agg(
    format('%I.%I', schemaname, tablename),
    ', ' order by tablename
  )
  into tables_sql
  from pg_tables
  where schemaname = 'public'
    and tablename not in ('spatial_ref_sys');

  if tables_sql is null then
    raise exception 'No application tables found';
  end if;

  execute 'truncate table ' || tables_sql || ' cascade';

  -- Restore staff profiles before using the protected academic-structure RPCs.
  insert into public.profiles
  select * from coht_preserved_staff;

  /*
    Restore the canonical academic foundation.

    We deliberately call the existing SuperAdmin structure RPCs rather than
    hard-coding table columns here. This keeps the reset compatible with the
    live academic schema and preserves the same validation rules used by the
    Academic Structure screen.
  */
  perform public.superadmin_create_department(
    'Community Health',
    'CHS'
  );

  select id into d_id
  from public.departments
  where code = 'CHS'
  limit 1;

  perform public.superadmin_create_programme(
    d_id,
    'Community Health Extension Worker',
    'CHEW',
    null
  );

  perform public.superadmin_create_programme(
    d_id,
    'Junior Community Health Extension Worker',
    'JCHEW',
    null
  );

  perform public.superadmin_create_department(
    'Pharmacy Technician',
    'PHT'
  );

  select id into d_id
  from public.departments
  where code = 'PHT'
  limit 1;

  perform public.superadmin_create_programme(
    d_id,
    'Technician',
    'TECH',
    null
  );

  perform public.superadmin_create_department(
    'Health Information Management',
    'NDHIM'
  );

  select id into d_id
  from public.departments
  where code = 'NDHIM'
  limit 1;

  perform public.superadmin_create_programme(
    d_id,
    'National Diploma',
    'ND',
    null
  );

  perform public.superadmin_create_department(
    'Epidemiology and Disease Control',
    'EDC'
  );

  select id into d_id
  from public.departments
  where code = 'EDC'
  limit 1;

  perform public.superadmin_create_programme(
    d_id,
    'National Diploma',
    'ND',
    null
  );

  perform public.superadmin_create_department(
    'Clinical Nutrition and Dietetics',
    'NUD'
  );

  select id into d_id
  from public.departments
  where code = 'NUD'
  limit 1;

  perform public.superadmin_create_programme(
    d_id,
    'National Diploma',
    'ND',
    null
  );

  perform public.superadmin_create_department(
    'Medical Image Processing Technician',
    'MIPT'
  );

  select id into d_id
  from public.departments
  where code = 'MIPT'
  limit 1;

  perform public.superadmin_create_programme(
    d_id,
    'Technician',
    'TECH',
    null
  );

  return jsonb_build_object(
    'status', 'reset',
    'staff_profiles_preserved', preserved_count,
    'student_auth_accounts_removed', student_auth_count,
    'canonical_departments_restored', 6,
    'canonical_programmes_restored', 7
  );
end;
$$;

revoke all on function public.superadmin_reset_application_data() from public;
grant execute on function public.superadmin_reset_application_data() to authenticated;
