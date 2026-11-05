-- Peengo: temiz başlangıç (2026-11-05, Arena açılışı)
--  * Bugüne kadar kesilen bütün canavarlar geri alınır, avda giden dakikalar duvara geri döner.
--  * Arena sıfırlanır: petler, savaşlar, eşyalar silinir; coinler sıfırlanır (herkes ilk girişinde günlük 10 coin alır).
--  * Önce her şey dışarıdan erişilemeyen "yedek" şemasına kopyalanır; gerekirse geri yüklenebilir.
-- Bu dosya BİR KERE çalıştırılır. İkinci kez çalıştırılırsa yedek tabloları zaten var olduğu için hata verir ve hiçbir şey değişmez.

create schema if not exists yedek;
revoke all on schema yedek from public, anon, authenticated;

create table yedek.hunts_20261105   as select * from public.hunts;
create table yedek.marks_20261105   as select * from public.marks;
create table yedek.pets_20261105    as select * from public.pets;
create table yedek.items_20261105   as select * from public.items;
create table yedek.battles_20261105 as select * from public.battles;
create table yedek.coins_20261105   as select id, name, coins, coin_day, last_attack_at from public.players;

-- Avda giden dakikaları geri getir (o dakikayı sonradan yeniden doldurduysa olduğu gibi kalır)
insert into public.marks (player_id, minute, at)
select distinct on (h.player_id, m.minute) h.player_id, m.minute, h.at
  from public.hunts h cross join unnest(h.removed) as m(minute)
 where m.minute is not null
 order by h.player_id, m.minute, h.at
on conflict do nothing;

-- Arena ve avlar sıfırdan
delete from public.items;
delete from public.battles;
delete from public.pets;
delete from public.hunts;
update public.players set coins = 0, coin_day = null, last_attack_at = null;

select p.name as oyuncu,
       (select count(*) from yedek.hunts_20261105 h where h.player_id = p.id) as geri_alinan_av,
       (select count(*) from public.marks m where m.player_id = p.id)
         - (select count(*) from yedek.marks_20261105 m where m.player_id = p.id) as geri_gelen_dakika,
       (select count(*) from public.marks m where m.player_id = p.id) as simdiki_dakika
  from public.players p
 where not p.is_admin
 order by 2 desc, 1;
