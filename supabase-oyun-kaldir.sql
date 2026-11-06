-- Peengo: canavar avı ve Arena kapatıldı (2026-11-06). Oyun ayrı projeye (Peedle) taşınıyor; Peengo sadece dakika duvarı.
--  * Avda dakika verilerek kesilen canavarların dakikaları duvara geri döner
--    (o dakikayı sonradan yeniden doldurduysa olduğu gibi kalır).
--  * Oyun verileri (avlar, petler, eşyalar, savaşlar, coinler) SİLİNMEZ; ayrıca dışarıdan erişilemeyen "yedek" şemasına kopyalanır.
--  * Oyunun sunucu fonksiyonları kapatılır: uygulamanın eski bir sürümü açık kalsa bile av/arena çağrıları çalışmaz.
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir: iade ve yedek bir kere yapılır.

create schema if not exists yedek;
revoke all on schema yedek from public, anon, authenticated;

do $$
begin
  if exists (select 1 from public.arena_meta where k = 'oyun_kaldirildi') then
    raise notice 'Oyun zaten kaldırılmış, iade tekrar yapılmadı.';
    return;
  end if;

  create table if not exists yedek.hunts_20261106   as select * from public.hunts;
  create table if not exists yedek.marks_20261106   as select * from public.marks;
  create table if not exists yedek.pets_20261106    as select * from public.pets;
  create table if not exists yedek.items_20261106   as select * from public.items;
  create table if not exists yedek.battles_20261106 as select * from public.battles;
  create table if not exists yedek.players_oyun_20261106 as
    select id, name, coins, coin_day, last_attack_at, arena_off_until, arena_motto, tap_started_at, tap_mob from public.players;
  alter table yedek.hunts_20261106 enable row level security;
  alter table yedek.marks_20261106 enable row level security;
  alter table yedek.pets_20261106 enable row level security;
  alter table yedek.items_20261106 enable row level security;
  alter table yedek.battles_20261106 enable row level security;
  alter table yedek.players_oyun_20261106 enable row level security;

  -- Avda giden dakikaları geri getir
  insert into public.marks (player_id, minute, at)
  select distinct on (h.player_id, m.minute) h.player_id, m.minute, h.at
    from public.hunts h cross join unnest(h.removed) as m(minute)
   where m.minute is not null
     and exists (select 1 from public.players p where p.id = h.player_id)
   order by h.player_id, m.minute, h.at
  on conflict do nothing;

  update public.players set tap_started_at = null, tap_mob = null;

  insert into public.arena_meta (k, v) values ('oyun_kaldirildi', 'dakikalar iade edildi, yedek: yedek.*_20261106');
end $$;

-- Oyun fonksiyonlarını kapat (iç yardımcılar ve tetikleyiciler dokunulmadan kalır)
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('hunt', 'hunt_tap_start', 'hunt_tap', 'hunt_tap_status',
                         'arena_state', 'arena_seen', 'arena_deck', 'arena_merge', 'arena_buy', 'arena_equip',
                         'arena_attack', 'arena_toggle', 'arena_motto', 'arena_sell', 'arena_feed', 'share_battle')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

select p.name as oyuncu,
       (select count(*) from public.marks m where m.player_id = p.id)
         - (select count(*) from yedek.marks_20261106 m where m.player_id = p.id) as geri_gelen_dakika,
       (select count(*) from public.marks m where m.player_id = p.id) as simdiki_dakika,
       (select count(*) from pg_proc pr join pg_namespace n on n.oid = pr.pronamespace
         where n.nspname = 'public'
           and pr.proname in ('hunt', 'hunt_tap_start', 'hunt_tap', 'hunt_tap_status',
                              'arena_state', 'arena_seen', 'arena_deck', 'arena_merge', 'arena_buy', 'arena_equip',
                              'arena_attack', 'arena_toggle', 'arena_motto', 'arena_sell', 'arena_feed', 'share_battle')
           and has_function_privilege('anon', pr.oid, 'execute')) as acik_kalan_oyun_fonksiyonu
  from public.players p
 where not p.is_admin
 order by 2 desc, 1;
