-- ============================================================
-- Student result visibility is decided per examination
-- ============================================================
-- exams.show_instant_results is the single switch. Students read their own
-- final results through the existing exam_results policy, which only allows it
-- when the flag is on. The submit functions used to return the score to the
-- student's browser whatever the flag said; students now submit through a
-- wrapper that returns counts and progress only.

create or replace function public.submit_exam_paper_for_student(
  p_exam_session_course_id uuid,
  p_submission_request_id uuid
)
returns table(
  answered_questions integer,
  total_questions integer,
  all_papers_submitted boolean,
  otp_rotation_required boolean
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  r record;
begin
  select * into r from public.submit_exam_paper_v2(p_exam_session_course_id, p_submission_request_id);

  return query
  select (r.correct_answers + r.wrong_answers)::integer,
         (r.correct_answers + r.wrong_answers + r.unanswered_questions)::integer,
         r.all_papers_submitted,
         r.otp_rotation_required;
end;
$$;

revoke all on function public.submit_exam_paper_for_student(uuid, uuid) from public, anon;
grant execute on function public.submit_exam_paper_for_student(uuid, uuid) to authenticated;

-- Students can no longer call the score-returning submit functions directly.
revoke execute on function public.submit_exam_paper_v2(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.submit_exam_paper(uuid, uuid) from public, anon, authenticated;

-- The global switch only ever stored a value that nothing read.
drop function if exists public.superadmin_set_instant_results(boolean);
delete from public.system_settings where key = 'instant_results';
