-- Fix SuperAdmin active-course RPC.
-- Return the actual courses row type to eliminate return-column mismatches.

drop function if exists public.superadmin_list_active_courses();

create function public.superadmin_list_active_courses()
returns setof public.courses
language sql
security definer
stable
set search_path = public
as $function$
  select c.*
  from public.courses as c
  where c.is_active = true
  order by c.code;
$function$;

revoke all on function public.superadmin_list_active_courses() from public;
grant execute on function public.superadmin_list_active_courses() to authenticated;
