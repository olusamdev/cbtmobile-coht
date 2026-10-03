-- ============================================================
-- MIGRATION 12: SECURE QUESTION DELIVERY
-- ============================================================
-- Students must never query question_options directly because that table
-- contains is_correct. This RPC validates the authenticated student's
-- ownership of the exam session and returns only safe question/option fields.
-- ============================================================

create or replace function public.get_exam_questions(
    p_exam_session_id uuid
)
returns table (
    question_id uuid,
    question_number integer,
    question_text text,
    option_id uuid,
    option_key text,
    option_text text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_student_id uuid;
    v_exam_id uuid;
begin
    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    v_student_id := public.current_student_id();
    if v_student_id is null then
        raise exception 'Authenticated user is not an active student';
    end if;

    select es.exam_id
      into v_exam_id
      from public.exam_sessions es
     where es.id = p_exam_session_id
       and es.student_id = v_student_id;

    if not found then
        raise exception 'Exam session does not exist or does not belong to this student';
    end if;

    return query
    select
        q.id,
        q.question_number,
        q.question_text,
        qo.id,
        qo.option_key,
        qo.option_text
    from public.questions q
    join public.question_options qo
      on qo.question_id = q.id
    where q.exam_id = v_exam_id
    order by q.question_number, qo.option_key;
end;
$$;

comment on function public.get_exam_questions(uuid) is
    'Secure student question delivery. Returns question/options without exposing question_options.is_correct.';

revoke all on function public.get_exam_questions(uuid) from public;
grant execute on function public.get_exam_questions(uuid) to authenticated;
