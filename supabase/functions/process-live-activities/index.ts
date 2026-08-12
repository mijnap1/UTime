const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-utime-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type LiveActivityRow = {
  activity_id: string;
  activity_token: string;
  course_code: string;
  building: string | null;
  room_number: string | null;
  meeting_type: string | null;
  section: string | null;
  delivery_mode: string | null;
  start_time: string;
  end_time: string;
  alert_cue_minutes: number;
  push_stage: string | null;
  last_push_at: string | null;
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
    const rows = await fetchActiveRows(config);
    const now = new Date();

    let updated = 0;
    let ended = 0;

    for (const row of rows) {
      const startTime = new Date(row.start_time);
      const cueStart = new Date(startTime.getTime() - row.alert_cue_minutes * 60_000);

      if (now >= startTime) {
        await sendLiveActivityPush(config, row, "end");
        await markStage(config, row.activity_id, "ended");
        ended += 1;
        continue;
      }

      if (now >= cueStart && shouldSendCueUpdate(row, now)) {
        await sendLiveActivityPush(config, row, "update");
        await markStage(config, row.activity_id, "cue");
        updated += 1;
      }
    }

    return json({ ok: true, checked: rows.length, updated, ended });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(message);
    return json({ ok: false, error: message }, 500);
  }
});

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

async function markStage(
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

function contentState(row: LiveActivityRow, showCompactCountdown: boolean) {
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
