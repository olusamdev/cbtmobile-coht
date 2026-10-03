-- Programme codes are unique within a department,
-- not globally across the entire college.

alter table public.programmes
  drop constraint if exists programmes_code_unique;

alter table public.programmes
  add constraint programmes_department_code_unique
  unique (department_id, code);