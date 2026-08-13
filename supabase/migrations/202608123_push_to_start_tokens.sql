create table if not exists push_to_start_tokens (
  install_id text primary key,
  push_to_start_token text not null,
  updated_at timestamptz not null default now()
);

alter table push_to_start_tokens enable row level security;
