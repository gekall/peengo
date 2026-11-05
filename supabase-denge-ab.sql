-- Peengo dengeleme (A + B)
--  A) Yumrukla av günde en fazla 40 canavar (İstanbul günü). Dakika vererek kesmek sınırsız.
--  B) Efsane birleştirme zorlaştı: Sv10→11 %60, Sv11→12 %45, Sv12→13 %30. Sv1-10 arası aynı (%90'dan seviye başına -%1).
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

create index if not exists hunts_player_at_idx on public.hunts (player_id, at desc);

-- Bugün kaç canavar yumrukla kesildi
create or replace function public.tap_used_today(p_pid uuid) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from hunts
   where player_id = p_pid and tapped
     and (at at time zone 'Europe/Istanbul')::date = (now() at time zone 'Europe/Istanbul')::date $$;
revoke execute on function public.tap_used_today(uuid) from public, anon, authenticated;

create or replace function public.hunt_tap_status(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  return json_build_object('used', tap_used_today(v_pid), 'limit', 40);
end $$;

-- İlk vuruş: sıradaki canavar için sayaç başlar (günlük hak bittiyse başlamaz)
create or replace function public.hunt_tap_start(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_no int; v_used int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  v_used := tap_used_today(v_pid);
  if v_used >= 40 then
    raise exception 'Bugünlük yumruk hakkın bitti (40/40). Yarın yine vurabilirsin; dakika vererek kesmeye devam edebilirsin.';
  end if;
  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  update players set tap_started_at = now(), tap_mob = v_no where id = v_pid;
  return json_build_object('mob_no', v_no, 'need', case when v_no % 5 = 0 then 80 else 40 end, 'at', now(), 'used', v_used, 'limit', 40);
end $$;

-- Son vuruş: canavar dakika almadan kesilir (günde en fazla 40)
create or replace function public.hunt_tap(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_no int; v_boss boolean; v_min int; v_started timestamptz; v_mob int; v_left numeric; v_used int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  perform pg_advisory_xact_lock(hashtext('hunt:' || v_pid::text));

  v_used := tap_used_today(v_pid);
  if v_used >= 40 then
    raise exception 'Bugünlük yumruk hakkın bitti (40/40). Yarın yine vurabilirsin; dakika vererek kesmeye devam edebilirsin.';
  end if;

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
  return json_build_object('mob_no', v_no, 'boss', v_boss, 'removed', '{}'::smallint[], 'kills', v_no, 'tapped', true,
                           'used', v_used + 1, 'limit', 40);
end $$;

-- Birleştir: Sv1-10 %(90 - seviye), efsaneler %60 / %45 / %30
create or replace function public.arena_merge(p_token uuid, p_pet bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_tier int; v_slot1 smallint; v_mate bigint; v_slot2 smallint; v_items int; v_ok boolean; v_new bigint; v_chance int;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  select tier, slot into v_tier, v_slot1 from pets where id = p_pet and owner = v_pid;
  if v_tier is null then raise exception 'Bu pet artık senin değil. Sayfayı yenile.'; end if;
  if v_tier >= 12 then raise exception 'Sifonların Efendisi en üst seviye, daha fazla birleşmez.'; end if;
  select p.id, p.slot into v_mate, v_slot2 from pets p
   where p.owner = v_pid and p.tier = v_tier and p.id <> p_pet
   order by (p.slot is not null), exists (select 1 from items i where i.pet_id = p.id), p.id
   limit 1;
  if v_mate is null then raise exception 'Birleştirmek için aynı petten bir tane daha lazım.'; end if;
  select count(*) into v_items from items where pet_id in (p_pet, v_mate);
  delete from pets where id in (p_pet, v_mate);
  v_chance := case v_tier when 9 then 60 when 10 then 45 when 11 then 30 else 90 - v_tier end;
  v_ok := random() * 100 < v_chance;
  if v_ok then
    insert into pets (owner, tier, slot, src) values (v_pid, v_tier + 1, least(v_slot1, v_slot2), 'birlesim')
      returning id into v_new;
  end if;
  return json_build_object('ok', v_ok, 'tier', v_tier, 'pet', v_new, 'items_back', v_items, 'chance', v_chance);
end $$;

revoke execute on function public.hunt_tap_status(uuid), public.hunt_tap_start(uuid), public.hunt_tap(uuid), public.arena_merge(uuid, bigint) from public;
grant execute on function public.hunt_tap_status(uuid), public.hunt_tap_start(uuid), public.hunt_tap(uuid), public.arena_merge(uuid, bigint) to anon, authenticated;

select 'denge A+B hazir' as durum,
       (select string_agg(p.name || ':' || public.tap_used_today(p.id), ' ' order by p.name) from public.players p where not p.is_admin) as bugun_yumruk_av;
