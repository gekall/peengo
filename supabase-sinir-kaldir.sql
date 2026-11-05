-- Peengo: yumrukla avdaki günlük 40 canavar sınırı kaldırıldı (otomatik vuruş saniyede 1 kalır)
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

create or replace function public.hunt_tap_status(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  return json_build_object('used', tap_used_today(v_pid), 'limit', null);
end $$;

create or replace function public.hunt_tap_start(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_no int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  update players set tap_started_at = now(), tap_mob = v_no where id = v_pid;
  return json_build_object('mob_no', v_no, 'need', case when v_no % 5 = 0 then 80 else 40 end, 'at', now());
end $$;

create or replace function public.hunt_tap(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_no int; v_boss boolean; v_min int; v_started timestamptz; v_mob int; v_left numeric;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  perform pg_advisory_xact_lock(hashtext('hunt:' || v_pid::text));


  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  v_boss := v_no % 5 = 0;
  v_min := case when v_boss then 6 else 3 end;
  select tap_started_at, tap_mob into v_started, v_mob from players where id = v_pid for update;
  if v_started is null or v_mob is distinct from v_no then
    raise exception 'Vuruşların sayılmadı, bu canavara baştan vur.';
  end if;
  v_left := v_min - extract(epoch from (now() - v_started));
  if v_left > 0 then
    raise exception 'Çok hızlı vurdun! % sn sonra canavar düşer.', ceil(v_left)::int;
  end if;

  insert into hunts(player_id, mob_no, boss, removed, tapped) values (v_pid, v_no, v_boss, '{}', true);
  update players set tap_started_at = null, tap_mob = null where id = v_pid;
  return json_build_object('mob_no', v_no, 'boss', v_boss, 'removed', '{}'::smallint[], 'kills', v_no, 'tapped', true);
end $$;

select 'gunluk sinir kaldirildi' as durum,
       position('40/40' in pg_get_functiondef('public.hunt_tap(uuid)'::regprocedure)) = 0 as hunt_tap_sinirsiz,
       position('40/40' in pg_get_functiondef('public.hunt_tap_start(uuid)'::regprocedure)) = 0 as start_sinirsiz;
