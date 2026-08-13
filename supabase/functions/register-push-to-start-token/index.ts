const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type PushToStartRegistration = {
  install_id: string;
  push_to_start_token: string;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const secretKey =
    Deno.env.get("UTIME_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !secretKey) {
    return json({ error: "Missing Supabase server configuration" }, 500);
  }

  let payload: PushToStartRegistration;
  try {
    payload = await request.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  if (!payload.install_id) {
    return json({ error: "Missing install_id" }, 400);
  }

  if (!payload.push_to_start_token) {
    return json({ error: "Missing push_to_start_token" }, 400);
  }

  const response = await fetch(
    `${supabaseUrl}/rest/v1/push_to_start_tokens?on_conflict=install_id`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": secretKey,
        "Authorization": `Bearer ${secretKey}`,
        "Prefer": "resolution=merge-duplicates,return=minimal",
      },
      body: JSON.stringify({
        install_id: payload.install_id,
        push_to_start_token: payload.push_to_start_token,
        updated_at: new Date().toISOString(),
      }),
    },
  );

  if (!response.ok) {
    const details = await response.text();
    console.error("Failed to store push-to-start token", details);
    return json({ error: "Could not store push-to-start token", details }, 500);
  }

  return json({ ok: true });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
