-- ============================================================
-- Server-side strike recording, OTP rotation on submission,
-- RLS for reference tables, and non-enumerating matric mapping.
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- 1. STRIKES: authoritative write path for the student client
-- ------------------------------------------------------------
-- The client detects focus-loss events; the server decides the strike
-- number and pauses the session at the third uncleared strike.

create or replace function public.record_security_event(
  p_exam_session_id uuid,
  p_event_type text,
  p_reason text default null
)
returns table(strike_count integer, session_status text, paused boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_session public.exam_sessions%rowtype;
  v_count integer;
  v_last timestamptz;
  v_now timestamptz := now();
  v_type text;
  v_reason text;
  c_max_strikes constant integer := 3;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select student_id into v_student_id
  from public.profiles
  where id = auth.uid() and role = 'student' and is_active = true;

  if v_student_id is null then
    raise exception 'Student authorization required';
  end if;

  select * into v_session
  from public.exam_sessions
  where id = p_exam_session_id and student_id = v_student_id
  for update;

  if not found then
    raise exception 'Exam session does not exist';
  end if;

  select count(*), max(issued_at) into v_count, v_last
  from public.strikes
  where exam_session_id = p_exam_session_id and cleared_at is null;

  -- Paused or finished sessions accept no further strikes.
  if v_session.status <> 'active' then
    return query select v_count, v_session.status, v_session.status = 'paused';
    return;
  end if;

  -- Debounce: one physical action can raise blur + visibility together.
  if v_last is not null and v_now - v_last < interval '2 seconds' then
    return query select v_count, v_session.status, false;
    return;
  end if;

  v_type := left(coalesce(nullif(trim(p_event_type), ''), 'unknown'), 40);
  v_reason := left(coalesce(nullif(trim(p_reason), ''), v_type), 300);
  v_count := v_count + 1;

  insert into public.strikes(exam_session_id, strike_number, reason, issued_at, issued_by)
  values (p_exam_session_id, v_count, v_reason, v_now, auth.uid());

  insert into public.exam_session_events(exam_session_id, event_type, event_data, performed_by)
  values (
    p_exam_session_id,
    'STRIKE_ISSUED',
    jsonb_build_object('strike', v_count, 'type', v_type, 'reason', v_reason),
    auth.uid()
  );

  if v_count >= c_max_strikes then
    update public.exam_sessions
    set status = 'paused', paused_at = v_now, updated_at = v_now
    where id = p_exam_session_id;

    insert into public.exam_session_events(exam_session_id, event_type, event_data, performed_by)
    values (
      p_exam_session_id,
      'SESSION_PAUSED',
      jsonb_build_object('reason', 'Automatic pause: ' || c_max_strikes || ' strikes', 'strike', v_count, 'paused_at', v_now),
      auth.uid()
    );

    if not exists (
      select 1 from public.supervisor_alerts
      where exam_session_id = p_exam_session_id and status = 'open'
    ) then
      insert into public.supervisor_alerts(exam_session_id, message)
      values (p_exam_session_id, 'Automatic pause after ' || c_max_strikes || ' strikes');
    end if;

    return query select v_count, 'paused'::text, true;
    return;
  end if;

  return query select v_count, 'active'::text, false;
end;
$$;

-- Lets the exam page restore the strike count after a refresh.
create or replace function public.get_exam_strikes(p_exam_session_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_count integer;
begin
  select student_id into v_student_id
  from public.profiles
  where id = auth.uid() and role = 'student' and is_active = true;

  if v_student_id is null then
    raise exception 'Student authorization required';
  end if;

  if not exists (
    select 1 from public.exam_sessions
    where id = p_exam_session_id and student_id = v_student_id
  ) then
    raise exception 'Exam session does not exist';
  end if;

  select count(*) into v_count
  from public.strikes
  where exam_session_id = p_exam_session_id and cleared_at is null;

  return v_count;
end;
$$;

revoke all on function public.record_security_event(uuid, text, text) from public, anon;
revoke all on function public.get_exam_strikes(uuid) from public, anon;
grant execute on function public.record_security_event(uuid, text, text) to authenticated;
grant execute on function public.get_exam_strikes(uuid) to authenticated;

-- ------------------------------------------------------------
-- 2. OTP ROTATION when an examination session is submitted
-- ------------------------------------------------------------
-- The OTP is the student's Auth password. Rotating it here, inside the
-- same transaction as the submission, means it cannot be skipped by
-- closing the browser. Rotation failure never blocks a submission; it is
-- logged as an audit event instead.

create or replace function public.rotate_student_otp(p_student_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_otp text := '';
  v_uid uuid;
  i integer;
begin
  select id into v_uid
  from public.profiles
  where student_id = p_student_id and role = 'student';

  if v_uid is null then
    raise exception 'Student auth account not found';
  end if;

  v_bytes := gen_random_bytes(6);
  for i in 0..5 loop
    v_otp := v_otp || substr(c_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
  end loop;

  update auth.users
  set encrypted_password = crypt(v_otp, gen_salt('bf', 10)),
      updated_at = now()
  where id = v_uid;

  insert into public.student_exam_otps(student_id, current_otp, otp_epoch, valid_for_date, issued_at, updated_at)
  values (p_student_id, v_otp, 1, current_date, now(), now())
  on conflict (student_id) do update
  set current_otp = excluded.current_otp,
      otp_epoch = public.student_exam_otps.otp_epoch + 1,
      valid_for_date = excluded.valid_for_date,
      issued_at = excluded.issued_at,
      updated_at = excluded.updated_at;

  return v_otp;
end;
$$;

revoke all on function public.rotate_student_otp(uuid) from public, anon, authenticated;
grant execute on function public.rotate_student_otp(uuid) to service_role;

create or replace function public.trg_rotate_otp_on_session_submitted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.rotate_student_otp(new.student_id);
    insert into public.exam_session_events(exam_session_id, event_type, event_data)
    values (new.id, 'OTP_ROTATED', '{}'::jsonb);
  exception when others then
    insert into public.exam_session_events(exam_session_id, event_type, event_data)
    values (new.id, 'OTP_ROTATION_FAILED', jsonb_build_object('error', sqlerrm));
  end;
  return new;
end;
$$;

drop trigger if exists rotate_otp_on_session_submitted on public.exam_sessions;
create trigger rotate_otp_on_session_submitted
after update of status on public.exam_sessions
for each row
when (new.status = 'submitted' and old.status is distinct from 'submitted')
execute function public.trg_rotate_otp_on_session_submitted();

-- ------------------------------------------------------------
-- 3. RLS on reference tables that had none
-- ------------------------------------------------------------
-- Writes go through SECURITY DEFINER RPCs; signed-in users may read the
-- reference data the app embeds in queries. student_exam_day_sessions is
-- internal and gets no policy at all.

alter table public.departments enable row level security;
alter table public.programmes enable row level security;
alter table public.courses enable row level security;
alter table public.academic_sessions enable row level security;
alter table public.student_exam_day_sessions enable row level security;

drop policy if exists departments_authenticated_select on public.departments;
create policy departments_authenticated_select on public.departments
  for select to authenticated using (true);

drop policy if exists programmes_authenticated_select on public.programmes;
create policy programmes_authenticated_select on public.programmes
  for select to authenticated using (true);

drop policy if exists courses_authenticated_select on public.courses;
create policy courses_authenticated_select on public.courses
  for select to authenticated using (true);

drop policy if exists academic_sessions_authenticated_select on public.academic_sessions;
create policy academic_sessions_authenticated_select on public.academic_sessions
  for select to authenticated using (true);

revoke all on public.departments, public.programmes, public.courses,
  public.academic_sessions, public.student_exam_day_sessions from anon;
revoke insert, update, delete, truncate on public.departments, public.programmes,
  public.courses, public.academic_sessions from authenticated;
revoke all on public.student_exam_day_sessions from authenticated;

-- ------------------------------------------------------------
-- 4. Matric mapping no longer reveals which matric numbers exist
-- ------------------------------------------------------------
-- Unknown or inactive students now fail at sign-in with the same generic
-- credentials error as a wrong OTP.

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

  return v_reg_no || '@student.coht.local';
end;
$$;

revoke all on function public.student_auth_email(text) from public;
grant execute on function public.student_auth_email(text) to anon, authenticated;
