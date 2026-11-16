-- Peengo: günlük sıralama. Bugün (Türkiye saatiyle 00:00'dan beri) kim kaç kez işedi, kaç yeni dakika doldurdu.
-- Her gece 00:00'da kendiliğinden sıfırlanır. Saatler yine gizli, sadece sayılar görünür.
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

create or replace view public.pee_counts as
  select player_id,
         count(*)::int as last24,
         count(*) filter (where at >= date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul')::int as today,
         count(*) filter (where is_new and at >= date_trunc('day', now() at time zone 'Europe/Istanbul') at time zone 'Europe/Istanbul')::int as today_new
    from public.pees
   where at > now() - interval '24 hours'
   group by player_id;
grant select on public.pee_counts to anon, authenticated;

select pl.name as oyuncu, coalesce(c.today, 0) as bugun_iseme, coalesce(c.today_new, 0) as bugun_yeni_dakika, coalesce(c.last24, 0) as son_24_saat
  from public.players pl left join public.pee_counts c on c.player_id = pl.id
 where not pl.is_admin
 order by 2 desc, 3 desc, 1;
