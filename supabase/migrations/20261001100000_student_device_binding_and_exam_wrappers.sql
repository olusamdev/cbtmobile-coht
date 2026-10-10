-- ============================================================
-- One active device per student, and guarded student exam calls
-- ============================================================
-- Every browser sends a stable random id in the x-device-id header. A student's
-- registration number can be bound to one device at a time. A binding counts as
-- active for 3 minutes after the device was last seen; after that another
-- device may take over, and a SuperAdmin can release it at any time.

create table if not exists public.student_devices (
  student_id uuid primary key references public.students(id) on delete cascade,
  device_id text not null,
  device_label text,
  bound_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

alter table public.student_devices enable row level security;
revoke all on public.student_devices from anon, authenticated;

create or replace function public.assert_student_device()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student_id uuid;
  v_headers text;
  v_device text;
  r public.student_devices%rowtype;
  c_window constant interval := interval '3 minutes';
begin
  select student_id into v_student_id
  from public.profiles where id = auth.uid() and role = 'student' and is_active = true;
  if v_student_id is null then return; end if;

  v_headers := nullif(current_setting('request.headers', true), '');
  if v_headers is not null then
    v_device := nullif(trim(coalesce((v_headers::json)->>'x-device-id', '')), '');
  end if;
  if v_device is null then
    raise exception 'Device identification is missing. Refresh the page and try again.';
  end if;
  v_device := left(v_device, 100);

  select * into r from public.student_devices where student_id = v_student_id for update;

  if not found then
    insert into public.student_devices(student_id, device_id) values (v_student_id, v_device);
    return;
  end if;

  if r.device_id = v_device then
    update public.student_devices set last_seen_at = now() where student_id = v_student_id;
    return;
  end if;

  if r.last_seen_at < now() - c_window then
    update public.student_devices
    set device_id = v_device, device_label = null, bound_at = now(), last_seen_at = now()
    where student_id = v_student_id;
    return;
  end if;

  raise exception 'This account is active on another device. Close it there, or ask the SuperAdmin to release it.';
end;
$$;

revoke all on function public.assert_student_device() from public, anon, authenticated;

-- Called after sign-in and on a timer while the student is signed in.
create or replace function public.student_device_ping(p_label text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_student_id uuid;
begin
  perform public.assert_student_device();
  select student_id into v_student_id from public.profiles where id = auth.uid() and role = 'student';
  if v_student_id is not null and p_label is not null then
    update public.student_devices set device_label = left(p_label, 120) where student_id = v_student_id;
  end if;
end;
$$;

-- Called on sign-out so the next sign-in elsewhere is not blocked.
create or replace function public.release_student_device()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_student_id uuid; v_headers text; v_device text;
begin
  select student_id into v_student_id from public.profiles where id = auth.uid() and role = 'student';
  if v_student_id is null then return; end if;
  v_headers := nullif(current_setting('request.headers', true), '');
  if v_headers is not null then v_device := nullif(trim(coalesce((v_headers::json)->>'x-device-id', '')), ''); end if;
  delete from public.student_devices where student_id = v_student_id and device_id = v_device;
end;
$$;

revoke all on function public.student_device_ping(text) from public, anon;
revoke all on function public.release_student_device() from public, anon;
grant execute on function public.student_device_ping(text) to authenticated;
grant execute on function public.release_student_device() to authenticated;

-- ------------------------------------------------------------
-- Student exam calls go through guarded wrappers
-- ------------------------------------------------------------

create or replace function public.start_exam_paper_for_student(p_exam_id uuid, p_exam_course_id uuid)
returns table(
  exam_session_id uuid, exam_session_course_id uuid, mode text, paper_status text, session_status text,
  started_at timestamptz, paper_expires_at timestamptz, global_expires_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare v_student_id uuid;
begin
  perform public.assert_student_device();

  select student_id into v_student_id
  from public.profiles where id = auth.uid() and role = 'student' and is_active = true;

  if v_student_id is not null
     and coalesce((select (value)::text = 'true' from public.system_settings where key = 'require_student_photo'), true)
     and not exists (select 1 from public.student_photos where student_id = v_student_id) then
    raise exception 'Upload your identifier photo before starting your first paper.';
  end if;

  return query select * from public.start_exam_paper_v2(p_exam_id, p_exam_course_id);
end;
$$;

create or replace function public.get_exam_questions_for_student(p_exam_session_id uuid, p_exam_session_course_id uuid)
returns table(question_id uuid, question_number integer, question_text text, option_id uuid, option_key text, option_text text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.assert_student_device();
  return query select * from public.get_exam_questions_v2(p_exam_session_id, p_exam_session_course_id);
end;
$$;

create or replace function public.save_exam_answer_for_student(
  p_exam_session_id uuid, p_exam_session_course_id uuid, p_question_id uuid, p_selected_option_id uuid
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_student_device();
  return public.save_exam_answer_v2(p_exam_session_id, p_exam_session_course_id, p_question_id, p_selected_option_id);
end;
$$;

create or replace function public.submit_exam_paper_for_student(
  p_exam_session_course_id uuid,
  p_submission_request_id uuid
)
returns table(answered_questions integer, total_questions integer, all_papers_submitted boolean, otp_rotation_required boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare r record;
begin
  perform public.assert_student_device();
  select * into r from public.submit_exam_paper_v2(p_exam_session_course_id, p_submission_request_id);
  return query
  select (r.correct_answers + r.wrong_answers)::integer,
         (r.correct_answers + r.wrong_answers + r.unanswered_questions)::integer,
         r.all_papers_submitted,
         r.otp_rotation_required;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'start_exam_paper_for_student(uuid,uuid)',
    'get_exam_questions_for_student(uuid,uuid)',
    'save_exam_answer_for_student(uuid,uuid,uuid,uuid)',
    'submit_exam_paper_for_student(uuid,uuid)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- The unguarded versions are no longer callable by students.
revoke execute on function public.start_exam_paper_v2(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.get_exam_questions_v2(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.save_exam_answer_v2(uuid, uuid, uuid, uuid) from public, anon, authenticated;

-- A finished sitting frees the device as well as rotating the OTP.
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
  delete from public.student_devices where student_id = new.student_id;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- SuperAdmin identity overrides
-- ------------------------------------------------------------

create or replace function public.superadmin_find_student_identity(p_search text)
returns table(
  student_id uuid, reg_no text, full_name text,
  photo_uploads integer, photo_can_upload boolean, photo_path text,
  device_label text, device_last_seen timestamptz, device_active boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare v_term text := nullif(trim(coalesce(p_search, '')), '');
begin
  perform public.require_superadmin();
  if v_term is null then return; end if;
  return query
  select s.id, s.reg_no, s.full_name,
         coalesce(sp.upload_count, 0),
         (sp.student_id is null or sp.upload_count < 2 + sp.extra_uploads),
         sp.photo_path,
         d.device_label, d.last_seen_at,
         (d.student_id is not null and d.last_seen_at >= now() - interval '3 minutes')
  from public.students s
  left join public.student_photos sp on sp.student_id = s.id
  left join public.student_devices d on d.student_id = s.id
  where s.reg_no ilike '%' || v_term || '%' or s.full_name ilike '%' || v_term || '%'
  order by s.reg_no
  limit 10;
end;
$$;

create or replace function public.superadmin_release_student_device(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_superadmin();
  delete from public.student_devices where student_id = p_student_id;
end;
$$;

revoke all on function public.superadmin_find_student_identity(text) from public, anon;
revoke all on function public.superadmin_release_student_device(uuid) from public, anon;
grant execute on function public.superadmin_find_student_identity(text) to authenticated;
grant execute on function public.superadmin_release_student_device(uuid) to authenticated;
