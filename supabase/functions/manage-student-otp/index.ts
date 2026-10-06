import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function serviceClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function requireSuperAdmin(req: Request, admin: ReturnType<typeof serviceClient>) {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("Authentication required.");

  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData.user) throw new Error("Authentication required.");

  const { data: profile, error: profileError } = await admin
    .from("profiles")
    .select("role, is_active")
    .eq("id", userData.user.id)
    .single();

  if (profileError || !profile?.is_active) throw new Error("Active profile not found.");
  if (profile.role !== "superadmin") throw new Error("SuperAdmin authorization required.");
}

/**
 * Returns the student's OTP for today, creating one when none exists for
 * today. Generation and the Auth password update both happen inside
 * public.rotate_student_otp, the same function the submission trigger uses.
 */
async function ensureCurrent(admin: ReturnType<typeof serviceClient>, student: { id: string; reg_no: string; full_name: string }) {
  const today = new Date().toISOString().slice(0, 10);

  const { data: existing } = await admin
    .from("student_exam_otps")
    .select("current_otp, valid_for_date, issued_at")
    .eq("student_id", student.id)
    .maybeSingle();

  if (existing?.current_otp && existing.valid_for_date === today) {
    return { ...student, otp: existing.current_otp, issued_at: existing.issued_at };
  }

  const { data: otp, error } = await admin.rpc("rotate_student_otp", { p_student_id: student.id });
  if (error) throw new Error(error.message);

  return { ...student, otp: String(otp), issued_at: new Date().toISOString() };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const admin = serviceClient();
    await requireSuperAdmin(req, admin);

    const body = await req.json();
    if (body.action !== "ensure_current") throw new Error("Unsupported OTP operation.");

    const { data: list, error } = await admin
      .from("students")
      .select("id, reg_no, full_name, programmes(department_id)")
      .eq("is_active", true)
      .order("reg_no");
    if (error) throw new Error(error.message);

    const targets = (list ?? []).filter((s: any) =>
      body.studentId
        ? s.id === String(body.studentId)
        : body.departmentId
          ? s.programmes?.department_id === String(body.departmentId)
          : true,
    );

    const students: unknown[] = [];
    const failures: string[] = [];
    const queue = [...targets];

    const worker = async () => {
      while (queue.length) {
        const s = queue.shift();
        if (!s) break;
        try {
          students.push(await ensureCurrent(admin, s));
        } catch (e) {
          failures.push(`${s.reg_no}: ${e instanceof Error ? e.message : "OTP generation failed"}`);
        }
      }
    };

    await Promise.all(Array.from({ length: Math.min(8, Math.max(1, targets.length)) }, worker));

    return json({ students, failures });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : "OTP operation failed." }, 400);
  }
});
