alter table live_activities
add column if not exists schedule_id uuid,
add column if not exists updated_at timestamptz not null default now();

alter table class_schedules
add column if not exists started_at timestamptz,
add column if not exists ended_at timestamptz;

create index if not exists live_activities_install_start_idx
on live_activities (install_id, start_time);

create index if not exists class_schedules_push_stage_start_idx
on class_schedules (push_stage, start_time);
