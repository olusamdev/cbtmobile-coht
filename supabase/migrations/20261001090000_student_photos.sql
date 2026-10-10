-- ============================================================
-- Student identifier photo
-- ============================================================
-- A student uploads a photo before their first paper and may change it once.
-- Any further change needs a SuperAdmin to allow another upload. Photos are
-- written only by the upload-student-photo edge function (service role), so
-- the limit cannot be bypassed from the browser.

insert into storage.buckets (id, name, public)
values ('student-photos', 'student-photos', false)
on conflict (id) do nothing;

drop policy if exists student_photos_read on storage.objects;
create policy student_photos_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'student-photos'
    and (
      public.current_user_role() in ('admin', 'superadmin')
      or (storage.foldername(name))[1] = (select p.student_id::text from public.profiles p where p.id = auth.uid())
    )
  );

create table if not exists public.student_photos (
  student_id uuid primary key references public.students(id) on delete cascade,
  photo_path text not null,
  gender text check (gender in ('male', 'female')),
  upload_count integer not null default 1 check (upload_count >= 1),
  extra_uploads integer not null default 0 check (extra_uploads >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.photo_change_requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  reason text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid
);

create unique index if not exists photo_change_requests_one_pending
  on public.photo_change_requests(student_id) where status = 'pending';

alter table public.student_photos enable row level security;
alter table public.photo_change_requests enable row level security;
revoke all on public.student_photos, public.photo_change_requests from anon, authenticated;

-- ------------------------------------------------------------
-- Edge function (service role) helpers
-- ------------------------------------------------------------
-- Self-service allows 2 uploads: the first photo and one change.

create or replace function public.student_photo_next_index(p_student_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare r public.student_photos%rowtype;
begin
  select * into r from public.student_photos where student_id = p_student_id;
  if not found then return 1; end if;
  if r.upload_count >= 2 + r.extra_uploads then
    raise exception 'Photo changes are locked. Ask the SuperAdmin to allow another upload.';
  end if;
  return r.upload_count + 1;
end;
$$;

create or replace function public.record_student_photo(p_student_id uuid, p_path text, p_gender text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.student_photos%rowtype;
begin
  select * into r from public.student_photos where student_id = p_student_id for update;
  if not found then
    insert into public.student_photos(student_id, photo_path, gender) values (p_student_id, p_path, p_gender);
    return;
  end if;
  if r.upload_count >= 2 + r.extra_uploads then
    raise exception 'Photo changes are locked. Ask the SuperAdmin to allow another upload.';
  end if;
  update public.student_photos
  set photo_path = p_path, gender = coalesce(p_gender, gender), upload_count = upload_count + 1, updated_at = now()
  where student_id = p_student_id;
end;
$$;

revoke all on function public.student_photo_next_index(uuid) from public, anon, authenticated;
revoke all on function public.record_student_photo(uuid, text, text) from public, anon, authenticated;
grant execute on function public.student_photo_next_index(uuid) to service_role;
grant execute on function public.record_student_photo(uuid, text, text) to service_role;

-- ------------------------------------------------------------
-- Student-facing
-- ------------------------------------------------------------

create or replace function public.get_my_photo_status()
returns table(photo_path text, gender text, upload_count integer, can_upload boolean, request_pending boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare v_student_id uuid; r public.student_photos%rowtype;
begin
  select student_id into v_student_id from public.profiles where id = auth.uid() and role = 'student' and is_active = true;
  if v_student_id is null then raise exception 'Student authorization required'; end if;
  select * into r from public.student_photos where student_id = v_student_id;
  return query select
    r.photo_path, r.gender, coalesce(r.upload_count, 0),
    (r.student_id is null or r.upload_count < 2 + r.extra_uploads),
    exists (select 1 from public.photo_change_requests q where q.student_id = v_student_id and q.status = 'pending');
end;
$$;

create or replace function public.request_photo_change_clearance(p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_student_id uuid; r public.student_photos%rowtype;
begin
  select student_id into v_student_id from public.profiles where id = auth.uid() and role = 'student' and is_active = true;
  if v_student_id is null then raise exception 'Student authorization required'; end if;
  select * into r from public.student_photos where student_id = v_student_id;
  if not found then raise exception 'Upload your photo first.'; end if;
  if r.upload_count < 2 + r.extra_uploads then raise exception 'You can still change your photo without clearance.'; end if;
  if exists (select 1 from public.photo_change_requests where student_id = v_student_id and status = 'pending') then
    raise exception 'Your request is already waiting for the SuperAdmin.';
  end if;
  insert into public.photo_change_requests(student_id, reason)
  values (v_student_id, left(coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Student requested a photo change'), 300));
end;
$$;

revoke all on function public.get_my_photo_status() from public, anon;
revoke all on function public.request_photo_change_clearance(text) from public, anon;
grant execute on function public.get_my_photo_status() to authenticated;
grant execute on function public.request_photo_change_clearance(text) to authenticated;

-- ------------------------------------------------------------
-- Staff-facing
-- ------------------------------------------------------------

create or replace function public.get_student_photo_paths(p_student_ids uuid[])
returns table(student_id uuid, photo_path text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if public.current_user_role() not in ('admin', 'superadmin') then
    raise exception 'Administrative authorization required';
  end if;
  return query
  select sp.student_id, sp.photo_path from public.student_photos sp where sp.student_id = any(p_student_ids);
end;
$$;

create or replace function public.superadmin_list_photo_requests()
returns table(request_id uuid, student_id uuid, reg_no text, full_name text, reason text, requested_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_superadmin();
  return query
  select q.id, q.student_id, s.reg_no, s.full_name, q.reason, q.created_at
  from public.photo_change_requests q
  join public.students s on s.id = q.student_id
  where q.status = 'pending'
  order by q.created_at;
end;
$$;

create or replace function public.superadmin_decide_photo_request(p_request_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare q public.photo_change_requests%rowtype;
begin
  perform public.require_superadmin();
  select * into q from public.photo_change_requests where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Request not found or already decided.'; end if;
  if p_approve then
    update public.student_photos set extra_uploads = extra_uploads + 1, updated_at = now() where student_id = q.student_id;
  end if;
  update public.photo_change_requests
  set status = case when p_approve then 'approved' else 'declined' end, decided_at = now(), decided_by = auth.uid()
  where id = q.id;
end;
$$;

create or replace function public.superadmin_grant_photo_change(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_superadmin();
  update public.student_photos set extra_uploads = extra_uploads + 1, updated_at = now() where student_id = p_student_id;
  if not found then raise exception 'This student has not uploaded a photo yet.'; end if;
  update public.photo_change_requests
  set status = 'approved', decided_at = now(), decided_by = auth.uid()
  where student_id = p_student_id and status = 'pending';
end;
$$;

revoke all on function public.get_student_photo_paths(uuid[]) from public, anon;
revoke all on function public.superadmin_list_photo_requests() from public, anon;
revoke all on function public.superadmin_decide_photo_request(uuid, boolean) from public, anon;
revoke all on function public.superadmin_grant_photo_change(uuid) from public, anon;
grant execute on function public.get_student_photo_paths(uuid[]) to authenticated;
grant execute on function public.superadmin_list_photo_requests() to authenticated;
grant execute on function public.superadmin_decide_photo_request(uuid, boolean) to authenticated;
grant execute on function public.superadmin_grant_photo_change(uuid) to authenticated;

-- The photo is required before a first paper unless a SuperAdmin turns the rule off.
insert into public.system_settings(key, value) values ('require_student_photo', 'true'::jsonb)
on conflict (key) do nothing;
