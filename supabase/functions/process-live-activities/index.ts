const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-utime-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type LiveActivityRow = ClassScheduleFields & {
  install_id: string;
  activity_id: string;
  activity_token: string;
  schedule_id: string | null;
  push_stage: string | null;
  last_push_at: string | null;
};

type ClassScheduleRow = ClassScheduleFields & {
  id: string;
  install_id: string;
  event_uid: string;
  live_activity_lead_minutes: number;
  push_stage: string | null;
  activity_id: string | null;
  last_push_at: string | null;
};

type PushToStartTokenRow = {
  install_id: string;
  push_to_start_token: string;
};

type ClassScheduleFields = {
  course_code: string;
  building: string | null;
  room_number: string | null;
  meeting_type: string | null;
  section: string | null;
  delivery_mode: string | null;
  start_time: string;
  end_time: string;
  alert_cue_minutes: number;
};

Deno.serve(async (request) => {
  try {
    if (request.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    const cronSecret = Deno.env.get("UTIME_CRON_SECRET");
    if (!cronSecret || request.headers.get("x-utime-cron-secret") !== cronSecret) {
      return json({ error: "Unauthorized" }, 401);
    }

    const config = readConfig();
    const now = new Date();

    const updateResult = await updateActiveLiveActivities(config, now);
    const startResult = await startDueSchedules(config, now);

    return json({
      ok: true,
      checked_schedules: startResult.checked,
      started: startResult.started,
      skipped_start: startResult.skipped,
      checked_activities: updateResult.checked,
      updated: updateResult.updated,
      ended: updateResult.ended,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    return json({ ok: false, error: message }, 500);
  }
});

async function startDueSchedules(config: ReturnType<typeof readConfig>, now: Date) {
  const schedules = await fetchDueScheduleRows(config, now);
  let started = 0;
  let skipped = 0;

  for (const schedule of schedules) {
    if (schedule.push_stage !== "pending") {
      skipped += 1;
      continue;
    }

    if (await hasBlockingEarlierSchedule(config, schedule, now)) {
      skipped += 1;
      continue;
    }

    const token = await fetchPushToStartToken(config, schedule.install_id);
    if (!token) {
      skipped += 1;
      continue;
    }

    await sendStartPush(config, schedule, token.push_to_start_token);
    await markScheduleStage(config, schedule.id, "start_sent");
    started += 1;
  }

  return { checked: schedules.length, started, skipped };
}

async function updateActiveLiveActivities(config: ReturnType<typeof readConfig>, now: Date) {
  const rows = await fetchActiveRows(config);
  let updated = 0;
  let ended = 0;

  for (const row of rows) {
    const startTime = new Date(row.start_time);
    const endTime = new Date(row.end_time);
    const cueStart = new Date(startTime.getTime() - row.alert_cue_minutes * 60_000);

    if (now >= endTime) {
      await sendLiveActivityPush(config, row, "end");
      await markLiveActivityStage(config, row.activity_id, "ended");
      await markMatchingScheduleEnded(config, row);
      ended += 1;
      continue;
    }

    if (now >= cueStart && shouldSendCueUpdate(row, now)) {
      await sendLiveActivityPush(config, row, "update");
      await markLiveActivityStage(config, row.activity_id, "cue");
      await markMatchingScheduleCue(config, row);
      updated += 1;
    }
  }

  return { checked: rows.length, updated, ended };
}

function readConfig() {
  const supabaseUrl = requiredEnv("SUPABASE_URL");
  const secretKey =
    Deno.env.get("UTIME_SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!secretKey) {
    throw new Error("Missing UTIME_SUPABASE_SECRET_KEY");
  }

  return {
    supabaseUrl,
    secretKey,
    apnsTeamID: requiredEnv("APNS_TEAM_ID"),
    apnsKeyID: requiredEnv("APNS_KEY_ID"),
    apnsPrivateKey: requiredEnv("APNS_PRIVATE_KEY"),
    apnsTopic: Deno.env.get("APNS_LIVE_ACTIVITY_TOPIC") ?? "com.jamie.UTime.push-type.liveactivity",
    apnsHost: Deno.env.get("APNS_ENV") === "production"
      ? "api.push.apple.com"
      : "api.sandbox.push.apple.com",
  };
}

async function fetchDueScheduleRows(
  config: ReturnType<typeof readConfig>,
  now: Date,
): Promise<ClassScheduleRow[]> {
  const url = new URL(`${config.supabaseUrl}/rest/v1/class_schedules`);
  url.searchParams.set("select", "*");
  url.searchParams.set("push_stage", "eq.pending");
  url.searchParams.set("end_time", `gt.${now.toISOString()}`);
  url.searchParams.set("order", "start_time.asc");
  url.searchParams.set("limit", "100");

  const response = await fetch(url, {
    headers: dbHeaders(config),
  });

  if (!response.ok) {
    throw new Error(`Could not fetch schedule rows: ${await response.text()}`);
  }

  const rows: ClassScheduleRow[] = await response.json();
  return rows.filter((row) => {
    const startTime = new Date(row.start_time).getTime();
    const endTime = new Date(row.end_time).getTime();
    const leadStart = startTime - row.live_activity_lead_minutes * 60_000;
    return now.getTime() >= leadStart && now.getTime() < endTime;
  });
}

async function hasBlockingEarlierSchedule(
  config: ReturnType<typeof readConfig>,
  schedule: ClassScheduleRow,
  now: Date,
) {
  const url = new URL(`${config.supabaseUrl}/rest/v1/class_schedules`);
  url.searchParams.set("select", "id");
  url.searchParams.set("install_id", `eq.${schedule.install_id}`);
  url.searchParams.set("start_time", `lt.${new Date(schedule.start_time).toISOString()}`);
  url.searchParams.set("end_time", `gt.${now.toISOString()}`);
  url.searchParams.set("order", "start_time.asc");
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: dbHeaders(config),
  });

  if (!response.ok) {
    throw new Error(`Could not check earlier schedules: ${await response.text()}`);
  }

  const rows: Array<{ id: string }> = await response.json();
  return rows.length > 0;
}

async function fetchPushToStartToken(
  config: ReturnType<typeof readConfig>,
  installID: string,
): Promise<PushToStartTokenRow | null> {
  const url = new URL(`${config.supabaseUrl}/rest/v1/push_to_start_tokens`);
  url.searchParams.set("select", "*");
  url.searchParams.set("install_id", `eq.${installID}`);
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: dbHeaders(config),
  });

  if (!response.ok) {
    throw new Error(`Could not fetch push-to-start token: ${await response.text()}`);
  }

  const rows: PushToStartTokenRow[] = await response.json();
  return rows[0] ?? null;
}

async function fetchActiveRows(config: ReturnType<typeof readConfig>): Promise<LiveActivityRow[]> {
  const now = Date.now();
  const futureCutoff = new Date(now + 61 * 60_000).toISOString();
  const pastCutoff = new Date(now - 90 * 60_000).toISOString();
  const url = new URL(`${config.supabaseUrl}/rest/v1/live_activities`);
  url.searchParams.set("select", "*");
  url.searchParams.set("push_stage", "neq.ended");
  url.searchParams.set("start_time", `lte.${futureCutoff}`);
  url.searchParams.set("end_time", `gte.${pastCutoff}`);

  const response = await fetch(url, {
    headers: dbHeaders(config),
  });

  if (!response.ok) {
    throw new Error(`Could not fetch Live Activities: ${await response.text()}`);
  }

  return await response.json();
}

async function markScheduleStage(
  config: ReturnType<typeof readConfig>,
  scheduleID: string,
  stage: "start_sent",
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
      push_stage: stage,
      last_push_at: new Date().toISOString(),
      started_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }),
  });

  if (!response.ok) {
    throw new Error(`Could not mark schedule ${scheduleID} as ${stage}: ${await response.text()}`);
  }
}

async function markLiveActivityStage(
  config: ReturnType<typeof readConfig>,
  activityID: string,
  stage: "cue" | "ended",
) {
  const url = new URL(`${config.supabaseUrl}/rest/v1/live_activities`);
  url.searchParams.set("activity_id", `eq.${activityID}`);

  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      ...dbHeaders(config),
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify({
      push_stage: stage,
      last_push_at: new Date().toISOString(),
      ended_at: stage === "ended" ? new Date().toISOString() : null,
    }),
  });

  if (!response.ok) {
    throw new Error(`Could not mark ${activityID} as ${stage}: ${await response.text()}`);
  }
}

async function markMatchingScheduleCue(
  config: ReturnType<typeof readConfig>,
  row: LiveActivityRow,
) {
  await patchMatchingSchedule(config, row, {
    push_stage: "cue",
    activity_id: row.activity_id,
    last_push_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  });
}

async function markMatchingScheduleEnded(
  config: ReturnType<typeof readConfig>,
  row: LiveActivityRow,
) {
  await patchMatchingSchedule(config, row, {
    push_stage: "ended",
    activity_id: row.activity_id,
    last_push_at: new Date().toISOString(),
    ended_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  });
}

async function patchMatchingSchedule(
  config: ReturnType<typeof readConfig>,
  row: LiveActivityRow,
  body: Record<string, unknown>,
) {
  const scheduleID = "schedule_id" in row ? row.schedule_id : null;
  const url = new URL(`${config.supabaseUrl}/rest/v1/class_schedules`);

  if (typeof scheduleID === "string" && scheduleID.length > 0) {
    url.searchParams.set("id", `eq.${scheduleID}`);
  } else {
    url.searchParams.set("install_id", `eq.${row.install_id}`);
    url.searchParams.set("course_code", `eq.${row.course_code}`);
    url.searchParams.set("start_time", `eq.${new Date(row.start_time).toISOString()}`);
    url.searchParams.set("end_time", `eq.${new Date(row.end_time).toISOString()}`);
  }

  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      ...dbHeaders(config),
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    console.error("Could not patch matching schedule", await response.text());
  }
}

async function sendStartPush(
  config: ReturnType<typeof readConfig>,
  row: ClassScheduleRow,
  pushToStartToken: string,
) {
  const jwt = await createProviderToken(config);
  const now = Math.floor(Date.now() / 1000);

  const payload: Record<string, unknown> = {
    aps: {
      timestamp: now,
      event: "start",
      "attributes-type": "ClassActivityAttributes",
      attributes: attributes(row),
      "content-state": contentState(row, shouldShowCompactCountdown(row)),
      "stale-date": Math.floor(new Date(row.start_time).getTime() / 1000),
      "relevance-score": 100,
      alert: {
        title: `${displayCourseCode(row.course_code)} starts soon`,
        body: alertBody(row),
        sound: "default",
      },
    },
  };

  const response = await fetch(`https://${config.apnsHost}/3/device/${pushToStartToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": config.apnsTopic,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`APNs start failed: ${response.status} ${await response.text()}`);
  }
}

async function sendLiveActivityPush(
  config: ReturnType<typeof readConfig>,
  row: LiveActivityRow,
  event: "update" | "end",
) {
  const jwt = await createProviderToken(config);
  const now = Math.floor(Date.now() / 1000);
  const startUnix = Math.floor(new Date(row.start_time).getTime() / 1000);

  const payload: Record<string, unknown> = {
    aps: {
      timestamp: now,
      event,
      "content-state": contentState(row, event === "update"),
      "stale-date": event === "update" ? startUnix : now,
      ...(event === "update" ? { "relevance-score": 100 } : {}),
      ...(event === "end" ? { "dismissal-date": now } : {}),
    },
  };

  const response = await fetch(`https://${config.apnsHost}/3/device/${row.activity_token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": config.apnsTopic,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`APNs ${event} failed: ${response.status} ${await response.text()}`);
  }
}

function attributes(row: ClassScheduleFields) {
  return {
    courseCode: row.course_code,
    building: row.building ?? "",
    roomNumber: row.room_number ?? "",
    meetingType: row.meeting_type ?? "",
    section: row.section ?? "",
    deliveryMode: row.delivery_mode ?? "",
    startTime: appleReferenceDateSeconds(row.start_time),
    endTime: appleReferenceDateSeconds(row.end_time),
    compactShowsCountdown: shouldShowCompactCountdown(row),
    compactCueID: shouldShowCompactCountdown(row) ? Math.floor(Date.now() / 1000) : 0,
    compactCueMinutes: row.alert_cue_minutes,
    compactCountdownUntil: shouldShowCompactCountdown(row) ? appleReferenceDateSeconds(row.start_time) : null,
  };
}

function contentState(row: ClassScheduleFields, showCompactCountdown: boolean) {
  return {
    courseCode: row.course_code,
    building: row.building ?? "",
    roomNumber: row.room_number ?? "",
    meetingType: row.meeting_type ?? "",
    section: row.section ?? "",
    deliveryMode: row.delivery_mode ?? "",
    startTime: appleReferenceDateSeconds(row.start_time),
    endTime: appleReferenceDateSeconds(row.end_time),
    compactShowsCountdown: showCompactCountdown,
    compactCueID: showCompactCountdown ? Math.floor(Date.now() / 1000) : 0,
    compactCueMinutes: row.alert_cue_minutes,
    compactCountdownUntil: showCompactCountdown ? appleReferenceDateSeconds(row.start_time) : null,
  };
}

function shouldShowCompactCountdown(row: ClassScheduleFields) {
  const now = Date.now();
  const startTime = new Date(row.start_time).getTime();
  return now >= startTime - row.alert_cue_minutes * 60_000 && now < startTime;
}

function shouldSendCueUpdate(row: LiveActivityRow, now: Date) {
  if (row.push_stage !== "cue") {
    return true;
  }

  if (!row.last_push_at) {
    return true;
  }

  const lastPush = new Date(row.last_push_at).getTime();
  if (!Number.isFinite(lastPush)) {
    return true;
  }

  return now.getTime() - lastPush > 45_000;
}

function alertBody(row: ClassScheduleFields) {
  const location = [row.building, row.room_number]
    .filter((part) => part && part.trim().length > 0)
    .join(" ");

  if (location) {
    return location;
  }

  return row.delivery_mode || "Open UTime for details";
}

function displayCourseCode(courseCode: string) {
  const match = courseCode.trim().match(/^[A-Z]{3}\d{3}/);
  return match ? match[0] : courseCode;
}

async function createProviderToken(config: ReturnType<typeof readConfig>) {
  const header = base64URLJSON({ alg: "ES256", kid: config.apnsKeyID });
  const claims = base64URLJSON({
    iss: config.apnsTeamID,
    iat: Math.floor(Date.now() / 1000),
  });
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(config.apnsPrivateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

function appleReferenceDateSeconds(value: string) {
  return new Date(value).getTime() / 1000 - 978_307_200;
}

function dbHeaders(config: ReturnType<typeof readConfig>) {
  return {
    "apikey": config.secretKey,
    "Authorization": `Bearer ${config.secretKey}`,
  };
}

function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
}

function pemToArrayBuffer(pem: string) {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return bytes.buffer;
}

function base64URLJSON(value: unknown) {
  return base64URL(new TextEncoder().encode(JSON.stringify(value)));
}

function base64URL(bytes: Uint8Array) {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
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
