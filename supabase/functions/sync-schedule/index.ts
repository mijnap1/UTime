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
  await deleteScheduleRows(config, payload.install_id);

  const rows = payload.events
    .filter((event) => new Date(event.end_time).getTime() > Date.now())
    .map((event) => ({
      install_id: payload.install_id,
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
      push_stage: "pending",
      updated_at: new Date().toISOString(),
    }));

  if (rows.length > 0) {
    await insertScheduleRows(config, rows);
  }

  return json({ ok: true, synced: rows.length });
});

function validatePayload(payload: ScheduleSyncPayload) {
  if (!payload.install_id) {
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

  for (const event of payload.events) {
    if (!event.event_uid || !event.course_code || !event.start_time || !event.end_time) {
      return "Schedule event is missing required fields";
    }
  }

  return null;
}

async function deleteScheduleRows(
  config: { supabaseUrl: string; secretKey: string },
  installID: string,
) {
  const url = new URL(`${config.supabaseUrl}/rest/v1/class_schedules`);
  url.searchParams.set("install_id", `eq.${installID}`);

  const response = await fetch(url, {
    method: "DELETE",
    headers: {
      ...dbHeaders(config),
      "Prefer": "return=minimal",
    },
  });

  if (!response.ok) {
    throw new Error(`Could not clear schedule rows: ${await response.text()}`);
  }
}

async function insertScheduleRows(
  config: { supabaseUrl: string; secretKey: string },
  rows: Array<Record<string, unknown>>,
) {
  const response = await fetch(`${config.supabaseUrl}/rest/v1/class_schedules`, {
    method: "POST",
    headers: {
      ...dbHeaders(config),
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify(rows),
  });

  if (!response.ok) {
    throw new Error(`Could not insert schedule rows: ${await response.text()}`);
  }
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
