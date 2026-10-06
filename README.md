# COHT CBT — Backend

Supabase backend for the College of Health Technology CBT portal: Postgres schema, RLS, RPCs and edge functions. The frontend lives in the `coht-cbt` repo.

## Contents

- `supabase/migrations/` ordered SQL migrations (schema, auth roles, exam execution, scoring, admin/SuperAdmin operations)
- `supabase/functions/manage-staff-account` create admin accounts, change admin passwords (SuperAdmin only)
- `supabase/functions/manage-student-otp` issue and rotate student OTPs (SuperAdmin; students for their own rotation)
- `supabase/tests/` SQL verification scripts

## Deploy

```sh
supabase link --project-ref <ref>
supabase db push
supabase functions deploy manage-staff-account manage-student-otp
```

## Student login

Registration number plus OTP. The matric number maps to a synthetic Auth email; the OTP is the Auth password.

Do not edit migrations that have already been applied; add a new one.
