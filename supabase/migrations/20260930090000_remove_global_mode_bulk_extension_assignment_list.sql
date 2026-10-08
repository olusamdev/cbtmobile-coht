-- ============================================================
-- 1. Remove the global "examination mode" setting
-- ============================================================
-- Mode belongs to each examination (exams.mode). Nothing in the exam engine
-- reads system_settings.exam_mode, so the setting only ever stored a value.

drop function if exists public.superadmin_set_exam_mode(text);
delete from public.system_settings where key = 'exam_mode';

-- ============================================================
-- 2. Assignment list shows active assignments only
-- ============================================================
-- Unassigning is a soft delete (is_active = false). The previous list returned
-- inactive rows too, so an unassigned paper never disappeared from the screen.

create or replace function public.superadmin_list_admin_paper_assignments()
returns table(assignment_id uuid, admin_id uuid, admin_name text, admin_email text, exam_course_id uuid, exam_id uuid, exam_title text, course_code text, course_title text, is_active boolean, assigned_at timestamptz)
language plpgsql security definer stable set search_path=public
as $$
begin
 if public.current_user_role()<>'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
 return query
 select apa.id,p.id,coalesce(p.display_name,''),coalesce(u.email,''),ec.id,e.id,e.title,c.code,c.title,apa.is_active,apa.assigned_at
 from public.admin_paper_assignments apa
 join public.profiles p on p.id=apa.admin_id
 join auth.users u on u.id=p.id
 join public.exam_courses ec on ec.id=apa.exam_course_id
 join public.exams e on e.id=ec.exam_id
 join public.courses c on c.id=ec.course_id
 where p.role='admin' and apa.is_active
 order by p.display_name,e.title,c.code;
end; $$;

revoke all on function public.superadmin_list_admin_paper_assignments() from public;
grant execute on function public.superadmin_list_admin_paper_assignments() to authenticated;

-- ============================================================
-- 2b. Per-attempt time extension was failing on every call
-- ============================================================
-- The function declares OUT columns (exam_session_id, total_extension_seconds,
-- updated_at) and also uses the same names unqualified in its queries, which
-- PL/pgSQL rejects as ambiguous. The directive resolves such names to columns;
-- the body is otherwise unchanged apart from casting the bigint column to the
-- declared integer result, which made the function fail even without the clash.

create or replace function public.admin_extend_exam_time(
    p_exam_session_id uuid,
    p_extension_seconds integer,
    p_reason text default null
)
returns table (
    exam_session_id uuid,
    total_extension_seconds integer,
    updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
    v_role text;
    v_session public.exam_sessions%rowtype;
    v_now timestamptz;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    v_role := public.current_user_role();

    if v_role not in ('admin', 'superadmin') then
        raise exception 'Administrative authorization required';
    end if;


    if p_extension_seconds <= 0 then
        raise exception 'Extension must be greater than zero seconds';
    end if;


    select *
    into v_session
    from public.exam_sessions
    where id = p_exam_session_id
    for update;

    if not found then
        raise exception 'Exam session does not exist';
    end if;


    if v_session.status not in ('active', 'paused') then
        raise exception
            'Time can only be extended for an active or paused examination';
    end if;


    v_now := now();


    update public.exam_sessions
    set
        total_extension_seconds =
            coalesce(total_extension_seconds, 0)
            + p_extension_seconds,
        updated_at = v_now
    where id = p_exam_session_id
    returning *
    into v_session;


    insert into public.exam_session_events (
        exam_session_id,
        event_type,
        event_data,
        performed_by
    )
    values (
        p_exam_session_id,
        'TIME_EXTENDED',
        jsonb_build_object(
            'extension_seconds', p_extension_seconds,
            'reason', p_reason,
            'updated_at', v_now
        ),
        auth.uid()
    );


    return query
    select
        v_session.id,
        v_session.total_extension_seconds::integer,
        v_now;

end;
$$;

-- ============================================================
-- 3. Bulk time extension for an examination (or one paper of it)
-- ============================================================
-- Applies the existing per-attempt extension (admin_extend_exam_time) to every
-- active or paused sitting, so the extension accounting stays in one place.

create or replace function public.superadmin_extend_exam_time_bulk(
  p_exam_id uuid,
  p_exam_course_id uuid,
  p_extension_minutes integer,
  p_reason text
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
begin
  perform public.require_superadmin();

  if p_extension_minutes is null or p_extension_minutes < 1 or p_extension_minutes > 240 then
    raise exception 'Extension must be between 1 and 240 minutes.';
  end if;
  if not exists (select 1 from public.exams where id = p_exam_id) then
    raise exception 'Examination not found.';
  end if;
  if p_exam_course_id is not null and not exists (
    select 1 from public.exam_courses where id = p_exam_course_id and exam_id = p_exam_id
  ) then
    raise exception 'That paper does not belong to this examination.';
  end if;

  for r in
    select es.id
    from public.exam_sessions es
    where es.exam_id = p_exam_id
      and es.status in ('active', 'paused')
      and (
        p_exam_course_id is null
        or exists (
          select 1 from public.exam_session_courses esc
          where esc.exam_session_id = es.id
            and esc.exam_course_id = p_exam_course_id
            and esc.status in ('active', 'paused', 'available')
        )
      )
  loop
    perform public.admin_extend_exam_time(
      r.id, p_extension_minutes * 60,
      coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Bulk time extension')
    );
    n := n + 1;
  end loop;

  return n;
end;
$$;

revoke all on function public.superadmin_extend_exam_time_bulk(uuid, uuid, integer, text) from public, anon;
grant execute on function public.superadmin_extend_exam_time_bulk(uuid, uuid, integer, text) to authenticated;

-- ============================================================
-- 4. Admin operations that failed at run time
-- ============================================================
-- Found by calling every admin/supervision function the app uses:
--   resume_exam_session / supervision_get_audit_trail: output column names clash
--   with table columns (ambiguous reference); resolved with the directive.
--   admin_get_exam_session_state: selected two columns that do not exist on
--   exam_session_courses, so Force submit could never look up the paper. It now
--   returns NULL for those two (unused) fields and lists the active paper first.
-- Bodies are otherwise unchanged except for casting bigint seconds columns to the
-- integer result types the functions declare.

CREATE OR REPLACE FUNCTION public.resume_exam_session(p_exam_session_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS TABLE(exam_session_id uuid, session_status text, total_paused_seconds integer, resumed_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
    v_role text;
    v_session public.exam_sessions%rowtype;
    v_now timestamptz;
    v_pause_seconds integer;
begin

    -- --------------------------------------------------------
    -- AUTHENTICATION
    -- --------------------------------------------------------

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;


    -- --------------------------------------------------------
    -- AUTHORIZATION
    -- --------------------------------------------------------

    v_role := public.current_user_role();

    if v_role not in ('admin', 'superadmin') then
        raise exception 'Administrative authorization required';
    end if;


    -- --------------------------------------------------------
    -- LOCK SESSION
    -- --------------------------------------------------------

    select *
    into v_session
    from public.exam_sessions
    where id = p_exam_session_id
    for update;


    if not found then
        raise exception 'Exam session does not exist';
    end if;


    -- --------------------------------------------------------
    -- VALIDATE STATE
    -- --------------------------------------------------------

    if v_session.status <> 'paused' then
        raise exception
            'Only a paused examination session can be resumed';
    end if;


    if v_session.paused_at is null then
        raise exception
            'Paused session has no pause timestamp';
    end if;


    -- --------------------------------------------------------
    -- AUTHORITATIVE TIME
    -- --------------------------------------------------------

    v_now := now();


    v_pause_seconds :=
        greatest(
            0,
            floor(
                extract(
                    epoch from (v_now - v_session.paused_at)
                )
            )::integer
        );


    -- --------------------------------------------------------
    -- RESUME
    -- --------------------------------------------------------

    update public.exam_sessions
    set
        status = 'active',
        paused_at = null,
        total_paused_seconds =
            coalesce(total_paused_seconds, 0)
            + v_pause_seconds,
        updated_at = v_now
    where id = p_exam_session_id
    returning *
    into v_session;


    -- --------------------------------------------------------
    -- AUDIT EVENT
    -- --------------------------------------------------------

    insert into public.exam_session_events (
        exam_session_id,
        event_type,
        event_data,
        performed_by
    )
    values (
        p_exam_session_id,
        'SESSION_RESUMED',
        jsonb_build_object(
            'reason', p_reason,
            'resumed_at', v_now,
            'pause_duration_seconds', v_pause_seconds
        ),
        auth.uid()
    );


    -- --------------------------------------------------------
    -- RETURN
    -- --------------------------------------------------------

    return query
    select
        v_session.id,
        v_session.status,
        v_session.total_paused_seconds::integer,
        v_now;

end;
$function$;

CREATE OR REPLACE FUNCTION public.supervision_get_audit_trail(p_exam_session_id uuid)
 RETURNS TABLE(id uuid, event_type text, event_data jsonb, performed_by uuid, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
begin
    if public.current_user_role() not in ('admin','superadmin') then raise exception 'Administrative authorization required'; end if;
    if public.current_user_role()='admin' and not exists(select 1 from exam_session_courses esc join admin_paper_assignments apa on apa.exam_course_id=esc.exam_course_id where esc.exam_session_id=p_exam_session_id and apa.admin_id=auth.uid() and apa.is_active) then raise exception 'Attempt is outside your assignment'; end if;
    return query select id,event_type,event_data,performed_by,created_at from exam_session_events where exam_session_id=p_exam_session_id order by created_at;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_get_exam_session_state(p_exam_session_id uuid)
 RETURNS TABLE(exam_session_id uuid, exam_id uuid, student_id uuid, session_status text, started_at timestamp with time zone, paused_at timestamp with time zone, total_paused_seconds integer, total_extension_seconds integer, current_question_id uuid, exam_session_course_id uuid, paper_status text, submission_request_id uuid, submission_started_at timestamp with time zone, submitted_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
    v_role text;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    v_role := public.current_user_role();

    if v_role not in ('admin', 'superadmin') then
        raise exception 'Administrative authorization required';
    end if;


    return query
    select
        es.id,
        es.exam_id,
        es.student_id,
        es.status,
        es.started_at,
        es.paused_at,
        coalesce(es.total_paused_seconds, 0)::integer,
        coalesce(es.total_extension_seconds, 0)::integer,
        es.current_question_id,
        esc.id,
        esc.status,
        null::uuid,
        null::timestamp with time zone,
        esc.submitted_at
    from public.exam_sessions es
    left join public.exam_session_courses esc
        on esc.exam_session_id = es.id
    where es.id = p_exam_session_id
    order by (esc.status = 'active') desc nulls last, esc.created_at;

    if not found then
        raise exception 'Exam session does not exist';
    end if;

end;
$function$;
