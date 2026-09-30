const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ScheduleEvent = {
  event_uid: string;
  course_code: string;
  building?: string | null;
  room_number?: string | null;
  meeting_type?: string | null;
  section?: string | null;
  delivery_mode?: string | null;
  start_time: string;
  end_time: string;
};

type ScheduleSyncPayload = {
  install_id: string;
  live_activity_lead_minutes: number;
  alert_cue_minutes: number;
  events: ScheduleEvent[];
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

  let payload: ScheduleSyncPayload;
  try {
    payload = await request.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const validationError = validatePayload(payload);
  if (validationError) {
    return json({ error: validationError }, 400);
  }

  const config = { supabaseUrl, secretKey };

  const rows = payload.events
    .filter((event) => new Date(event.end_time).getTime() > Date.now())
    .map((event) => ({
      event_uid: event.event_uid,
      course_code: event.course_code,
      building: event.building ?? null,
      room_number: event.room_number ?? null,
      meeting_type: event.meeting_type ?? null,
      section: event.section ?? null,
      delivery_mode: event.delivery_mode ?? null,
      start_time: event.start_time,
      end_time: event.end_time,
      live_activity_lead_minutes: clampMinutes(payload.live_activity_lead_minutes),
      alert_cue_minutes: clampMinutes(payload.alert_cue_minutes),
    }));

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/sync_class_schedule`, {
    method: "POST", headers: { ...dbHeaders(config), "Content-Type": "application/json" },
    body: JSON.stringify({ p_install_id: payload.install_id, p_events: rows }),
  });
  if (!response.ok) {
    console.error("Atomic schedule sync failed", response.status);
    return json({ error: "Schedule sync failed; your previous schedule was retained" }, 500);
  }
  return json({ ok: true, synced: rows.length });
});

function validatePayload(payload: ScheduleSyncPayload) {
  if (!payload || typeof payload.install_id !== "string" || !payload.install_id) {
    return "Missing install_id";
  }

  if (!Array.isArray(payload.events)) {
    return "Missing events";
  }

  if (!Number.isFinite(payload.live_activity_lead_minutes)) {
    return "Missing live_activity_lead_minutes";
  }

  if (!Number.isFinite(payload.alert_cue_minutes)) {
    return "Missing alert_cue_minutes";
  }

  const ids = new Set<string>();
  for (const event of payload.events) {
    if (!event || !event.event_uid || !event.course_code || !event.start_time || !event.end_time) {
      return "Schedule event is missing required fields";
    }
    const start = Date.parse(event.start_time), end = Date.parse(event.end_time);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || ids.has(event.event_uid)) {
      return "Schedule contains invalid dates or duplicate events";
    }
    ids.add(event.event_uid);
  }

  return null;
}

function clampMinutes(value: number) {
  return Math.min(Math.max(Math.round(value), 1), 60);
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
