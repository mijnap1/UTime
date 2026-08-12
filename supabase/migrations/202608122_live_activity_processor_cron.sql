create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

select cron.unschedule('process-live-activities-every-minute')
where exists (
  select 1
  from cron.job
  where jobname = 'process-live-activities-every-minute'
);

select cron.schedule(
  'process-live-activities-every-minute',
  '* * * * *',
  $$
  select
    net.http_post(
      url := 'https://almwdqahpisubekxipbv.supabase.co/functions/v1/process-live-activities',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-utime-cron-secret', 'utime-9k28vQp4xL7m-2026'
      ),
      body := jsonb_build_object('triggered_at', now()),
      timeout_milliseconds := 10000
    ) as request_id;
  $$
);
