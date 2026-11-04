-- Peengo günlük hatırlatıcılar (Web Push)
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Not: bildirimleri "peengo-push" adlı Edge Function gönderir (supabase/functions/peengo-push).

create extension if not exists pg_net;

-- Ayarlar: bildirim anahtarları fonksiyon tarafından ilk çalışmada üretilir; zamanlayıcı şifresi burada üretilir
create table if not exists public.push_config (
  id int primary key check (id = 1),
  vapid_public text,
  vapid_private text,
  cron_secret text not null default encode(extensions.gen_random_bytes(24), 'hex')
);
insert into public.push_config(id) values (1) on conflict do nothing;
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

-- Bildirim abonelikleri (her cihaz bir satır)
create table if not exists public.push_subs (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

create or replace function public.push_subscribe(p_token uuid, p_endpoint text, p_p256dh text, p_auth text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000
     or coalesce(char_length(p_p256dh), 0) not between 20 and 200
     or coalesce(char_length(p_auth), 0) not between 8 and 100 then
    raise exception 'Bildirim aboneliği geçersiz, tekrar dene.';
  end if;
  insert into push_subs(player_id, endpoint, p256dh, auth) values (v_pid, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set player_id = excluded.player_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  delete from push_subs where player_id = v_pid and id not in
    (select id from push_subs where player_id = v_pid order by created_at desc limit 10);
  return true;
end $$;

create or replace function public.push_unsubscribe(p_token uuid, p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subs
   where endpoint = p_endpoint
     and player_id = (select player_id from sessions where token = p_token)
$$;

revoke execute on function public.push_subscribe(uuid, text, text, text), public.push_unsubscribe(uuid, text) from public;
grant execute on function public.push_subscribe(uuid, text, text, text), public.push_unsubscribe(uuid, text) to anon, authenticated;

-- Zamanlayıcılar: 07:00 Türkiye = 04:00 UTC, 20:00 Türkiye = 17:00 UTC
select cron.schedule('peengo-gunaydin', '0 4 * * *', $c$
  select net.http_post(
    url := 'https://klaeugeeyltdgjexfhfk.supabase.co/functions/v1/peengo-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-peengo-cron', (select cron_secret from public.push_config where id = 1)),
    body := '{"kind":"morning"}'::jsonb,
    timeout_milliseconds := 30000)
$c$);

select cron.schedule('peengo-gece-alarm', '0 17 * * *', $c$
  select net.http_post(
    url := 'https://klaeugeeyltdgjexfhfk.supabase.co/functions/v1/peengo-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-peengo-cron', (select cron_secret from public.push_config where id = 1)),
    body := '{"kind":"evening"}'::jsonb,
    timeout_milliseconds := 30000)
$c$);
