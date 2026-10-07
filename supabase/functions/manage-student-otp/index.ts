import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const OTP_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

type Admin = ReturnType<typeof serviceClient>;
type StudentRow = { id: string; reg_no: string; full_name: string };

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

function makeOtp() {
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  // 256 is divisible by 32, so the modulo introduces no bias.
  return Array.from(bytes, (b) => OTP_ALPHABET[b % OTP_ALPHABET.length]).join("");
}

function authEmail(regNo: string) {
  return `${regNo.trim().toLowerCase()}@student.coht.local`;
}

async function requireSuperAdmin(req: Request, admin: Admin) {
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

async function saveOtp(admin: Admin, studentId: string, otp: string) {
  const { data: current } = await admin
    .from("student_exam_otps")
    .select("otp_epoch")
    .eq("student_id", studentId)
    .maybeSingle();

  const now = new Date().toISOString();
  const { error } = await admin.from("student_exam_otps").upsert(
    {
      student_id: studentId,
      current_otp: otp,
      otp_epoch: Number(current?.otp_epoch ?? 0) + 1,
      valid_for_date: now.slice(0, 10),
      issued_at: now,
      updated_at: now,
    },
    { onConflict: "student_id" },
  );
  if (error) throw new Error(error.message);
  return now;
}

/**
 * Creates the student's sign-in account and profile. Imports only create
 * `students` rows, and a data reset removes the accounts, so accounts are
 * provisioned here the first time an OTP is issued.
 */
async function provisionAccount(admin: Admin, student: StudentRow, otp: string) {
  const email = authEmail(student.reg_no);

  let userId: string;
  const created = await admin.auth.admin.createUser({
    email,
    password: otp,
    email_confirm: true,
    user_metadata: { full_name: student.full_name, reg_no: student.reg_no },
  });

  if (created.error || !created.data.user) {
    // The Auth user may already exist without a profile (an interrupted run).
    const { data: existingId } = await admin.rpc("find_auth_user_id", { p_email: email });
    if (!existingId) throw new Error(created.error?.message ?? "Could not create the sign-in account.");
    userId = String(existingId);
    const updated = await admin.auth.admin.updateUserById(userId, { password: otp });
    if (updated.error) throw new Error(updated.error.message);
  } else {
    userId = created.data.user.id;
  }

  const { error: profileError } = await admin.from("profiles").upsert(
    { id: userId, role: "student", student_id: student.id, display_name: student.full_name, is_active: true },
    { onConflict: "id" },
  );
  if (profileError) throw new Error(`Profile could not be created: ${profileError.message}`);
}

/** Returns today's OTP for the student, creating the account or rotating as needed. */
async function ensureCurrent(admin: Admin, student: StudentRow) {
  const today = new Date().toISOString().slice(0, 10);

  const { data: profile } = await admin
    .from("profiles")
    .select("id")
    .eq("student_id", student.id)
    .maybeSingle();

  if (profile) {
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

  const otp = makeOtp();
  await provisionAccount(admin, student, otp);
  const issuedAt = await saveOtp(admin, student.id, otp);
  return { ...student, otp, issued_at: issuedAt };
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
          students.push(await ensureCurrent(admin, { id: s.id, reg_no: s.reg_no, full_name: s.full_name }));
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
