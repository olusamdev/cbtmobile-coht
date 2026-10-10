import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const MAX_BYTES = 300_000;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!token) throw new Error("Authentication required.");
    const { data: userData, error: userError } = await admin.auth.getUser(token);
    if (userError || !userData.user) throw new Error("Authentication required.");

    const { data: profile } = await admin
      .from("profiles")
      .select("role, is_active, student_id")
      .eq("id", userData.user.id)
      .single();
    if (!profile?.is_active || profile.role !== "student" || !profile.student_id) {
      throw new Error("Only students can upload an identifier photo.");
    }
    const studentId = String(profile.student_id);

    const form = await req.formData();
    const photo = form.get("photo");
    const gender = String(form.get("gender") ?? "");
    if (!(photo instanceof Blob)) throw new Error("Choose a photo first.");
    if (gender && gender !== "male" && gender !== "female") throw new Error("Choose your gender.");
    if (photo.size === 0 || photo.size > MAX_BYTES) throw new Error("The photo must be smaller than 300 KB.");

    const bytes = new Uint8Array(await photo.arrayBuffer());
    const isJpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    if (!isJpeg) throw new Error("The photo must be a JPEG image.");

    // Fails with a clear message when the student has used up their uploads.
    const { data: index, error: indexError } = await admin.rpc("student_photo_next_index", { p_student_id: studentId });
    if (indexError) throw new Error(indexError.message);

    const path = `${studentId}/${index}.jpg`;
    const { error: uploadError } = await admin.storage
      .from("student-photos")
      .upload(path, bytes, { contentType: "image/jpeg", upsert: true });
    if (uploadError) throw new Error(`Upload failed: ${uploadError.message}`);

    const { error: recordError } = await admin.rpc("record_student_photo", {
      p_student_id: studentId,
      p_path: path,
      p_gender: gender || null,
    });
    if (recordError) throw new Error(recordError.message);

    return json({ ok: true, path });
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : "Upload failed." }, 400);
  }
});
