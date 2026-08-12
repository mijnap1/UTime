alter table live_activities enable row level security;

create unique index if not exists live_activities_activity_id_key
on live_activities (activity_id);

alter table live_activities
add column if not exists push_stage text not null default 'registered',
add column if not exists last_push_at timestamptz,
add column if not exists ended_at timestamptz;
