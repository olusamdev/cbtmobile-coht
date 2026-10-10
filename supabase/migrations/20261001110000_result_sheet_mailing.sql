-- ============================================================
-- Result sheet mailing
-- ============================================================
-- When an examination is closed (deactivated), one result sheet per paper is
-- queued for that paper's examiner. The send-result-sheets edge function builds
-- the Excel and Word sheets and sends them through a Google Apps Script mailer.

alter table public.exam_courses add column if not exists examiner_email text;

create or replace function public.valid_examiner_emails(p text)
returns boolean
language sql
immutable
as $$
  select p is null or (
    select coalesce(bool_and(trim(e) ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'), false) and count(*) <= 3
    from unnest(string_to_array(p, ',')) e
  )
$$;

alter table public.exam_courses drop constraint if exists exam_courses_examiner_email_check;
alter table public.exam_courses add constraint exam_courses_examiner_email_check
  check (public.valid_examiner_emails(examiner_email));

create or replace function public.superadmin_set_paper_examiner_email(p_exam_course_id uuid, p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_clean text;
begin
  perform public.require_superadmin();
  v_clean := nullif(trim(coalesce(p_email, '')), '');
  if v_clean is not null then
    select string_agg(lower(trim(e)), ', ') into v_clean from unnest(string_to_array(v_clean, ',')) e where trim(e) <> '';
    if not public.valid_examiner_emails(v_clean) then
      raise exception 'Enter valid email address(es), separated by commas (maximum 3).';
    end if;
  end if;
  update public.exam_courses set examiner_email = v_clean where id = p_exam_course_id;
  if not found then raise exception 'Paper not found.'; end if;
end;
$$;

create table if not exists public.result_mail_queue (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  exam_course_id uuid not null references public.exam_courses(id) on delete cascade,
  recipients text not null,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed')),
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz
);

alter table public.result_mail_queue enable row level security;
revoke all on public.result_mail_queue from anon, authenticated;

create or replace function public.queue_result_mail_for_exam(p_exam_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  with ins as (
    insert into public.result_mail_queue(exam_id, exam_course_id, recipients)
    select p_exam_id, ec.id, ec.examiner_email
    from public.exam_courses ec
    where ec.exam_id = p_exam_id and ec.examiner_email is not null
      and not exists (
        select 1 from public.result_mail_queue q
        where q.exam_course_id = ec.id and q.status in ('pending', 'sending')
      )
    returning 1
  )
  select count(*) into n from ins;
  return n;
end;
$$;

revoke all on function public.queue_result_mail_for_exam(uuid) from public, anon, authenticated;

create or replace function public.trg_queue_result_mail_on_close()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.queue_result_mail_for_exam(new.id);
  return new;
end;
$$;

drop trigger if exists queue_result_mail_on_close on public.exams;
create trigger queue_result_mail_on_close
after update of is_active on public.exams
for each row
when (old.is_active = true and new.is_active = false)
execute function public.trg_queue_result_mail_on_close();

-- ------------------------------------------------------------
-- SuperAdmin
-- ------------------------------------------------------------

create or replace function public.superadmin_queue_result_mail(p_exam_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_superadmin();
  if not exists (select 1 from public.exams where id = p_exam_id) then raise exception 'Examination not found.'; end if;
  return public.queue_result_mail_for_exam(p_exam_id);
end;
$$;

create or replace function public.superadmin_list_result_mail_queue(p_limit integer default 30)
returns table(
  id uuid, exam_id uuid, exam_title text, course_code text, course_title text,
  recipients text, status text, attempts integer, last_error text, created_at timestamptz, sent_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.require_superadmin();
  return query
  select q.id, q.exam_id, e.title, c.code, c.title, q.recipients, q.status, q.attempts, q.last_error, q.created_at, q.sent_at
  from public.result_mail_queue q
  join public.exams e on e.id = q.exam_id
  join public.exam_courses ec on ec.id = q.exam_course_id
  join public.courses c on c.id = ec.course_id
  order by q.created_at desc
  limit greatest(1, least(coalesce(p_limit, 30), 200));
end;
$$;

create or replace function public.superadmin_requeue_result_mail(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_superadmin();
  update public.result_mail_queue set status = 'pending', last_error = null where id = p_id and status = 'failed';
  if not found then raise exception 'Only failed deliveries can be retried.'; end if;
end;
$$;

revoke all on function public.superadmin_set_paper_examiner_email(uuid, text) from public, anon;
revoke all on function public.superadmin_queue_result_mail(uuid) from public, anon;
revoke all on function public.superadmin_list_result_mail_queue(integer) from public, anon;
revoke all on function public.superadmin_requeue_result_mail(uuid) from public, anon;
grant execute on function public.superadmin_set_paper_examiner_email(uuid, text) to authenticated;
grant execute on function public.superadmin_queue_result_mail(uuid) to authenticated;
grant execute on function public.superadmin_list_result_mail_queue(integer) to authenticated;
grant execute on function public.superadmin_requeue_result_mail(uuid) to authenticated;

-- ------------------------------------------------------------
-- Edge function (service role)
-- ------------------------------------------------------------

create or replace function public.claim_result_mail_jobs(p_exam_id uuid default null, p_limit integer default 20)
returns table(
  id uuid, exam_id uuid, exam_course_id uuid, recipients text,
  exam_title text, course_code text, course_title text, session_name text
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  with picked as (
    select q.id
    from public.result_mail_queue q
    where (q.status = 'pending' or (q.status = 'sending' and q.claimed_at < now() - interval '10 minutes'))
      and (p_exam_id is null or q.exam_id = p_exam_id)
    order by q.created_at
    limit greatest(1, least(coalesce(p_limit, 20), 50))
    for update skip locked
  ),
  upd as (
    update public.result_mail_queue q
    set status = 'sending', attempts = q.attempts + 1, claimed_at = now()
    from picked where q.id = picked.id
    returning q.id, q.exam_id, q.exam_course_id, q.recipients
  )
  select u.id, u.exam_id, u.exam_course_id, u.recipients, e.title, c.code, c.title, s.name
  from upd u
  join public.exams e on e.id = u.exam_id
  join public.exam_courses ec on ec.id = u.exam_course_id
  join public.courses c on c.id = ec.course_id
  left join public.academic_sessions s on s.id = e.academic_session_id;
end;
$$;

create or replace function public.complete_result_mail(p_id uuid, p_ok boolean, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.result_mail_queue
  set status = case when p_ok then 'sent' else 'failed' end,
      last_error = case when p_ok then null else left(coalesce(p_error, 'Delivery failed'), 500) end,
      sent_at = case when p_ok then now() else null end
  where id = p_id;
end;
$$;

create or replace function public.result_sheet_rows(p_exam_course_id uuid)
returns table(
  reg_no text, full_name text, programme_name text, level integer, result_status text,
  answered integer, correct integer, wrong integer, unanswered integer, total integer,
  percentage numeric, submitted_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
  select s.reg_no, s.full_name, p.name, s.level,
         case when r.id is null then 'Absent' else 'Submitted' end,
         r.answered_questions, r.correct_answers, r.wrong_answers, r.unanswered_questions, r.total_questions,
         r.percentage, r.scored_at
  from public.exam_courses ec
  join public.exams e on e.id = ec.exam_id
  join public.student_course_registrations scr
    on scr.course_id = ec.course_id and scr.academic_session_id = e.academic_session_id and scr.is_active = true
  join public.students s on s.id = scr.student_id
  left join public.programmes p on p.id = s.programme_id
  left join lateral (
    select r2.*
    from public.exam_results r2
    join public.exam_session_courses esc on esc.id = r2.exam_session_course_id
    where r2.student_id = s.id and esc.exam_course_id = ec.id and r2.voided_at is null
    order by r2.scored_at desc
    limit 1
  ) r on true
  where ec.id = p_exam_course_id
  order by s.reg_no;
end;
$$;

revoke all on function public.claim_result_mail_jobs(uuid, integer) from public, anon, authenticated;
revoke all on function public.complete_result_mail(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.result_sheet_rows(uuid) from public, anon, authenticated;
grant execute on function public.claim_result_mail_jobs(uuid, integer) to service_role;
grant execute on function public.complete_result_mail(uuid, boolean, text) to service_role;
grant execute on function public.result_sheet_rows(uuid) to service_role;
