-- Peengo Arena: petler, ordu, sıra tabanlı savaş, günlük coin ve market
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
--
-- Kurallar:
--  * Kesilen her canavar envantere pet olarak gelir (eski avlar da bir kereye mahsus pet olur).
--  * Herkes en fazla 5 petlik ordu kurar. Ordu, sahibi çevrimdışıyken de savaşır.
--  * İstediğin oyuncuya saldırırsın (10 dk'da bir). Önce iki ordunun 1. petleri çarpışır,
--    sırayla vururlar; ölen petin yerine sıradaki çıkar. Savaşı sunucu hesaplar, kayıt tutulur.
--  * Kaybeden ordunun bütün petleri (üstlerindeki eşyalarla) kazananın envanterine geçer, kazanan +5 coin.
--  * Aynı seviyeden 2 pet birleşir: %70 bir üst seviye pet, %30 ikisi de gider.
--  * Her gün ilk girişte 10 coin. Market: kılıç (saldırı +%) ve zırh (can +%).

alter table public.players add column if not exists coins int not null default 0;
alter table public.players add column if not exists coin_day date;
alter table public.players add column if not exists last_attack_at timestamptz;

-- Pet istatistikleri (13 seviye: 9 canavar + 4 boss). index.html'deki PET_HP / PET_ATK ile aynı olmalı.
create or replace function public.pet_hp(t int) returns int language sql immutable as $$
  select (array[30,38,47,59,73,92,114,143,179,224,279,349,437])[t + 1] $$;
create or replace function public.pet_atk(t int) returns int language sql immutable as $$
  select (array[8,10,12,15,18,23,28,36,45,56,70,87,109])[t + 1] $$;
-- Market eşyaları: k = kılıç (saldırı yüzdesi), z = zırh (can yüzdesi)
create or replace function public.item_pct(c text) returns int language sql immutable as $$
  select case c when 'k1' then 20 when 'k2' then 40 when 'k3' then 70
                when 'z1' then 20 when 'z2' then 40 when 'z3' then 70 else 0 end $$;
create or replace function public.item_price(c text) returns int language sql immutable as $$
  select case c when 'k1' then 10 when 'k2' then 25 when 'k3' then 60
                when 'z1' then 10 when 'z2' then 25 when 'z3' then 60 end $$;
-- Kaçıncı av hangi canavar: her 10. av boss (4 boss sırayla), diğerleri 9 canavar sırayla
create or replace function public.mob_tier(p_no int, p_boss boolean) returns int language sql immutable as $$
  select case when p_boss then 9 + ((p_no / 10 - 1) % 4) else (p_no - 1) % 10 end $$;

create table if not exists public.pets (
  id bigint generated always as identity primary key,
  owner uuid not null references public.players(id) on delete cascade,
  tier smallint not null check (tier between 0 and 12),
  slot smallint check (slot between 1 and 5),
  src text not null default 'av',
  at timestamptz not null default now()
);
create index if not exists pets_owner_idx on public.pets (owner);
create unique index if not exists pets_owner_slot_idx on public.pets (owner, slot) where slot is not null;

create table if not exists public.items (
  id bigint generated always as identity primary key,
  owner uuid not null references public.players(id) on delete cascade,
  code text not null check (code in ('k1','k2','k3','z1','z2','z3')),
  pet_id bigint references public.pets(id) on delete set null,
  at timestamptz not null default now()
);
create index if not exists items_owner_idx on public.items (owner);
create unique index if not exists items_pet_kind_idx on public.items (pet_id, (left(code, 1))) where pet_id is not null;

create table if not exists public.battles (
  id bigint generated always as identity primary key,
  attacker uuid not null references public.players(id) on delete cascade,
  defender uuid not null references public.players(id) on delete cascade,
  a_team jsonb not null,
  d_team jsonb not null,
  starter smallint not null,
  log jsonb not null,
  attacker_won boolean not null,
  captured int not null default 0,
  coins int not null default 0,
  seen boolean not null default false,
  at timestamptz not null default now()
);
create index if not exists battles_at_idx on public.battles (at desc);
create index if not exists battles_unseen_idx on public.battles (defender) where not seen;

alter table public.pets    enable row level security;
alter table public.items   enable row level security;
alter table public.battles enable row level security;
drop policy if exists "pets herkes okur" on public.pets;
create policy "pets herkes okur" on public.pets for select to anon, authenticated using (true);
drop policy if exists "items herkes okur" on public.items;
create policy "items herkes okur" on public.items for select to anon, authenticated using (true);
drop policy if exists "battles herkes okur" on public.battles;
create policy "battles herkes okur" on public.battles for select to anon, authenticated using (true);
revoke insert, update, delete on public.pets, public.items, public.battles from anon, authenticated;
grant select on public.pets, public.items, public.battles to anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.battles;
exception when others then null;
end $$;

-- Av = pet. Eski avlar bir kereye mahsus pete dönüşür; yeni avlarda tetikleyici ekler.
alter table public.hunts add column if not exists pet_given boolean not null default false;
alter table public.hunts alter column pet_given set default true;
insert into public.pets (owner, tier, src, at)
  select h.player_id, public.mob_tier(h.mob_no, h.boss), 'av', h.at
    from public.hunts h where not h.pet_given order by h.id;
update public.hunts set pet_given = true where not pet_given;

create or replace function public.hunt_pet()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.pet_given then
    insert into pets (owner, tier, src) values (new.player_id, mob_tier(new.mob_no, new.boss), 'av');
  end if;
  return new;
end $$;
drop trigger if exists hunts_pet on public.hunts;
create trigger hunts_pet after insert on public.hunts for each row execute function public.hunt_pet();

-- Oturumdan oyuncu (yönetici arenada savaşamaz)
create or replace function public.arena_pid(p_token uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_pid uuid; v_admin boolean;
begin
  select p.id, p.is_admin into v_pid, v_admin
    from sessions s join players p on p.id = s.player_id where s.token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if v_admin then raise exception 'Yönetici hesabı arenada savaşamaz, sadece izler.'; end if;
  return v_pid;
end $$;

-- Bir oyuncunun ordusu, ekipman bonuslarıyla, slot sırasına göre
create or replace function public.arena_team(p_owner uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 't', p.tier, 'k', k.code, 'z', z.code,
           'hp',  round(pet_hp(p.tier)  * (100 + item_pct(z.code)) / 100.0)::int,
           'atk', round(pet_atk(p.tier) * (100 + item_pct(k.code)) / 100.0)::int) order by p.slot), '[]'::jsonb)
    from pets p
    left join items k on k.pet_id = p.id and left(k.code, 1) = 'k'
    left join items z on z.pet_id = p.id and left(z.code, 1) = 'z'
   where p.owner = p_owner and p.slot is not null
$$;

-- Arena durumu: coin (günün ilk girişinde +10), saldırı bekleme süresi, görülmemiş savaşlar
create or replace function public.arena_state(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_admin boolean; v_coins int; v_day date; v_last timestamptz; v_unseen int; v_gift int := 0;
  v_today date := (now() at time zone 'Europe/Istanbul')::date;
begin
  select p.id, p.is_admin, p.coins, p.coin_day, p.last_attack_at
    into v_pid, v_admin, v_coins, v_day, v_last
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
   for update of p;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if not v_admin and (v_day is null or v_day < v_today) then
    v_gift := 10;
    update players set coins = coins + v_gift, coin_day = v_today where id = v_pid returning coins into v_coins;
  end if;
  select count(*) into v_unseen from battles where defender = v_pid and not seen;
  return json_build_object('id', v_pid, 'admin', v_admin, 'coins', v_coins, 'gift', v_gift, 'unseen', v_unseen,
    'cooldown_until', v_last + interval '10 minutes', 'now', now());
end $$;

create or replace function public.arena_seen(p_token uuid)
returns int language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_n int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  update battles set seen = true where defender = v_pid and not seen;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Orduyu kaydet: en fazla 5 pet, verilen sıra = savaşa çıkış sırası
create or replace function public.arena_deck(p_token uuid, p_pets bigint[])
returns int language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_n int; v_ok int;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  p_pets := coalesce(p_pets, '{}');
  v_n := coalesce(cardinality(p_pets), 0);
  if v_n > 5 then raise exception 'Orduna en fazla 5 pet koyabilirsin.'; end if;
  if (select count(distinct x) from unnest(p_pets) x) <> v_n then raise exception 'Aynı peti iki kez seçemezsin.'; end if;
  select count(*) into v_ok from pets where owner = v_pid and id = any(p_pets);
  if v_ok <> v_n then raise exception 'Bu petlerden bazıları artık senin değil. Sayfayı yenile.'; end if;
  update pets set slot = null where owner = v_pid and slot is not null;
  update pets p set slot = x.ord from unnest(p_pets) with ordinality as x(id, ord) where p.id = x.id;
  return v_n;
end $$;

-- Birleştir: bu pet + aynı seviyeden bir tane daha. %70 bir üst seviye, %30 ikisi de gider.
-- Eşi seçerken önce ordu dışındaki ve eşyasız petler kullanılır. Üstlerindeki eşyalar çantaya döner.
create or replace function public.arena_merge(p_token uuid, p_pet bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_tier int; v_slot1 smallint; v_mate bigint; v_slot2 smallint; v_items int; v_ok boolean; v_new bigint;
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
  v_ok := random() < 0.7;
  if v_ok then
    insert into pets (owner, tier, slot, src) values (v_pid, v_tier + 1, least(v_slot1, v_slot2), 'birlesim')
      returning id into v_new;
  end if;
  return json_build_object('ok', v_ok, 'tier', v_tier, 'pet', v_new, 'items_back', v_items);
end $$;

create or replace function public.arena_buy(p_token uuid, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_price int; v_coins int; v_id bigint;
begin
  v_pid := arena_pid(p_token);
  v_price := item_price(p_code);
  if v_price is null then raise exception 'Markette böyle bir eşya yok.'; end if;
  update players set coins = coins - v_price where id = v_pid and coins >= v_price returning coins into v_coins;
  if v_coins is null then raise exception 'Coinin yetmiyor. Bu eşya % coin.', v_price; end if;
  insert into items (owner, code) values (v_pid, p_code) returning id into v_id;
  return json_build_object('id', v_id, 'coins', v_coins);
end $$;

-- Eşya giydir (p_pet null ise çıkar). Bir pette 1 kılıç + 1 zırh olur, eskisi çantaya döner.
create or replace function public.arena_equip(p_token uuid, p_item bigint, p_pet bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_code text;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  select code into v_code from items where id = p_item and owner = v_pid;
  if v_code is null then raise exception 'Bu eşya artık senin değil. Sayfayı yenile.'; end if;
  if p_pet is null then
    update items set pet_id = null where id = p_item;
    return true;
  end if;
  if not exists (select 1 from pets where id = p_pet and owner = v_pid) then
    raise exception 'Bu pet artık senin değil. Sayfayı yenile.';
  end if;
  update items set pet_id = null where pet_id = p_pet and left(code, 1) = left(v_code, 1) and id <> p_item;
  update items set pet_id = p_pet where id = p_item;
  return true;
end $$;

-- Saldır: savaşı sunucu hesaplar, tur tur kayıt (log) döner; istemci bunu canlı gibi oynatır.
-- log satırı: [vuran taraf (0 saldıran, 1 savunan), vuran pet sırası, vurulan pet sırası, hasar, 0 normal/1 kritik/2 ıska, vurulanın kalan canı]
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
    if random() < 0.07 then
      v_dmg := 0; v_flag := 2;
    else
      v_dmg := greatest(1, round(v_atk * (0.85 + random() * 0.3))::int);
      if random() < 0.12 then v_dmg := round(v_dmg * 1.6)::int; v_flag := 1; else v_flag := 0; end if;
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

revoke execute on function public.arena_pid(uuid), public.arena_team(uuid), public.hunt_pet() from public, anon, authenticated;
revoke execute on function public.arena_state(uuid), public.arena_seen(uuid), public.arena_deck(uuid, bigint[]),
  public.arena_merge(uuid, bigint), public.arena_buy(uuid, text), public.arena_equip(uuid, bigint, bigint),
  public.arena_attack(uuid, uuid) from public;
grant execute on function public.arena_state(uuid), public.arena_seen(uuid), public.arena_deck(uuid, bigint[]),
  public.arena_merge(uuid, bigint), public.arena_buy(uuid, text), public.arena_equip(uuid, bigint, bigint),
  public.arena_attack(uuid, uuid) to anon, authenticated;

select 'arena hazir' as durum,
       (select count(*) from public.pets) as toplam_pet,
       (select string_agg(pp.name || ':' || c, ', ' order by c desc)
          from (select owner, count(*) c from public.pets group by owner) x
          join public.players pp on pp.id = x.owner) as kimde_kac_pet;
