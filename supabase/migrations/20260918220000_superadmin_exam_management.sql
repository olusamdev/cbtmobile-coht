create or replace function public.superadmin_create_exam(
    p_academic_session_id uuid, p_title text, p_mode text,
    p_duration_minutes integer, p_question_count integer,
    p_is_active boolean, p_course_ids uuid[]
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_exam_id uuid; v_course_id uuid; v_order integer:=1;
begin
 if public.current_user_role() <> 'superadmin' then raise exception 'SuperAdmin authorization required'; end if;
 if not exists(select 1 from public.academic_sessions where id=p_academic_session_id and is_active) then raise exception 'Selected academic session is not active or does not exist'; end if;
 if nullif(trim(p_title),'') is null then raise exception 'Examination title is required'; end if;
 if p_mode not in ('regular','pharmacy-prenational','pharmacy_prenational','continuous') then raise exception 'Invalid examination mode'; end if;
 if p_duration_minutes<=0 then raise exception 'Duration must be greater than zero'; end if;
 if p_question_count<0 then raise exception 'Question count cannot be negative'; end if;
 if coalesce(array_length(p_course_ids,1),0)=0 then raise exception 'At least one paper/course is required'; end if;
 if p_mode='regular' and array_length(p_course_ids,1)<>1 then raise exception 'Regular examinations require exactly one paper'; end if;
 insert into public.exams(academic_session_id,title,mode,duration_minutes,question_count,is_active)
 values(p_academic_session_id,trim(p_title),replace(p_mode,'pharmacy-prenational','pharmacy_prenational'),p_duration_minutes,p_question_count,coalesce(p_is_active,false)) returning id into v_exam_id;
 foreach v_course_id in array p_course_ids loop
  if not exists(select 1 from public.courses where id=v_course_id and is_active) then raise exception 'One or more selected courses are invalid or inactive'; end if;
  insert into public.exam_courses(exam_id,course_id,paper_order) values(v_exam_id,v_course_id,v_order); v_order:=v_order+1;
 end loop;
 return v_exam_id;
end; $$;
revoke all on function public.superadmin_create_exam(uuid,text,text,integer,integer,boolean,uuid[]) from public;
grant execute on function public.superadmin_create_exam(uuid,text,text,integer,integer,boolean,uuid[]) to authenticated;
