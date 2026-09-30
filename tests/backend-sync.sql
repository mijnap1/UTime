-- Run after loading the migration in a transaction; always roll back.
do $$
declare installation text := 'utime-test-' || gen_random_uuid(); events jsonb; initial_id uuid; remaining integer;
begin
  events := jsonb_build_array(jsonb_build_object('event_uid','test-event','course_code','TEST',
    'start_time',now()+interval '15 minutes','end_time',now()+interval '75 minutes',
    'live_activity_lead_minutes',30,'alert_cue_minutes',5));
  perform sync_class_schedule(installation,events);
  select id into initial_id from class_schedules where install_id=installation;
  update class_schedules set push_stage='start_sent' where id=initial_id;
  perform sync_class_schedule(installation,events);
  assert (select id=initial_id and push_stage='start_sent' from class_schedules where install_id=installation), 'Retry reset delivery state';
  begin
    perform sync_class_schedule(installation,jsonb_build_array(jsonb_build_object('event_uid','broken')));
    raise exception 'Expected invalid schedule to fail';
  exception when not_null_violation then null;
  end;
  assert (select count(*)=1 from class_schedules where install_id=installation), 'Failed sync lost data';
  update class_schedules set push_stage='pending' where id=initial_id;
  assert not exists(select 1 from due_class_schedules(now()) where install_id=installation), 'Unregistered device occupied batch';
  insert into push_to_start_tokens(install_id,push_to_start_token) values (installation,'test-only');
  -- Due filtering happens in SQL, before the batch limit.
  assert exists(select 1 from due_class_schedules(now()) where install_id=installation), 'Due class missing';
  perform sync_class_schedule(installation,'[]'::jsonb);
  assert not exists(select 1 from class_schedules where install_id=installation), 'Clear did not remove schedule';
end $$;
