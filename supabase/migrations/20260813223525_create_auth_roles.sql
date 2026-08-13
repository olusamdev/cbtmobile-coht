-- ============================================================
-- MIGRATION 5: AUTHENTICATION PROFILES AND ROLES
-- ============================================================
-- Establishes the application identity layer on top of
-- Supabase Auth.
--
-- Supabase Auth owns authentication.
-- public.profiles owns application role/identity mapping.
--
-- Roles:
--   student
--   admin
--   superadmin
--
-- IMPORTANT:
-- A user must NEVER be able to select or modify their own
-- privileged role from the client.
-- Role-management policies/functions will be added in the
-- security/RLS layer.
-- ============================================================


-- ============================================================
-- 1. PROFILES
-- ============================================================
-- One application profile corresponds to one Supabase Auth user.
--
-- auth.users.id is the authoritative authentication identity.
--
-- student_id is populated only for student accounts.
-- Admin and Superadmin accounts do not require a student record.
-- ============================================================

create table public.profiles (
    id uuid primary key
        references auth.users(id)
        on delete cascade,

    role text not null default 'student'
        check (
            role in (
                'student',
                'admin',
                'superadmin'
            )
        ),

    student_id uuid
        references public.students(id)
        on delete restrict,

    is_active boolean not null default true,

    display_name text,

    created_at timestamptz not null default now(),

    updated_at timestamptz not null default now(),

    -- A student profile may point to only one student record.
    unique (student_id)
);


-- ============================================================
-- 2. INDEXES
-- ============================================================

create index idx_profiles_role
    on public.profiles(role);

create index idx_profiles_student_id
    on public.profiles(student_id);

create index idx_profiles_is_active
    on public.profiles(is_active);


-- ============================================================
-- 3. ROLE / STUDENT CONSISTENCY
-- ============================================================
-- Students must have a student_id.
-- Administrative accounts must not be linked to a student
-- academic record.
--
-- This prevents a profile from accidentally becoming both an
-- academic student identity and an administrative identity.
-- ============================================================

alter table public.profiles
add constraint profiles_role_student_consistency
check (
    (role = 'student' and student_id is not null)
    or
    (role in ('admin', 'superadmin') and student_id is null)
);


-- ============================================================
-- 4. UPDATED_AT TRIGGER
-- ============================================================

create trigger profiles_set_updated_at
before update on public.profiles
for each row
execute function public.set_updated_at();


-- ============================================================
-- 5. COMMENTS
-- ============================================================

comment on table public.profiles is
    'Application identity profile linked one-to-one with a Supabase Auth user.';

comment on column public.profiles.id is
    'Supabase Auth user ID from auth.users.id.';

comment on column public.profiles.role is
    'Application role: student, admin, or superadmin. Privileged roles must be assigned through trusted administrative operations.';

comment on column public.profiles.student_id is
    'Academic student record associated with this authenticated user. Required only for student profiles.';

comment on column public.profiles.is_active is
    'Controls whether this account is currently permitted to access the application.';

comment on column public.profiles.display_name is
    'Display name used by administrative interfaces.';