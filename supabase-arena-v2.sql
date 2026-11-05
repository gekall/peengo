-- Peengo Arena v2
--  * Av döngüsü 10 canavar: her turun 5. ve 10. avı boss, 10 avdan sonra başa döner.
--  * Sv 11-13 (Kanalizasyon Ejderi, Rögar Krakeni, Sifonların Efendisi) avda çıkmaz, sadece birleştirmeyle elde edilir.
--  * Birleştirme şansı Sv 1'de %90, her seviyede %1 azalır (Sv 12 → 13: %79).
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir (seviye taşıma bir kere yapılır).
--
-- Seviye sırası (Sv = tier + 1):
--   1 Kanalizasyon Faresi   2 Tuvalet Örümceği   3 Lavabo Mikrobu   4 Gider Yılanı   5 Rögar Kurbağası (BOSS)
--   6 Sifon Yarasası        7 Klozet Yengeci     8 Fayans Hamamböceği   9 Tıkanık Hortlak   10 Kireç Golemi (BOSS)
--   11 Kanalizasyon Ejderi  12 Rögar Krakeni     13 Sifonların Efendisi   (efsaneler, sadece birleştirme)

create table if not exists public.arena_meta (k text primary key, v text, at timestamptz not null default now());
alter table public.arena_meta enable row level security;
revoke all on public.arena_meta from anon, authenticated;

-- Kaçıncı av hangi pet: turun n. avı = Sv n
create or replace function public.mob_tier(p_no int, p_boss boolean) returns int language sql immutable as $$
  select (p_no - 1) % 10 $$;

-- Var olan petleri ve savaş kayıtlarını yeni sıraya taşı (canavar aynı kalır, seviyesi değişir). Bir kere çalışır.
do $$
declare m int[] := array[0, 1, 2, 3, 5, 6, 7, 8, 4, 9, 10, 11, 12];
begin
  if not exists (select 1 from public.arena_meta where k = 'tier_v2') then
    update public.pets set tier = m[tier + 1];
    update public.battles b set
      a_team = (select coalesce(jsonb_agg(jsonb_set(e, '{t}', to_jsonb(m[(e->>'t')::int + 1])) order by o), '[]'::jsonb)
                  from jsonb_array_elements(b.a_team) with ordinality x(e, o)),
      d_team = (select coalesce(jsonb_agg(jsonb_set(e, '{t}', to_jsonb(m[(e->>'t')::int + 1])) order by o), '[]'::jsonb)
                  from jsonb_array_elements(b.d_team) with ordinality x(e, o));
    insert into public.arena_meta (k, v) values ('tier_v2', 'tasindi');
  end if;
end $$;

-- Canavar avı: her 5. av boss (2 dakika), diğerleri 1 dakika
create or replace function public.hunt(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_no int; v_boss boolean; v_cost int; v_have int; v_removed smallint[];
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  perform pg_advisory_xact_lock(hashtext('hunt:' || v_pid::text));

  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  v_boss := v_no % 5 = 0;
  v_cost := case when v_boss then 2 else 1 end;

  select count(*) into v_have from marks where player_id = v_pid;
  if v_have < v_cost then
    raise exception 'Bu canavar için duvarında en az % dakika olmalı. Biraz daha işe!', v_cost;
  end if;

  with pick as (
    select minute from marks where player_id = v_pid order by random() limit v_cost
  ), del as (
    delete from marks m using pick
     where m.player_id = v_pid and m.minute = pick.minute
    returning m.minute
  )
  select array_agg(minute order by minute) into v_removed from del;

  insert into hunts(player_id, mob_no, boss, removed) values (v_pid, v_no, v_boss, v_removed);
  return json_build_object('mob_no', v_no, 'boss', v_boss, 'removed', v_removed, 'kills', v_no);
end $$;

-- Birleştir: şans Sv 1'de %90, her seviyede %1 azalır
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
  v_chance := 90 - v_tier;
  v_ok := random() * 100 < v_chance;
  if v_ok then
    insert into pets (owner, tier, slot, src) values (v_pid, v_tier + 1, least(v_slot1, v_slot2), 'birlesim')
      returning id into v_new;
  end if;
  return json_build_object('ok', v_ok, 'tier', v_tier, 'pet', v_new, 'items_back', v_items, 'chance', v_chance);
end $$;

revoke execute on function public.arena_merge(uuid, bigint) from public;
grant execute on function public.arena_merge(uuid, bigint) to anon, authenticated;

select 'arena v2 hazir' as durum,
       (select v from public.arena_meta where k = 'tier_v2') as tasima,
       (select string_agg('Sv' || (tier + 1) || ':' || c, ' ' order by tier) from (select tier, count(*) c from public.pets group by tier) x) as seviye_dagilimi,
       (select count(*) from public.battles) as savas,
       position('% 5 = 0' in pg_get_functiondef('public.hunt(uuid)'::regprocedure)) > 0 as av_5te_boss;
