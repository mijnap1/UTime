-- Replace one installation's schedule atomically and retain delivery progress on retries.
create or replace function public.sync_class_schedule(p_install_id text, p_events jsonb)
returns integer language plpgsql security invoker set search_path = public as $$
declare synced integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_install_id, 0));
  -- End activities removed from the schedule (including pause/clear).
  update live_activities a set end_time = now(), updated_at = now()
  where a.install_id = p_install_id and a.push_stage <> 'ended'
    and not exists (select 1 from jsonb_to_recordset(p_events) as e(course_code text, start_time timestamptz, end_time timestamptz)
      where e.course_code = a.course_code and e.start_time = a.start_time and e.end_time = a.end_time);

  insert into class_schedules (install_id,event_uid,course_code,building,room_number,meeting_type,section,delivery_mode,
    start_time,end_time,live_activity_lead_minutes,alert_cue_minutes)
  select p_install_id,e.event_uid,e.course_code,e.building,e.room_number,e.meeting_type,e.section,e.delivery_mode,
    e.start_time,e.end_time,e.live_activity_lead_minutes,e.alert_cue_minutes
  from jsonb_to_recordset(p_events) as e(event_uid text,course_code text,building text,room_number text,
    meeting_type text,section text,delivery_mode text,start_time timestamptz,end_time timestamptz,
    live_activity_lead_minutes integer,alert_cue_minutes integer)
  on conflict (install_id,event_uid) do update set
    course_code=excluded.course_code,building=excluded.building,room_number=excluded.room_number,
    meeting_type=excluded.meeting_type,section=excluded.section,delivery_mode=excluded.delivery_mode,
    start_time=excluded.start_time,end_time=excluded.end_time,
    live_activity_lead_minutes=excluded.live_activity_lead_minutes,alert_cue_minutes=excluded.alert_cue_minutes,
    updated_at=now();
  get diagnostics synced = row_count;

  delete from class_schedules s where s.install_id = p_install_id
    and not exists (select 1 from jsonb_array_elements(p_events) e where e->>'event_uid' = s.event_uid);

  update live_activities a set alert_cue_minutes=s.alert_cue_minutes,building=s.building,room_number=s.room_number,
    updated_at=now()
  from class_schedules s where s.install_id=p_install_id and a.install_id=s.install_id
    and a.course_code=s.course_code and a.start_time=s.start_time and a.end_time=s.end_time;
  return synced;
end $$;
revoke all on function public.sync_class_schedule(text,jsonb) from public, anon, authenticated;
grant execute on function public.sync_class_schedule(text,jsonb) to service_role;

-- Apply each row's lead time before limiting the batch.
create or replace function public.due_class_schedules(p_now timestamptz)
returns setof public.class_schedules language sql stable security invoker set search_path=public as $$
  select s.* from class_schedules s where push_stage='pending' and end_time>p_now
    and exists (select 1 from push_to_start_tokens t where t.install_id=s.install_id)
    and start_time - make_interval(mins=>live_activity_lead_minutes) <= p_now
  order by last_push_at nulls first, start_time limit 100;
$$;
revoke all on function public.due_class_schedules(timestamptz) from public, anon, authenticated;
grant execute on function public.due_class_schedules(timestamptz) to service_role;
