-- Peengo Arena dengeleme: güç eğrisi düzleşti, savaşta şans payı genişledi
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
--  * Eskiden Sv13, Sv1'in ~14 katı can/saldırıya sahipti (toplam güç ~200 kat). Artık her seviye +2 can, ~+0.75 saldırı:
--    Sv1 = 34 can / 14 saldırı, Sv13 = 58 can / 23 saldırı.
--  * Hasar ±%35 oynar (eskiden ±%15), kritik %18 ihtimalle x1.75 (eskiden %12, x1.6), ıska %10 (eskiden %7).
--  * index.html'deki PET_HP / PET_ATK aynı değerlerle güncellendi. Eski savaş kayıtları kendi değerleriyle oynatılır.

create or replace function public.pet_hp(t int) returns int language sql immutable as $$
  select (array[34,36,38,40,42,44,46,48,50,52,54,56,58])[t + 1] $$;
create or replace function public.pet_atk(t int) returns int language sql immutable as $$
  select (array[14,15,16,16,17,18,18,19,20,21,22,22,23])[t + 1] $$;

create or replace function public.arena_attack(p_token uuid, p_target uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_last timestamptz; v_left int; v_tname text; v_tadmin boolean;
  a_team jsonb; d_team jsonb; a_n int; d_n int; a_cur int[]; d_cur int[];
  v_first int; v_side int; ai int := 1; di int := 1; v_steps int := 0;
  v_atk int; v_dmg int; v_flag int; v_log jsonb := '[]'::jsonb;
  v_awon boolean; v_win uuid; v_lose_ids bigint[]; v_cap int; v_bid bigint; v_at timestamptz := now();
begin
  v_pid := arena_pid(p_token);
  if p_target = v_pid then raise exception 'Kendine saldıramazsın.'; end if;
  select name, is_admin into v_tname, v_tadmin from players where id = p_target;
  if v_tname is null then raise exception 'Bu oyuncu bulunamadı.'; end if;
  if v_tadmin then raise exception 'Yöneticiye saldırılamaz.'; end if;
  if coalesce((select arena_off_until from players where id = v_pid) > now(), false) then
    raise exception 'Ordun inaktif. Saldırmak için önce Ordu sekmesinden aktif et.';
  end if;
  if coalesce((select arena_off_until from players where id = p_target) > now(), false) then
    raise exception '% ordusunu savaşa kapattı, saldırılamaz.', v_tname;
  end if;
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));

  select last_attack_at into v_last from players where id = v_pid for update;
  if v_last is not null and v_last > now() - interval '10 minutes' then
    v_left := ceil(extract(epoch from (v_last + interval '10 minutes' - now())))::int;
    raise exception 'Ordun dinleniyor. % dk % sn sonra tekrar saldırabilirsin.', v_left / 60, v_left % 60;
  end if;

  a_team := arena_team(v_pid);
  d_team := arena_team(p_target);
  a_n := jsonb_array_length(a_team);
  d_n := jsonb_array_length(d_team);
  if a_n = 0 then raise exception 'Önce ordunu kur: Ordu sekmesinden en az 1 pet seç.'; end if;
  if d_n = 0 then raise exception '% şu an ordusuz, saldıracak kimse yok.', v_tname; end if;
  a_cur := array(select (e->>'hp')::int from jsonb_array_elements(a_team) with ordinality x(e, o) order by o);
  d_cur := array(select (e->>'hp')::int from jsonb_array_elements(d_team) with ordinality x(e, o) order by o);

  v_first := floor(random() * 2)::int;
  v_side := v_first;
  loop
    v_steps := v_steps + 1;
    v_atk := case when v_side = 0 then (a_team->(ai - 1)->>'atk')::int else (d_team->(di - 1)->>'atk')::int end;
    if random() < 0.10 then
      v_dmg := 0; v_flag := 2;
    else
      v_dmg := greatest(1, round(v_atk * (0.65 + random() * 0.7))::int);
      if random() < 0.18 then v_dmg := round(v_dmg * 1.75)::int; v_flag := 1; else v_flag := 0; end if;
    end if;

    if v_side = 0 then
      d_cur[di] := greatest(0, d_cur[di] - v_dmg);
      v_log := v_log || jsonb_build_array(jsonb_build_array(0, ai - 1, di - 1, v_dmg, v_flag, d_cur[di]));
      if d_cur[di] = 0 then
        di := di + 1;
        if di > d_n then v_awon := true; exit; end if;
      end if;
    else
      a_cur[ai] := greatest(0, a_cur[ai] - v_dmg);
      v_log := v_log || jsonb_build_array(jsonb_build_array(1, di - 1, ai - 1, v_dmg, v_flag, a_cur[ai]));
      if a_cur[ai] = 0 then
        ai := ai + 1;
        if ai > a_n then v_awon := false; exit; end if;
      end if;
    end if;
    v_side := 1 - v_side;

    if v_steps >= 400 then
      -- çok uzarsa kalan can yüzdesi yüksek olan kazanır
      v_awon := (select coalesce(sum(x), 0) from unnest(a_cur) x)::numeric / (select sum((e->>'hp')::int) from jsonb_array_elements(a_team) e)
             >= (select coalesce(sum(x), 0) from unnest(d_cur) x)::numeric / (select sum((e->>'hp')::int) from jsonb_array_elements(d_team) e);
      exit;
    end if;
  end loop;

  v_win := case when v_awon then v_pid else p_target end;
  v_lose_ids := array(select (e->>'id')::bigint from jsonb_array_elements(case when v_awon then d_team else a_team end) e);
  v_cap := coalesce(cardinality(v_lose_ids), 0);
  update pets set owner = v_win, slot = null, src = 'savas', at = now() where id = any(v_lose_ids);
  update items set owner = v_win where pet_id = any(v_lose_ids);
  update players set coins = coins + 5 where id = v_win;
  update players set last_attack_at = now() where id = v_pid;

  insert into battles (attacker, defender, a_team, d_team, starter, log, attacker_won, captured, coins, at)
    values (v_pid, p_target, a_team, d_team, v_first, v_log, v_awon, v_cap, 5, v_at)
    returning id into v_bid;
  if random() < 0.05 then delete from battles where at < now() - interval '60 days'; end if;

  return json_build_object('id', v_bid, 'attacker', v_pid, 'defender', p_target, 'a_team', a_team, 'd_team', d_team,
    'starter', v_first, 'log', v_log, 'attacker_won', v_awon, 'captured', v_cap, 'coins', 5, 'seen', false, 'at', v_at,
    'cooldown_until', now() + interval '10 minutes');
end $$;

select 'denge hazir' as durum, public.pet_hp(0) as sv1_can, public.pet_atk(0) as sv1_sald, public.pet_hp(12) as sv13_can, public.pet_atk(12) as sv13_sald,
       position('0.65 + random() * 0.7' in pg_get_functiondef('public.arena_attack(uuid,uuid)'::regprocedure)) > 0 as yeni_sans;
