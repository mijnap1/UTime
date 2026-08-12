const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type LiveActivityRegistration = {
  install_id: string;
  activity_id: string;
  activity_token: string;
  course_code: string;
  building?: string | null;
  room_number?: string | null;
  meeting_type?: string | null;
  section?: string | null;
  delivery_mode?: string | null;
  start_time: string;
  end_time: string;
  alert_cue_minutes: number;
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

  let payload: LiveActivityRegistration;
  try {
    payload = await request.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const missingField = requiredFields.find((field) => !payload[field]);
  if (missingField) {
    return json({ error: `Missing ${missingField}` }, 400);
  }

  const response = await fetch(
    `${supabaseUrl}/rest/v1/live_activities?on_conflict=activity_id`,
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
        activity_id: payload.activity_id,
        activity_token: payload.activity_token,
        course_code: payload.course_code,
        building: payload.building ?? null,
        room_number: payload.room_number ?? null,
        meeting_type: payload.meeting_type ?? null,
        section: payload.section ?? null,
        delivery_mode: payload.delivery_mode ?? null,
        start_time: payload.start_time,
        end_time: payload.end_time,
        alert_cue_minutes: payload.alert_cue_minutes,
      }),
    },
  );

  if (!response.ok) {
    const details = await response.text();
    console.error("Failed to store Live Activity token", details);
    return json({ error: "Could not store Live Activity token" }, 500);
  }

  return json({ ok: true });
});

const requiredFields: Array<keyof LiveActivityRegistration> = [
  "install_id",
  "activity_id",
  "activity_token",
  "course_code",
  "start_time",
  "end_time",
  "alert_cue_minutes",
];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
