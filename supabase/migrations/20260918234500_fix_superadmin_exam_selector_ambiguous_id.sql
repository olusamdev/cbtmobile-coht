create or replace function public.superadmin_list_exams_for_question_bank()
returns table(
  id uuid,
  title text,
  mode text,
  is_active boolean,
  question_count integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.profiles as p
    where p.id = auth.uid()
      and p.role = 'superadmin'
      and p.is_active = true
  ) then
    raise exception 'SuperAdmin access required';
  end if;

  return query
  select e.id, e.title, e.mode, e.is_active, e.question_count
  from public.exams as e
  order by e.created_at desc;
end;
$$;

revoke all on function public.superadmin_list_exams_for_question_bank() from public;
grant execute on function public.superadmin_list_exams_for_question_bank() to authenticated;
