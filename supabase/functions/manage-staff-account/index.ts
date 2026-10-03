import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("Supabase function environment is not configured.");
}

const adminClient = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function requireSuperAdmin(req: Request) {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) throw new Error("Authentication required.");

  const token = authHeader.slice("Bearer ".length);
  const { data: userData, error: userError } = await adminClient.auth.getUser(token);
  if (userError || !userData.user) throw new Error("Invalid authentication session.");

  const { data: profile, error: profileError } = await adminClient
    .from("profiles")
    .select("id, role, is_active")
    .eq("id", userData.user.id)
    .single();

  if (profileError || !profile || profile.role !== "superadmin" || !profile.is_active) {
    throw new Error("SuperAdmin authorization required.");
  }

  return userData.user;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    const caller = await requireSuperAdmin(req);
    const body = await req.json();
    const action = String(body.action ?? "");

    if (action === "create_admin") {
      const fullName = String(body.fullName ?? "").trim();
      const email = String(body.email ?? "").trim().toLowerCase();
      const password = String(body.password ?? "");

      if (fullName.length < 2) throw new Error("Enter the administrator's full name.");
      if (!email || !email.includes("@")) throw new Error("Enter a valid administrative email address.");
      if (password.length < 8) throw new Error("Password must be at least 8 characters.");

      const { data: created, error: createError } = await adminClient.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { display_name: fullName },
      });

      if (createError) throw new Error(createError.message);
      if (!created.user) throw new Error("Auth user was not created.");

      const { error: profileError } = await adminClient.from("profiles").insert({
        id: created.user.id,
        role: "admin",
        student_id: null,
        is_active: true,
        display_name: fullName,
      });

      if (profileError) {
        // Roll back the Auth user if application-profile creation failed.
        await adminClient.auth.admin.deleteUser(created.user.id);
        throw new Error(profileError.message);
      }

      return json({ ok: true, userId: created.user.id, createdBy: caller.id });
    }

    if (action === "change_password") {
      const adminId = String(body.adminId ?? "");
      const password = String(body.password ?? "");
      if (!adminId) throw new Error("Administrator account is required.");
      if (password.length < 8) throw new Error("Password must be at least 8 characters.");

      const { data: target, error: targetError } = await adminClient
        .from("profiles")
        .select("id, role")
        .eq("id", adminId)
        .single();

      if (targetError || !target) throw new Error("Administrator account not found.");
      if (target.role !== "admin") throw new Error("Only administrator passwords can be changed here.");

      const { error: updateError } = await adminClient.auth.admin.updateUserById(adminId, {
        password,
      });

      if (updateError) throw new Error(updateError.message);

      return json({ ok: true, updatedUserId: adminId, updatedBy: caller.id });
    }

    throw new Error("Unsupported staff-account operation.");
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected server error.";
    const status = message.includes("Authentication") || message.includes("authorization") || message.includes("Authorization")
      ? 401
      : 400;
    return json({ error: message }, status);
  }
});
