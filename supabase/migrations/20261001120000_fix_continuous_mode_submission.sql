-- ============================================================
-- Continuous mode: submission failed on every call
-- ============================================================
-- The "is any other registered paper still unsubmitted?" check referenced
-- exam_sessions.exam_course_id, a column that does not exist (papers hang off
-- exam_session_courses). That broke submit_exam_paper_v2 and finalize_exam_papers
-- for Continuous examinations. The check now uses exam_session_courses and
-- only counts registrations in the examination's own academic session.
-- Bodies are otherwise unchanged.

CREATE OR REPLACE FUNCTION public.submit_exam_paper_v2(p_exam_session_course_id uuid, p_submission_request_id uuid)
 RETURNS TABLE(result_id uuid, exam_session_course_id uuid, score numeric, percentage numeric, correct_answers integer, wrong_answers integer, unanswered_questions integer, result_status text, submission_confirmed boolean, mode text, all_papers_submitted boolean, otp_rotation_required boolean, next_exam_session_course_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_student_id uuid;
  v_sc public.exam_session_courses%rowtype;
  v_session public.exam_sessions%rowtype;
  v_exam public.exams%rowtype;
  v_ec record;
  v_total integer;
  v_correct integer;
  v_wrong integer;
  v_unanswered integer;
  v_result public.exam_results%rowtype;
  v_selected_result public.exam_results%rowtype;
  v_now timestamptz := now();
  v_rotate boolean := false;
  v_all boolean := false;
  v_next uuid;
  v_day public.student_exam_day_sessions%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_student_id := public.current_student_id();

  select * into v_sc from public.exam_session_courses where id=p_exam_session_course_id for update;
  if not found then raise exception 'Examination paper session does not exist'; end if;
  select * into v_session from public.exam_sessions where id=v_sc.exam_session_id for update;
  if not found or v_session.student_id<>v_student_id then raise exception 'This examination session does not belong to you'; end if;
  select * into v_exam from public.exams where id=v_session.exam_id;

  if v_sc.status='submitted' then
    select * into v_selected_result from public.exam_results where exam_session_course_id=v_sc.id;
    if not found then raise exception 'Paper is marked submitted but no result exists'; end if;
    return query select v_selected_result.id,v_selected_result.exam_session_course_id,v_selected_result.score,v_selected_result.percentage,
      v_selected_result.correct_answers,v_selected_result.wrong_answers,v_selected_result.unanswered_questions,v_selected_result.status,true,
      v_exam.mode,(not exists(select 1 from public.exam_session_courses where exam_session_id=v_session.id and status<>'submitted')),
      false,null::uuid;
    return;
  end if;

  if v_exam.mode <> 'pharmacy_prenational' and v_sc.status <> 'active' then
    raise exception 'This examination paper cannot currently be submitted';
  end if;

  -- Pharmacy is one atomic sitting: score every paper in the same transaction.
  -- Regular/Continuous score only the requested paper.
  if v_exam.mode='pharmacy_prenational' then
    for v_ec in
      select esc.*
      from public.exam_session_courses esc
      where esc.exam_session_id=v_session.id and esc.status<>'submitted'
      order by esc.created_at
      for update
    loop
      select count(*) into v_total
      from public.questions q
      where q.exam_id=v_session.exam_id
        and (q.exam_course_id=v_ec.exam_course_id
             or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1));
      if v_total=0 then raise exception 'A Pharmacy paper has no questions assigned to it'; end if;

      select count(*) filter(where qo.is_correct=true), count(*) filter(where qo.is_correct=false)
        into v_correct,v_wrong
      from public.questions q
      left join public.answers a on a.question_id=q.id and a.exam_session_id=v_session.id
      left join public.question_options qo on qo.id=a.selected_option_id and qo.question_id=q.id
      where q.exam_id=v_session.exam_id
        and (q.exam_course_id=v_ec.exam_course_id
             or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1))
        and a.selected_option_id is not null;

      v_unanswered := greatest(0,v_total-v_correct-v_wrong);
      insert into public.exam_results(exam_session_id,exam_session_course_id,student_id,exam_id,total_questions,answered_questions,correct_answers,wrong_answers,unanswered_questions,score,percentage,status,scored_at)
      values(v_session.id,v_ec.id,v_student_id,v_session.exam_id,v_total,v_correct+v_wrong,v_correct,v_wrong,v_unanswered,v_correct,round((v_correct::numeric/nullif(v_total,0))*100,2),'final',v_now)
      on conflict(exam_session_course_id) do update set total_questions=excluded.total_questions,answered_questions=excluded.answered_questions,correct_answers=excluded.correct_answers,wrong_answers=excluded.wrong_answers,unanswered_questions=excluded.unanswered_questions,score=excluded.score,percentage=excluded.percentage,status='final',scored_at=v_now
      returning * into v_result;

      update public.exam_session_courses set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_ec.id;
      if v_ec.id=v_sc.id then v_selected_result:=v_result; end if;
    end loop;
    v_all := true;
    v_rotate := true;
    update public.exam_sessions set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_session.id;

  else
    select count(*) into v_total from public.questions q
    where q.exam_id=v_session.exam_id
      and (q.exam_course_id=v_sc.exam_course_id
           or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1));
    if v_total=0 then raise exception 'This examination paper contains no questions'; end if;

    select count(*) filter(where qo.is_correct=true), count(*) filter(where qo.is_correct=false)
      into v_correct,v_wrong
    from public.questions q
    left join public.answers a on a.question_id=q.id and a.exam_session_id=v_session.id
    left join public.question_options qo on qo.id=a.selected_option_id and qo.question_id=q.id
    where q.exam_id=v_session.exam_id
      and (q.exam_course_id=v_sc.exam_course_id
           or (q.exam_course_id is null and (select count(*) from public.exam_courses where exam_id=v_session.exam_id)=1))
      and a.selected_option_id is not null;

    v_unanswered := greatest(0,v_total-v_correct-v_wrong);
    insert into public.exam_results(exam_session_id,exam_session_course_id,student_id,exam_id,total_questions,answered_questions,correct_answers,wrong_answers,unanswered_questions,score,percentage,status,scored_at)
    values(v_session.id,v_sc.id,v_student_id,v_session.exam_id,v_total,v_correct+v_wrong,v_correct,v_wrong,v_unanswered,v_correct,round((v_correct::numeric/nullif(v_total,0))*100,2),'final',v_now)
    on conflict(exam_session_course_id) do update set total_questions=excluded.total_questions,answered_questions=excluded.answered_questions,correct_answers=excluded.correct_answers,wrong_answers=excluded.wrong_answers,unanswered_questions=excluded.unanswered_questions,score=excluded.score,percentage=excluded.percentage,status='final',scored_at=v_now
    returning * into v_selected_result;
    update public.exam_session_courses set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_sc.id;

    if v_exam.mode='regular' then
      v_all := true;
      v_rotate := true;
      update public.exam_sessions set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_session.id;
    else
      select * into v_day from public.student_exam_day_sessions where student_id=v_student_id and exam_date=current_date for update;
      if not exists (
        select 1 from public.exams e
        join public.exam_courses ec on ec.exam_id=e.id
        join public.student_course_registrations scr on scr.course_id=ec.course_id and scr.student_id=v_student_id and scr.academic_session_id = e.academic_session_id
        where e.is_active=true and e.mode='continuous' and scr.is_active=true
          and not exists (
            select 1 from public.exam_session_courses esc2
            join public.exam_sessions es2 on es2.id=esc2.exam_session_id
            where es2.student_id=v_student_id and esc2.exam_course_id = ec.id and esc2.status='submitted'
          )
      ) then
        v_all := true;
        v_rotate := true;
        update public.student_exam_day_sessions set status='ended',otp_rotation_required=true,otp_epoch=otp_epoch+1,updated_at=v_now where id=v_day.id;
        update public.exam_sessions set status='submitted',submitted_at=v_now,updated_at=v_now where id=v_session.id;
        -- the day is over: close this student's other Continuous sittings that have no paper in progress
        update public.exam_sessions es3
        set status = 'submitted', submitted_at = v_now, updated_at = v_now
        from public.exams e3
        where es3.student_id = v_student_id and e3.id = es3.exam_id and e3.mode = 'continuous' and es3.status = 'active'
          and not exists (select 1 from public.exam_session_courses esc3 where esc3.exam_session_id = es3.id and esc3.status in ('active', 'paused', 'submission_pending'));

      else
        v_all := false;
        update public.exam_sessions set status='active',submitted_at=null,updated_at=v_now where id=v_session.id;
        select esc2.id into v_next
        from public.exam_session_courses esc2
        where esc2.exam_session_id=v_session.id and esc2.status<>'submitted'
        order by esc2.created_at limit 1;
      end if;
    end if;
  end if;

  return query select v_selected_result.id,v_selected_result.exam_session_course_id,v_selected_result.score,v_selected_result.percentage,
    v_selected_result.correct_answers,v_selected_result.wrong_answers,v_selected_result.unanswered_questions,v_selected_result.status,true,
    v_exam.mode,v_all,v_rotate,v_next;
end;
$function$;

CREATE OR REPLACE FUNCTION public.finalize_exam_papers(p_exam_session_id uuid, p_exam_session_course_id uuid)
 RETURNS TABLE(result_id uuid, all_submitted boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_session public.exam_sessions%rowtype;
  v_sc public.exam_session_courses%rowtype;
  v_exam public.exams%rowtype;
  v_ec public.exam_session_courses%rowtype;
  v_result public.exam_results%rowtype;
  v_selected public.exam_results%rowtype;
  v_day public.student_exam_day_sessions%rowtype;
  v_all boolean := false;
  v_now timestamptz := now();
begin
  select * into v_session from public.exam_sessions where id = p_exam_session_id for update;
  if not found then raise exception 'Examination session does not exist'; end if;

  select * into v_sc from public.exam_session_courses
  where id = p_exam_session_course_id and exam_session_id = p_exam_session_id for update;
  if not found then raise exception 'Examination paper session does not exist'; end if;

  select * into v_exam from public.exams where id = v_session.exam_id;

  if v_sc.status = 'submitted' then
    select * into v_selected from public.exam_results where exam_session_course_id = v_sc.id;
    if not found then raise exception 'Paper is marked submitted but no result exists'; end if;
    return query select v_selected.id,
      not exists (select 1 from public.exam_session_courses x where x.exam_session_id = v_session.id and x.status <> 'submitted');
    return;
  end if;

  if v_exam.mode <> 'pharmacy_prenational' and v_sc.status not in ('active', 'paused', 'submission_pending') then
    raise exception 'This examination paper cannot be submitted';
  end if;

  if v_exam.mode = 'pharmacy_prenational' then
    for v_ec in
      select * from public.exam_session_courses x
      where x.exam_session_id = v_session.id and x.status <> 'submitted'
      order by x.created_at
      for update
    loop
      v_result := public.score_exam_paper(v_session, v_ec, v_now);
      if v_ec.id = v_sc.id then v_selected := v_result; end if;
    end loop;
    v_all := true;
    update public.exam_sessions set status = 'submitted', submitted_at = v_now, updated_at = v_now where id = v_session.id;

  else
    v_selected := public.score_exam_paper(v_session, v_sc, v_now);

    if v_exam.mode = 'regular' then
      v_all := true;
      update public.exam_sessions set status = 'submitted', submitted_at = v_now, updated_at = v_now where id = v_session.id;
    else
      select * into v_day from public.student_exam_day_sessions
      where student_id = v_session.student_id and exam_date = current_date for update;

      if not exists (
        select 1 from public.exams e
        join public.exam_courses ec on ec.exam_id = e.id
        join public.student_course_registrations scr on scr.course_id = ec.course_id and scr.student_id = v_session.student_id and scr.academic_session_id = e.academic_session_id
        where e.is_active = true and e.mode = 'continuous' and scr.is_active = true
          and not exists (
            select 1 from public.exam_session_courses esc2
            join public.exam_sessions es2 on es2.id = esc2.exam_session_id
            where es2.student_id = v_session.student_id and esc2.exam_course_id = ec.id and esc2.status = 'submitted'
          )
      ) then
        v_all := true;
        update public.student_exam_day_sessions
        set status = 'ended', otp_rotation_required = true, otp_epoch = otp_epoch + 1, updated_at = v_now
        where id = v_day.id;
        update public.exam_sessions set status = 'submitted', submitted_at = v_now, updated_at = v_now where id = v_session.id;
        -- the day is over: close this student's other Continuous sittings that have no paper in progress
        update public.exam_sessions es3
        set status = 'submitted', submitted_at = v_now, updated_at = v_now
        from public.exams e3
        where es3.student_id = v_session.student_id and e3.id = es3.exam_id and e3.mode = 'continuous' and es3.status = 'active'
          and not exists (select 1 from public.exam_session_courses esc3 where esc3.exam_session_id = es3.id and esc3.status in ('active', 'paused', 'submission_pending'));

      else
        update public.exam_sessions set status = 'active', submitted_at = null, updated_at = v_now where id = v_session.id;
      end if;
    end if;
  end if;

  return query select v_selected.id, v_all;
end;
$function$;

