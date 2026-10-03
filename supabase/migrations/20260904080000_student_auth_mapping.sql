-- ============================================================
-- MIGRATION 13: STUDENT AUTHENTICATION MAPPING
-- Matric-number login is mapped server-side to a synthetic
-- Supabase Auth email. Passwords remain entirely inside Auth.
-- ============================================================

create or replace function public.student_auth_email(p_reg_no text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_reg_no text;
begin
    v_reg_no := lower(trim(p_reg_no));

    if v_reg_no = '' then
        raise exception 'Matriculation number is required';
    end if;

    if not exists (
        select 1 from public.students
        where lower(reg_no) = v_reg_no and is_active = true
    ) then
        raise exception 'Student record not found or inactive';
    end if;

    return v_reg_no || '@student.coht.local';
end;
$$;

revoke all on function public.student_auth_email(text) from public;
grant execute on function public.student_auth_email(text) to anon, authenticated;
