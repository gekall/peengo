-- Peengo Arena güncellemesi: kahramanlar (Sv14-40), süreli eşyalar (kritik / can yenileme), yeni satış fiyatları
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
--
-- Kahramanlar: iki Sv13 birleşince %25 ihtimalle Sv14 kahraman çıkar. Kahramanlar birleşmez; pet yedirerek
--   seviye atlar (pet başına XP = petin seviyesi). Sv L → L+1 için 40 × (L − 13) XP gerekir. En üst Sv40.
--   Kahramanlar savaşta kaybedilse de ele geçirilmez.
-- Eşyalar: kılıç kritik ihtimali verir (+%8/+%15/+%25), zırh her turda can yeniler (+2/+3/+5).
--   Süreleri satın alındığı andan başlar: 1. kademe 1 gün, 2. kademe 2 gün, 3. kademe 3 gün.
-- Satış: Sv1-2 0,1 · Sv3-4 0,2 · Sv5 0,4 · Sv6-7 0,3 · Sv8 0,4 · Sv9 0,5 · Sv10 1 · Sv11 3 · Sv12 12 · Sv13 70 · kahraman 80+.

alter table public.pets drop constraint if exists pets_tier_check;
alter table public.pets add constraint pets_tier_check check (tier between 0 and 39);
alter table public.pets add column if not exists xp int not null default 0;
alter table public.items add column if not exists expires_at timestamptz;

create or replace function public.pet_hp(t int) returns int language sql immutable as $$
  select (array[34,36,38,40,42,44,46,48,50,52,54,56,58,59,61,62,64,65,67,68,70,71,73,74,76,77,79,80,82,83,85,86,88,89,91,92,94,95,97,98])[t + 1] $$;
create or replace function public.pet_atk(t int) returns int language sql immutable as $$
  select (array[14,15,16,16,17,18,18,19,20,21,22,22,23,23,24,24,25,25,26,26,27,27,28,28,29,29,30,30,31,31,32,32,33,33,34,34,35,35,36,36])[t + 1] $$;
create or replace function public.pet_price(t int) returns numeric language sql immutable as $$
  select (array[0.1,0.1,0.2,0.2,0.4,0.3,0.3,0.4,0.5,1.0,3,12,70,80,85,90,95,100,105,110,115,120,125,130,135,140,145,150,155,160,165,170,175,180,185,190,195,200,205,210]::numeric[])[t + 1] $$;

create or replace function public.item_crit(c text) returns int language sql immutable as $$
  select case c when 'k1' then 8 when 'k2' then 15 when 'k3' then 25 else 0 end $$;
create or replace function public.item_regen(c text) returns int language sql immutable as $$
  select case c when 'z1' then 2 when 'z2' then 3 when 'z3' then 5 else 0 end $$;
create or replace function public.item_days(c text) returns int language sql immutable as $$
  select case c when 'k1' then 1 when 'z1' then 1 when 'k2' then 2 when 'z2' then 2 when 'k3' then 3 when 'z3' then 3 else 1 end $$;

-- Daha önce alınmış eşyaların süresi şimdiden başlar
update public.items set expires_at = now() + make_interval(days => public.item_days(code)) where expires_at is null;

-- Ordu: can/saldırı seviyeden, kritik ve yenileme süresi dolmamış eşyalardan
create or replace function public.arena_team(p_owner uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 't', p.tier, 'k', k.code, 'z', z.code,
           'hp', pet_hp(p.tier), 'atk', pet_atk(p.tier),
           'crit', 18 + item_crit(k.code), 'regen', item_regen(z.code)) order by p.slot), '[]'::jsonb)
    from pets p
    left join items k on k.pet_id = p.id and left(k.code, 1) = 'k' and k.expires_at > now()
    left join items z on z.pet_id = p.id and left(z.code, 1) = 'z' and z.expires_at > now()
   where p.owner = p_owner and p.slot is not null
$$;
revoke execute on function public.arena_team(uuid) from public, anon, authenticated;

create or replace function public.arena_buy(p_token uuid, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_price int; v_coins numeric; v_id bigint; v_exp timestamptz;
begin
  v_pid := arena_pid(p_token);
  v_price := item_price(p_code);
  if v_price is null then raise exception 'Markette böyle bir eşya yok.'; end if;
  update players set coins = coins - v_price where id = v_pid and coins >= v_price returning coins into v_coins;
  if v_coins is null then raise exception 'Coinin yetmiyor. Bu eşya % coin.', v_price; end if;
  delete from items where expires_at <= now();
  v_exp := now() + make_interval(days => item_days(p_code));
  insert into items (owner, code, expires_at) values (v_pid, p_code, v_exp) returning id into v_id;
  return json_build_object('id', v_id, 'coins', v_coins, 'expires_at', v_exp);
end $$;

create or replace function public.arena_equip(p_token uuid, p_item bigint, p_pet bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_code text; v_exp timestamptz;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  select code, expires_at into v_code, v_exp from items where id = p_item and owner = v_pid;
  if v_code is null then raise exception 'Bu eşya artık senin değil. Sayfayı yenile.'; end if;
  if p_pet is null then
    update items set pet_id = null where id = p_item;
    return true;
  end if;
  if v_exp is null or v_exp <= now() then raise exception 'Bu eşyanın süresi dolmuş.'; end if;
  if not exists (select 1 from pets where id = p_pet and owner = v_pid) then
    raise exception 'Bu pet artık senin değil. Sayfayı yenile.';
  end if;
  update items set pet_id = null where pet_id = p_pet and left(code, 1) = left(v_code, 1) and id <> p_item;
  update items set pet_id = p_pet where id = p_item;
  return true;
end $$;

-- Birleştir: Sv1-10 %(90 - seviye), Sv10→11 %60, Sv11→12 %45, Sv12→13 %30, Sv13→14 (kahraman) %25
create or replace function public.arena_merge(p_token uuid, p_pet bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_tier int; v_slot1 smallint; v_mate bigint; v_slot2 smallint; v_items int; v_ok boolean; v_new bigint; v_chance int;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  select tier, slot into v_tier, v_slot1 from pets where id = p_pet and owner = v_pid;
  if v_tier is null then raise exception 'Bu pet artık senin değil. Sayfayı yenile.'; end if;
  if v_tier >= 13 then raise exception 'Kahramanlar birleşmez; pet yedirerek seviye atlar.'; end if;
  select p.id, p.slot into v_mate, v_slot2 from pets p
   where p.owner = v_pid and p.tier = v_tier and p.id <> p_pet
   order by (p.slot is not null), exists (select 1 from items i where i.pet_id = p.id), p.id
   limit 1;
  if v_mate is null then raise exception 'Birleştirmek için aynı petten bir tane daha lazım.'; end if;
  select count(*) into v_items from items where pet_id in (p_pet, v_mate);
  delete from pets where id in (p_pet, v_mate);
  v_chance := case v_tier when 9 then 60 when 10 then 45 when 11 then 30 when 12 then 25 else 90 - v_tier end;
  v_ok := random() * 100 < v_chance;
  if v_ok then
    insert into pets (owner, tier, slot, src) values (v_pid, v_tier + 1, least(v_slot1, v_slot2), 'birlesim')
      returning id into v_new;
  end if;
  return json_build_object('ok', v_ok, 'tier', v_tier, 'pet', v_new, 'items_back', v_items, 'chance', v_chance);
end $$;

-- Kahramanı besle: petleri yedir, XP topla, seviye atla (Sv40'a kadar)
create or replace function public.arena_feed(p_token uuid, p_hero bigint, p_pets bigint[])
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_tier int; v_xp int; v_want int; v_n int; v_gain int; v_items int; v_from int; v_need int;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  select tier, xp into v_tier, v_xp from pets where id = p_hero and owner = v_pid;
  if v_tier is null then raise exception 'Bu kahraman artık senin değil. Sayfayı yenile.'; end if;
  if v_tier < 13 then raise exception 'Sadece kahramanlar (Sv14 ve üstü) beslenebilir.'; end if;
  if v_tier >= 39 then raise exception 'Bu kahraman zaten en üst seviyede (Sv40).'; end if;
  select count(distinct x) into v_want from unnest(coalesce(p_pets, '{}')) x where x <> p_hero;
  if v_want = 0 then raise exception 'Yedirilecek pet seçilmedi.'; end if;
  if v_want > 1000 then raise exception 'Tek seferde en fazla 1000 pet yedirebilirsin.'; end if;
  select count(*), coalesce(sum(tier + 1), 0) into v_n, v_gain
    from pets where owner = v_pid and id = any(p_pets) and id <> p_hero and tier < 13;
  if v_n <> v_want then raise exception 'Bu petlerden bazıları yedirilemez ya da artık senin değil. Sayfayı yenile.'; end if;
  select count(*) into v_items from items where pet_id = any(p_pets);
  delete from pets where owner = v_pid and id = any(p_pets) and id <> p_hero;
  v_from := v_tier;
  v_xp := coalesce(v_xp, 0) + v_gain;
  loop
    exit when v_tier >= 39;
    v_need := 40 * (v_tier - 12);
    exit when v_xp < v_need;
    v_xp := v_xp - v_need;
    v_tier := v_tier + 1;
  end loop;
  if v_tier >= 39 then v_xp := 0; end if;
  update pets set tier = v_tier, xp = v_xp where id = p_hero;
  return json_build_object('tier', v_tier, 'from', v_from, 'xp', v_xp,
    'need', case when v_tier >= 39 then null else 40 * (v_tier - 12) end,
    'gained', v_gain, 'fed', v_n, 'items_back', v_items);
end $$;

-- Saldırı: kritik ve can yenileme petin eşyasından; kahramanlar ele geçirilmez.
-- log satırı: [vuran taraf, vuran sıra, vurulan sıra, hasar, 0/1 kritik/2 ıska, vurulanın canı, vuranın yenilediği can, vuranın canı]
create or replace function public.arena_attack(p_token uuid, p_target uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_last timestamptz; v_left int; v_tname text; v_tadmin boolean;
  a_team jsonb; d_team jsonb; a_n int; d_n int; a_cur int[]; d_cur int[];
  v_first int; v_side int; ai int := 1; di int := 1; v_steps int := 0;
  v_atk int; v_crit int; v_regen int; v_max int; v_heal int; v_self int; v_dmg int; v_flag int; v_log jsonb := '[]'::jsonb;
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
    v_atk   := case when v_side = 0 then (a_team->(ai - 1)->>'atk')::int else (d_team->(di - 1)->>'atk')::int end;
    v_crit  := coalesce(case when v_side = 0 then (a_team->(ai - 1)->>'crit')::int else (d_team->(di - 1)->>'crit')::int end, 18);
    v_regen := coalesce(case when v_side = 0 then (a_team->(ai - 1)->>'regen')::int else (d_team->(di - 1)->>'regen')::int end, 0);
    v_max   := case when v_side = 0 then (a_team->(ai - 1)->>'hp')::int else (d_team->(di - 1)->>'hp')::int end;
    -- zırh: vurmadan önce can yeniler (en fazla tam cana kadar)
    v_heal := 0;
    if v_regen > 0 then
      if v_side = 0 then
        v_heal := least(v_regen, v_max - a_cur[ai]); a_cur[ai] := a_cur[ai] + v_heal; v_self := a_cur[ai];
      else
        v_heal := least(v_regen, v_max - d_cur[di]); d_cur[di] := d_cur[di] + v_heal; v_self := d_cur[di];
      end if;
    else
      v_self := case when v_side = 0 then a_cur[ai] else d_cur[di] end;
    end if;
    if random() < 0.10 then
      v_dmg := 0; v_flag := 2;
    else
      v_dmg := greatest(1, round(v_atk * (0.65 + random() * 0.7))::int);
      if random() * 100 < v_crit then v_dmg := round(v_dmg * 1.75)::int; v_flag := 1; else v_flag := 0; end if;
    end if;

    if v_side = 0 then
      d_cur[di] := greatest(0, d_cur[di] - v_dmg);
      v_log := v_log || jsonb_build_array(jsonb_build_array(0, ai - 1, di - 1, v_dmg, v_flag, d_cur[di], v_heal, v_self));
      if d_cur[di] = 0 then
        di := di + 1;
        if di > d_n then v_awon := true; exit; end if;
      end if;
    else
      a_cur[ai] := greatest(0, a_cur[ai] - v_dmg);
      v_log := v_log || jsonb_build_array(jsonb_build_array(1, di - 1, ai - 1, v_dmg, v_flag, a_cur[ai], v_heal, v_self));
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
  -- kahramanlar (Sv14+) ele geçirilmez, sahibinde kalır
  v_lose_ids := array(select (e->>'id')::bigint from jsonb_array_elements(case when v_awon then d_team else a_team end) e where (e->>'t')::int < 13);
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

revoke execute on function public.arena_feed(uuid, bigint, bigint[]) from public;
grant execute on function public.arena_feed(uuid, bigint, bigint[]), public.arena_merge(uuid, bigint),
  public.arena_buy(uuid, text), public.arena_equip(uuid, bigint, bigint) to anon, authenticated;

select 'kahraman + sureli esya hazir' as durum,
       public.pet_hp(39) as sv40_can, public.pet_atk(39) as sv40_sald, public.pet_price(12) as sv13_fiyat,
       (select count(*) from public.items where expires_at > now()) as aktif_esya,
       position('v_regen' in pg_get_functiondef('public.arena_attack(uuid,uuid)'::regprocedure)) > 0 as yeni_savas;
