import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildDocx, buildXlsx, emailBody, sheetFileBase, type SheetMeta, type SheetRow } from "../_shared/result-sheet.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type Admin = ReturnType<typeof serviceClient>;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

function serviceClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function requireSuperAdmin(req: Request, admin: Admin) {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("Authentication required.");
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData.user) throw new Error("Authentication required.");
  const { data: profile, error } = await admin.from("profiles").select("role, is_active").eq("id", userData.user.id).single();
  if (error || !profile?.is_active) throw new Error("Active profile not found.");
  if (profile.role !== "superadmin") throw new Error("SuperAdmin authorization required.");
}

function toBase64(bytes: Uint8Array) {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  return btoa(binary);
}

async function sendViaMailer(message: {
  to: string;
  subject: string;
  htmlBody: string;
  attachments: { filename: string; mimeType: string; base64: string }[];
}) {
  const url = Deno.env.get("GAS_MAIL_URL");
  const token = Deno.env.get("GAS_MAIL_TOKEN");
  if (!url || !token) throw new Error("The mail sender is not configured (set GAS_MAIL_URL and GAS_MAIL_TOKEN).");

  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "text/plain;charset=utf-8" },
    body: JSON.stringify({ token, ...message }),
    redirect: "follow",
  });
  const text = await response.text();
  let result: { ok?: boolean; error?: string };
  try {
    result = JSON.parse(text);
  } catch {
    throw new Error(`The mail sender returned an unexpected response (HTTP ${response.status}).`);
  }
  if (!result.ok) throw new Error(result.error || "The mail sender rejected the message.");
}

async function mailSheet(meta: SheetMeta, rows: SheetRow[], to: string) {
  const base = sheetFileBase(meta);
  const [xlsx, docx] = [buildXlsx(meta, rows), await buildDocx(meta, rows)];
  await sendViaMailer({
    to,
    subject: `Result sheet: ${meta.courseCode} ${meta.courseTitle} (${meta.examTitle})`,
    htmlBody: emailBody(meta, rows),
    attachments: [
      { filename: `${base}.xlsx`, mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", base64: toBase64(xlsx) },
      { filename: `${base}.docx`, mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", base64: toBase64(docx) },
    ],
  });
}

const SAMPLE_ROWS: SheetRow[] = [
  { reg_no: "TEST/001", full_name: "Sample Student One", programme_name: "Pharmacy Technician", level: 100, result_status: "Submitted", answered: 20, correct: 16, wrong: 4, unanswered: 0, total: 20, percentage: 80, submitted_at: new Date().toISOString() },
  { reg_no: "TEST/002", full_name: "Sample Student Two", programme_name: "Pharmacy Technician", level: 100, result_status: "Absent", answered: null, correct: null, wrong: null, unanswered: null, total: null, percentage: null, submitted_at: null },
];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const admin = serviceClient();
    await requireSuperAdmin(req, admin);
    const body = await req.json();

    if (body.action === "send_test") {
      const to = String(body.to ?? "").trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) throw new Error("Enter a valid email address.");
      await mailSheet(
        { examTitle: "Test examination", courseCode: "TEST101", courseTitle: "Sample paper", sessionName: "Test session", generatedAt: new Date().toISOString() },
        SAMPLE_ROWS,
        to,
      );
      return json({ ok: true });
    }

    if (body.action !== "send_pending") throw new Error("Unsupported operation.");

    const { data: jobs, error: claimError } = await admin.rpc("claim_result_mail_jobs", {
      p_exam_id: body.examId ?? null,
      p_limit: 20,
    });
    if (claimError) throw new Error(claimError.message);

    let sent = 0;
    const failures: { course: string; error: string }[] = [];

    for (const job of (jobs ?? []) as any[]) {
      try {
        const { data: rows, error } = await admin.rpc("result_sheet_rows", { p_exam_course_id: job.exam_course_id });
        if (error) throw new Error(error.message);
        await mailSheet(
          {
            examTitle: job.exam_title,
            courseCode: job.course_code,
            courseTitle: job.course_title,
            sessionName: job.session_name ?? "",
            generatedAt: new Date().toISOString(),
          },
          (rows ?? []) as SheetRow[],
          String(job.recipients),
        );
        await admin.rpc("complete_result_mail", { p_id: job.id, p_ok: true, p_error: null });
        sent += 1;
      } catch (e) {
        const message = e instanceof Error ? e.message : "Delivery failed";
        await admin.rpc("complete_result_mail", { p_id: job.id, p_ok: false, p_error: message });
        failures.push({ course: String(job.course_code), error: message });
      }
    }

    return json({ processed: (jobs ?? []).length, sent, failed: failures.length, failures });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : "Operation failed." }, 400);
  }
});
