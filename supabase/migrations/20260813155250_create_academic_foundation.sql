-- ============================================================
-- COHT CBT PLATFORM
-- Migration: Academic Foundation
-- ============================================================

-- ============================================================
-- 1. DEPARTMENTS
-- ============================================================

create table public.departments (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    code text not null,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint departments_name_unique unique (name),
    constraint departments_code_unique unique (code)
);


-- ============================================================
-- 2. PROGRAMMES
-- ============================================================

create table public.programmes (
    id uuid primary key default gen_random_uuid(),
    department_id uuid not null references public.departments(id)
        on delete restrict,

    name text not null,
    code text not null,
    duration_years integer,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint programmes_code_unique unique (code),
    constraint programmes_duration_check
        check (duration_years is null or duration_years > 0)
);


-- ============================================================
-- 3. ACADEMIC SESSIONS
-- ============================================================

create table public.academic_sessions (
    id uuid primary key default gen_random_uuid(),

    name text not null,
    start_date date,
    end_date date,
    is_current boolean not null default false,
    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint academic_sessions_name_unique unique (name),
    constraint academic_sessions_dates_check
        check (
            end_date is null
            or start_date is null
            or end_date >= start_date
        )
);


-- ============================================================
-- 4. COURSES
-- ============================================================

create table public.courses (
    id uuid primary key default gen_random_uuid(),

    code text not null,
    title text not null,

    department_id uuid references public.departments(id)
        on delete restrict,

    programme_id uuid references public.programmes(id)
        on delete restrict,

    level integer,
    semester integer,
    credit_units integer,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint courses_code_unique unique (code),

    constraint courses_level_check
        check (
            level is null
            or level > 0
        ),

    constraint courses_semester_check
        check (
            semester is null
            or semester in (1, 2)
        ),

    constraint courses_credit_units_check
        check (
            credit_units is null
            or credit_units > 0
        )
);


-- ============================================================
-- 5. STUDENTS
-- ============================================================

create table public.students (
    id uuid primary key default gen_random_uuid(),

    reg_no text not null,
    full_name text not null,

    programme_id uuid references public.programmes(id)
        on delete restrict,

    level integer,

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint students_reg_no_unique unique (reg_no),

    constraint students_level_check
        check (
            level is null
            or level > 0
        )
);


-- ============================================================
-- 6. STUDENT COURSE REGISTRATIONS
-- ============================================================

create table public.student_course_registrations (
    id uuid primary key default gen_random_uuid(),

    student_id uuid not null references public.students(id)
        on delete cascade,

    course_id uuid not null references public.courses(id)
        on delete restrict,

    academic_session_id uuid not null
        references public.academic_sessions(id)
        on delete restrict,

    registration_type text not null default 'regular',

    registered_at timestamptz not null default now(),
    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint student_course_registration_unique
        unique (
            student_id,
            course_id,
            academic_session_id
        ),

    constraint registration_type_check
        check (
            registration_type in (
                'regular',
                'resit',
                'carry_over',
                'special'
            )
        )
);


-- ============================================================
-- INDEXES
-- ============================================================

create index idx_programmes_department_id
    on public.programmes(department_id);

create index idx_courses_department_id
    on public.courses(department_id);

create index idx_courses_programme_id
    on public.courses(programme_id);

create index idx_students_programme_id
    on public.students(programme_id);

create index idx_student_course_registrations_student_id
    on public.student_course_registrations(student_id);

create index idx_student_course_registrations_course_id
    on public.student_course_registrations(course_id);

create index idx_student_course_registrations_session_id
    on public.student_course_registrations(academic_session_id);


-- ============================================================
-- UPDATED_AT TRIGGER FUNCTION
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;


-- ============================================================
-- UPDATED_AT TRIGGERS
-- ============================================================

create trigger departments_set_updated_at
before update on public.departments
for each row
execute function public.set_updated_at();

create trigger programmes_set_updated_at
before update on public.programmes
for each row
execute function public.set_updated_at();

create trigger academic_sessions_set_updated_at
before update on public.academic_sessions
for each row
execute function public.set_updated_at();

create trigger courses_set_updated_at
before update on public.courses
for each row
execute function public.set_updated_at();

create trigger students_set_updated_at
before update on public.students
for each row
execute function public.set_updated_at();

create trigger student_course_registrations_set_updated_at
before update on public.student_course_registrations
for each row
execute function public.set_updated_at();