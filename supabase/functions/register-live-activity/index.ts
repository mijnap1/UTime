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

  const schedule = await findMatchingSchedule(
    { supabaseUrl, secretKey },
    payload,
  );

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
        schedule_id: schedule?.id ?? null,
        updated_at: new Date().toISOString(),
      }),
    },
  );

  if (!response.ok) {
    const details = await response.text();
    console.error("Failed to store Live Activity token", details);
    return json({ error: "Could not store Live Activity token" }, 500);
  }

  if (schedule) {
    await markScheduleActive({ supabaseUrl, secretKey }, schedule.id, payload.activity_id);
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

type MatchingSchedule = {
  id: string;
};

async function findMatchingSchedule(
  config: { supabaseUrl: string; secretKey: string },
  payload: LiveActivityRegistration,
): Promise<MatchingSchedule | null> {
  const start = new Date(payload.start_time);
  const end = new Date(payload.end_time);

  if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime())) {
    return null;
  }

  const url = new URL(`${config.supabaseUrl}/rest/v1/class_schedules`);
  url.searchParams.set("select", "id");
  url.searchParams.set("install_id", `eq.${payload.install_id}`);
  url.searchParams.set("course_code", `eq.${payload.course_code}`);
  url.searchParams.set("start_time", `eq.${start.toISOString()}`);
  url.searchParams.set("end_time", `eq.${end.toISOString()}`);
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: dbHeaders(config),
  });

  if (!response.ok) {
    console.error("Could not find matching schedule", await response.text());
    return null;
  }

  const rows: MatchingSchedule[] = await response.json();
  return rows[0] ?? null;
}

async function markScheduleActive(
  config: { supabaseUrl: string; secretKey: string },
  scheduleID: string,
  activityID: string,
) {
  const url = new URL(`${config.supabaseUrl}/rest/v1/class_schedules`);
  url.searchParams.set("id", `eq.${scheduleID}`);

  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      ...dbHeaders(config),
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({
      push_stage: "active",
      activity_id: activityID,
      started_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }),
  });

  if (!response.ok) {
    console.error("Could not mark schedule active", await response.text());
  }
}

function dbHeaders(config: { secretKey: string }) {
  return {
    "apikey": config.secretKey,
    "Authorization": `Bearer ${config.secretKey}`,
  };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}
