-- Peengo: sohbet artık hiç sıfırlanmaz. Mesajlar sadece sahibi (ya da yönetici) silerse gider.
--  * Pazar 00:00'daki otomatik silme işi kaldırılır.
--  * Mesaj/fotoğraf gönderirken eski haftayı silen kısım etkisiz hale gelir: chat_week_start() artık
--    "en baştan" (-infinity) döner, yani "bundan eski mesajları sil" adımı hiçbir mesajı kapsamaz.
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

create or replace function public.chat_week_start()
returns timestamptz language sql stable set search_path = public as $$
  select '-infinity'::timestamptz
$$;

do $$ begin
  perform cron.unschedule('peengo-pazar-sohbet-sifirlama');
exception when others then
  raise notice 'Pazar silme işi zaten yok (%).', sqlerrm;
end $$;

select (select count(*) from cron.job where jobname = 'peengo-pazar-sohbet-sifirlama') as pazar_silme_isi,
       public.chat_week_start() as silme_siniri,
       (select count(*) from public.messages) as mesaj_sayisi,
       (select min(at) from public.messages) as en_eski_mesaj;
