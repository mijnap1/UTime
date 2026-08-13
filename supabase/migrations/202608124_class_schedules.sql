create table if not exists class_schedules (
  id uuid primary key default gen_random_uuid(),
  install_id text not null,
  event_uid text not null,
  course_code text not null,
  building text,
  room_number text,
  meeting_type text,
  section text,
  delivery_mode text,
  start_time timestamptz not null,
  end_time timestamptz not null,
  live_activity_lead_minutes integer not null,
  alert_cue_minutes integer not null,
  push_stage text not null default 'pending',
  activity_id text,
  last_push_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table class_schedules enable row level security;

create unique index if not exists class_schedules_install_event_uid_key
on class_schedules (install_id, event_uid);

create index if not exists class_schedules_start_time_idx
on class_schedules (start_time);

create index if not exists class_schedules_install_start_time_idx
on class_schedules (install_id, start_time);
