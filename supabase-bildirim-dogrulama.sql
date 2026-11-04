-- Peengo hatırlatıcılar: zamanlayıcı fonksiyonu doğrulanmış (anon anahtarlı) çağırsın
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- anon_key sütununu peengo-push fonksiyonu kendisi doldurur (Supabase'in verdiği herkese açık anahtar).

alter table public.push_config add column if not exists anon_key text;

select cron.schedule('peengo-gunaydin', '0 4 * * *', $c$
  select net.http_post(
    url := 'https://klaeugeeyltdgjexfhfk.supabase.co/functions/v1/peengo-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select anon_key from public.push_config where id = 1),
      'x-peengo-cron', (select cron_secret from public.push_config where id = 1)),
    body := '{"kind":"morning"}'::jsonb,
    timeout_milliseconds := 30000)
$c$);

select cron.schedule('peengo-gece-alarm', '0 17 * * *', $c$
  select net.http_post(
    url := 'https://klaeugeeyltdgjexfhfk.supabase.co/functions/v1/peengo-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select anon_key from public.push_config where id = 1),
      'x-peengo-cron', (select cron_secret from public.push_config where id = 1)),
    body := '{"kind":"evening"}'::jsonb,
    timeout_milliseconds := 30000)
$c$);
