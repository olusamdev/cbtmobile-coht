-- COHT CBT — course identity verification script
-- ============================================================
-- NOT a migration. This file lives outside supabase/migrations
-- on purpose: `supabase db push` must never pick it up.
--
-- Purpose: verify that 20260926100000_fix_course_identity_uniqueness.sql
-- produced the intended schema + RPC behaviour, WITHOUT leaving any
-- data behind.
--
-- Section A is strictly read-only.
-- Section B inserts two courses and ROLLS BACK, so no rows persist.
--
-- Run manually, e.g.:
--   psql "$DATABASE_URL" -f supabase/tests/verify_course_identity.sql
-- ============================================================

\set ON_ERROR_STOP on

\echo ''
\echo '=== A. READ-ONLY ASSERTIONS (no writes) ==='

\echo '-- A1. expected unique constraint present'
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.courses'::regclass
  and contype = 'u'
order by conname;

\echo '-- A2. old global constraint must be GONE (expect 0 rows)'
select conname
from pg_constraint
where conrelid = 'public.courses'::regclass
  and conname = 'courses_code_unique';

\echo '-- A3. validate_import duplicate check is dept+programme scoped (expect t)'
select proname,
       (prosrc like '%c.department_id=v_dept_id and c.programme_id=v_prog_id%') as validate_scoped
from pg_proc
where proname = 'superadmin_validate_import';

\echo '-- A4. confirm_import upsert key includes dept+programme (expect t)'
select proname,
       (prosrc like '%department_id is not distinct from%') as confirm_scoped,
       (prosrc like '%upper(code)=v_code%')                  as still_matches_code
from pg_proc
where proname = 'superadmin_confirm_import';

\echo '-- A5. registration path disambiguates rather than guessing (expect t)'
select (prosrc like '%academic-context disambiguator%') as ambiguity_guard_present
from pg_proc
where proname = 'superadmin_validate_import';


-- ============================================================
-- B. COEXISTENCE TEST — wrapped so nothing is persisted
-- ============================================================
\echo ''
\echo '=== B. ROLLBACK TEST: same code, two academic contexts ==='

begin;

  -- Minimal academic context (temporary; rolled back below)
  insert into public.departments (code, name)
  values ('CHS', 'Community Health (verify)');

  insert into public.programmes (department_id, code, name)
  select d.id, 'CHEW', 'Community Health Extension Worker (verify)'
  from public.departments d where d.code = 'CHS';

  insert into public.programmes (department_id, code, name)
  select d.id, 'JCHEW', 'Junior Community Health Extension Worker (verify)'
  from public.departments d where d.code = 'CHS';

  -- Course A: GNS101 / CHS / CHEW
  insert into public.courses (code, title, department_id, programme_id, level, semester, credit_units)
  select 'GNS101', 'USE OF ENGLISH (verify A)', d.id, p.id, 100, 2, null
  from public.departments d
  join public.programmes p on p.department_id = d.id and p.code = 'CHEW'
  where d.code = 'CHS';

  -- Course B: GNS101 / CHS / JCHEW  (same code, same department, different programme)
  insert into public.courses (code, title, department_id, programme_id, level, semester, credit_units)
  select 'GNS101', 'USE OF ENGLISH (verify B)', d.id, p.id, 100, 2, null
  from public.departments d
  join public.programmes p on p.department_id = d.id and p.code = 'JCHEW'
  where d.code = 'CHS';

  \echo '-- B1. BOTH rows must exist with DIFFERENT ids (expect 2 rows)'
  select c.id, c.code, d.code as dept, p.code as prog, c.title
  from public.courses c
  join public.departments d on d.id = c.department_id
  join public.programmes  p on p.id = c.programme_id
  where c.code = 'GNS101'
  order by p.code;

  do $$
  declare n integer;
  begin
    select count(*) into n from public.courses where upper(code) = 'GNS101';
    if n <> 2 then
      raise exception 'FAIL: expected 2 coexisting GNS101 rows, found %', n;
    end if;
    if (select count(distinct id) from public.courses where upper(code)='GNS101') <> 2 then
      raise exception 'FAIL: coexisting rows did not receive distinct course.id values';
    end if;
    raise notice 'PASS: same code + different programme coexist as separate course.id records';
  end $$;

  \echo '-- B2. re-inserting the SAME dept+programme+code must be REJECTED'
  do $$
  begin
    begin
      insert into public.courses (code, title, department_id, programme_id)
      select 'GNS101', 'duplicate', d.id, p.id
      from public.departments d
      join public.programmes p on p.department_id = d.id and p.code = 'CHEW'
      where d.code = 'CHS';
      raise exception 'FAIL: duplicate dept+programme+code was accepted';
    exception when unique_violation then
      raise notice 'PASS: duplicate dept+programme+code correctly rejected';
    end;
  end $$;

rollback;

\echo ''
\echo '=== C. POST-ROLLBACK STATE (expect 0 rows — nothing persisted) ==='
select (select count(*) from public.courses)          as courses,
       (select count(*) from public.programmes)       as programmes,
       (select count(*) from public.departments)      as departments;

\echo 'Verification complete.'
