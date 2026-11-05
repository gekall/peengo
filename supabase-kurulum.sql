-- Peengo veritabanı kurulumu
-- Supabase > SQL Editor > New query: bu dosyanın tamamını yapıştır ve Run'a bas.
-- Tekrar çalıştırmak güvenlidir, var olan veriyi silmez.

create extension if not exists pgcrypto with schema extensions;

-- Oyuncular (kullanıcı adı ve renk benzersiz, şifre sadece şifrelenmiş hâliyle tutulur)
create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 20),
  color text not null unique,
  pass_hash text not null,
  created_at timestamptz not null default now()
);
create unique index if not exists players_name_lower_idx on public.players (lower(name));

-- Giriş oturumları (her cihaz bir kere giriş yapar, token telefonda/pc'de saklanır)
create table if not exists public.sessions (
  token uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Dakikalar: her kişi her dakikayı (00:00-23:59) bir kere doldurabilir
create table if not exists public.marks (
  player_id uuid not null references public.players(id) on delete cascade,
  minute smallint not null check (minute between 0 and 1439),
  at timestamptz not null default now(),
  primary key (player_id, minute)
);

alter table public.players  enable row level security;
alter table public.sessions enable row level security;
alter table public.marks    enable row level security;

-- Herkes dakikaları okuyabilir; yazma sadece aşağıdaki fonksiyonlarla
drop policy if exists "marks herkes okur" on public.marks;
create policy "marks herkes okur" on public.marks for select to anon, authenticated using (true);

-- Şifre olmadan oyuncu listesi
create or replace view public.players_public as
  select id, name, color, created_at from public.players;

revoke all on public.players, public.sessions from anon, authenticated;
revoke insert, update, delete on public.marks from anon, authenticated;
grant select on public.marks to anon, authenticated;
grant select on public.players_public to anon, authenticated;

-- Profil oluştur
create or replace function public.register(p_name text, p_pass text, p_color text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_id uuid; v_token uuid;
begin
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'Kullanıcı adı 2 ile 20 karakter arasında olmalı.';
  end if;
  if char_length(coalesce(p_pass, '')) < 4 then
    raise exception 'Şifre en az 4 karakter olmalı.';
  end if;
  if p_color not in ('sari','kirmizi','mavi','yesil','mor','pembe','turkuaz','lacivert','fistik') then
    raise exception 'Geçersiz renk.';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name)) then
    raise exception 'Bu kullanıcı adı alınmış. Başka bir isim yaz.';
  end if;
  if exists (select 1 from players where color = p_color) then
    raise exception 'Bu renk alınmış. Başka bir renk seç.';
  end if;
  insert into players(name, color, pass_hash)
    values (v_name, p_color, crypt(p_pass, gen_salt('bf'))) returning id into v_id;
  insert into sessions(player_id) values (v_id) returning token into v_token;
  return json_build_object('token', v_token, 'id', v_id);
exception when unique_violation then
  raise exception 'Bu kullanıcı adı ya da renk az önce alındı. Tekrar dene.';
end $$;

-- Giriş yap (kullanıcı adı büyük/küçük harf fark etmez)
create or replace function public.login(p_name text, p_pass text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_token uuid;
begin
  select id into v_id from players
   where lower(name) = lower(btrim(coalesce(p_name, '')))
     and pass_hash = crypt(coalesce(p_pass, ''), pass_hash);
  if v_id is null then
    perform pg_sleep(0.6);
    raise exception 'Kullanıcı adı ya da şifre yanlış.';
  end if;
  insert into sessions(player_id) values (v_id) returning token into v_token;
  return json_build_object('token', v_token, 'id', v_id);
end $$;

-- Kayıtlı cihaz: token kimin?
create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'color', p.color)
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
$$;

-- İşedim: dakikayı sunucu saati (Türkiye) belirler, geçmişe işaret konamaz
create or replace function public.pee(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_local timestamp := now() at time zone 'Europe/Istanbul';
  v_min int; v_at timestamptz; v_new boolean := false;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  insert into marks(player_id, minute) values (v_pid, v_min)
    on conflict do nothing returning at into v_at;
  if v_at is not null then
    v_new := true;
  else
    select at into v_at from marks where player_id = v_pid and minute = v_min;
  end if;
  return json_build_object('minute', v_min, 'at', v_at, 'new', v_new);
end $$;

-- Geri al: sadece kendi kaydın, sadece ilk 1 dakika içinde
create or replace function public.undo(p_token uuid, p_minute int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_n int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  delete from marks
   where player_id = v_pid and minute = p_minute and at > now() - interval '70 seconds';
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

-- Çıkış
create or replace function public.logout(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from sessions where token = p_token
$$;

revoke execute on function public.register(text, text, text), public.login(text, text),
  public.me(uuid), public.pee(uuid), public.undo(uuid, int), public.logout(uuid) from public;
grant execute on function public.register(text, text, text), public.login(text, text),
  public.me(uuid), public.pee(uuid), public.undo(uuid, int), public.logout(uuid) to anon, authenticated;

-- Canlı güncelleme: biri bastığında herkesin ekranı anında yenilensin
do $$ begin
  alter publication supabase_realtime add table public.marks;
exception when others then null;
end $$;


create table if not exists public.hunts (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  mob_no int not null,
  boss boolean not null default false,
  removed smallint[] not null,
  at timestamptz not null default now()
);
create index if not exists hunts_player_idx on public.hunts (player_id);

alter table public.hunts enable row level security;
drop policy if exists "hunts herkes okur" on public.hunts;
create policy "hunts herkes okur" on public.hunts for select to anon, authenticated using (true);
revoke insert, update, delete on public.hunts from anon, authenticated;
grant select on public.hunts to anon, authenticated;

-- Saldır: canavarı keser, bedel olarak oyuncunun dakikalarından rastgele 2 tanesini
-- (her 10. canavar boss: 4 tanesini) siler. Hangi dakikaların gideceğini sunucu seçer.
create or replace function public.hunt(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_no int; v_boss boolean; v_cost int; v_have int; v_removed smallint[];
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  perform pg_advisory_xact_lock(hashtext('hunt:' || v_pid::text));

  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  v_boss := v_no % 10 = 0;
  v_cost := case when v_boss then 4 else 2 end;

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

revoke execute on function public.hunt(uuid) from public;
grant execute on function public.hunt(uuid) to anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.hunts;
exception when others then null;
end $$;


create or replace function public.rename(p_token uuid, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'Kullanıcı adı 2 ile 20 karakter arasında olmalı.';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name) and id <> v_pid) then
    raise exception 'Bu kullanıcı adı alınmış. Başka bir isim yaz.';
  end if;
  update players set name = v_name where id = v_pid;
  return json_build_object('id', v_pid, 'name', v_name);
exception when unique_violation then
  raise exception 'Bu kullanıcı adı az önce alındı. Başka bir isim yaz.';
end $$;

revoke execute on function public.rename(uuid, text) from public;
grant execute on function public.rename(uuid, text) to anon, authenticated;


alter table public.players add column if not exists last_pee_at timestamptz;

-- Kayıtlı cihaz: token kimin? (bekleme süresi ve sunucu saati de döner)
create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'color', p.color,
                           'last_pee_at', p.last_pee_at, 'now', now())
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
$$;

-- İşedim: dakikayı sunucu saati (Türkiye) belirler; yeni kayıttan sonra 15 dakika bekleme
create or replace function public.pee(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_last timestamptz; v_left int;
  v_local timestamp := now() at time zone 'Europe/Istanbul';
  v_min int; v_at timestamptz; v_new boolean := false;
begin
  select s.player_id, p.last_pee_at into v_pid, v_last
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
   for update of p;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;

  if v_last is not null and v_last > now() - interval '15 minutes' then
    v_left := ceil(extract(epoch from (v_last + interval '15 minutes' - now())))::int;
    raise exception 'Dinlenme süresindesin. % dk % sn sonra tekrar basabilirsin.', v_left / 60, v_left % 60;
  end if;

  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  insert into marks(player_id, minute) values (v_pid, v_min)
    on conflict do nothing returning at into v_at;
  if v_at is not null then
    v_new := true;
    update players set last_pee_at = v_at where id = v_pid;
  else
    select at into v_at from marks where player_id = v_pid and minute = v_min;
  end if;
  return json_build_object('minute', v_min, 'at', v_at, 'new', v_new, 'now', now(),
    'cooldown_until', case when v_new then v_at + interval '15 minutes' end);
end $$;

-- Geri al: sadece kendi kaydın, sadece ilk 1 dakika içinde; bekleme süresi de sıfırlanır
create or replace function public.undo(p_token uuid, p_minute int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_n int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  delete from marks
   where player_id = v_pid and minute = p_minute and at > now() - interval '70 seconds';
  get diagnostics v_n = row_count;
  if v_n > 0 then
    update players set last_pee_at = null
     where id = v_pid and last_pee_at > now() - interval '70 seconds';
  end if;
  return v_n > 0;
end $$;


create table if not exists public.messages (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 300),
  at timestamptz not null default now()
);

alter table public.messages enable row level security;
drop policy if exists "messages herkes okur" on public.messages;
create policy "messages herkes okur" on public.messages for select to anon, authenticated using (true);
revoke insert, update, delete on public.messages from anon, authenticated;
grant select on public.messages to anon, authenticated;

-- Mesaj gönder: giriş yapmış oyuncu, en fazla 300 karakter, 2 saniyede bir
create or replace function public.send_message(p_token uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_id bigint; v_at timestamptz;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if char_length(v_body) = 0 then raise exception 'Boş mesaj gönderilemez.'; end if;
  if char_length(v_body) > 300 then raise exception 'Mesaj en fazla 300 karakter olabilir.'; end if;
  if exists (select 1 from messages where player_id = v_pid and at > now() - interval '2 seconds') then
    raise exception 'Biraz yavaş, 2 saniyede bir mesaj atabilirsin.';
  end if;
  insert into messages(player_id, body) values (v_pid, v_body) returning id, at into v_id, v_at;
  return json_build_object('id', v_id, 'player_id', v_pid, 'body', v_body, 'at', v_at);
end $$;

revoke execute on function public.send_message(uuid, text) from public;
grant execute on function public.send_message(uuid, text) to anon, authenticated;

do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when others then null;
end $$;


alter table public.players add column if not exists intro_seen int not null default 0;

create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'color', p.color,
                           'last_pee_at', p.last_pee_at, 'intro_seen', p.intro_seen, 'now', now())
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
$$;

create or replace function public.ack_intro(p_token uuid, p_version int)
returns void language sql security definer set search_path = public as $$
  update players set intro_seen = greatest(intro_seen, p_version)
   where id = (select player_id from sessions where token = p_token)
$$;

revoke execute on function public.ack_intro(uuid, int) from public;
grant execute on function public.ack_intro(uuid, int) to anon, authenticated;


-- Bu haftanın başlangıcı: en son pazar 00:00 (Türkiye saati)
create or replace function public.chat_week_start()
returns timestamptz language sql stable set search_path = public as $$
  select (date_trunc('week', (now() at time zone 'Europe/Istanbul') + interval '1 day') - interval '1 day')
         at time zone 'Europe/Istanbul'
$$;

-- Kendi mesajını sil
create or replace function public.delete_message(p_token uuid, p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_n int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  delete from messages where id = p_id and player_id = v_pid;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

revoke execute on function public.delete_message(uuid, bigint) from public;
grant execute on function public.delete_message(uuid, bigint) to anon, authenticated;

-- Mesaj gönder: önce geçen haftadan kalanları temizler (zamanlayıcı çalışmasa bile sıfırlama garanti)
create or replace function public.send_message(p_token uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_id bigint; v_at timestamptz;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if char_length(v_body) = 0 then raise exception 'Boş mesaj gönderilemez.'; end if;
  if char_length(v_body) > 300 then raise exception 'Mesaj en fazla 300 karakter olabilir.'; end if;
  if exists (select 1 from messages where player_id = v_pid and at > now() - interval '2 seconds') then
    raise exception 'Biraz yavaş, 2 saniyede bir mesaj atabilirsin.';
  end if;
  delete from messages where at < public.chat_week_start();
  insert into messages(player_id, body) values (v_pid, v_body) returning id, at into v_id, v_at;
  return json_build_object('id', v_id, 'player_id', v_pid, 'body', v_body, 'at', v_at);
end $$;

-- Zamanlayıcı: her pazar 00:00 Türkiye = cumartesi 21:00 UTC
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('peengo-pazar-sohbet-sifirlama', '0 21 * * 6', 'delete from public.messages');
exception when others then
  raise notice 'Zamanlayıcı kurulamadı (%), sıfırlama ilk mesajda yapılacak.', sqlerrm;
end $$;


create or replace function public.register(p_name text, p_pass text, p_color text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_id uuid; v_token uuid;
begin
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'Kullanıcı adı 2 ile 20 karakter arasında olmalı.';
  end if;
  if char_length(coalesce(p_pass, '')) < 4 then
    raise exception 'Şifre en az 4 karakter olmalı.';
  end if;
  if p_color not in ('sari','kirmizi','mavi','yesil','mor','pembe','turkuaz','lacivert','fistik',
                     'turuncu','bordo','kahve','gokmavi','lila','somon','haki','zumrut','fusya',
                     'petrol','hardal','nane','indigo','bej','gul') then
    raise exception 'Geçersiz renk.';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name)) then
    raise exception 'Bu kullanıcı adı alınmış. Başka bir isim yaz.';
  end if;
  if exists (select 1 from players where color = p_color) then
    raise exception 'Bu renk alınmış. Başka bir renk seç.';
  end if;
  insert into players(name, color, pass_hash)
    values (v_name, p_color, crypt(p_pass, gen_salt('bf'))) returning id into v_id;
  insert into sessions(player_id) values (v_id) returning token into v_token;
  return json_build_object('token', v_token, 'id', v_id);
exception when unique_violation then
  raise exception 'Bu kullanıcı adı ya da renk az önce alındı. Tekrar dene.';
end $$;


-- Mesajlara fotoğraf alanı; fotoğraflı mesajda yazı zorunlu değil
alter table public.messages add column if not exists image_path text;
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages add constraint messages_body_check
  check (char_length(body) <= 300 and (char_length(body) >= 1 or image_path is not null));

-- Fotoğraf deposu: herkes bağlantıyla görüntüler, en fazla 2 MB, sadece resim
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat', 'chat', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Yükleme bileti: sadece giriş yapmış oyuncu alabilir, 10 dakika geçerli
create table if not exists public.upload_tickets (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.upload_tickets enable row level security;
revoke all on public.upload_tickets from anon, authenticated;

create or replace function public.photo_ticket(p_token uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_id uuid;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if (select count(*) from upload_tickets where player_id = v_pid and created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Çok hızlı fotoğraf atıyorsun, biraz bekle.';
  end if;
  delete from upload_tickets where created_at < now() - interval '1 day';
  insert into upload_tickets(player_id) values (v_pid) returning id into v_id;
  return v_id;
end $$;

create or replace function public.valid_ticket(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from upload_tickets
                  where id::text = p_folder and created_at > now() - interval '10 minutes')
$$;

-- Bir fotoğraf hâlâ bir mesajda kullanılıyor mu?
create or replace function public.photo_unused(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from messages where image_path = p_name)
$$;

-- Fotoğraflı mesaj gönder
create or replace function public.send_photo(p_token uuid, p_path text, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_id bigint; v_at timestamptz;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if char_length(v_body) > 300 then raise exception 'Mesaj en fazla 300 karakter olabilir.'; end if;
  if p_path is null or p_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}$' then
    raise exception 'Fotoğraf yüklenemedi, tekrar dene.';
  end if;
  if not exists (select 1 from upload_tickets
                  where id::text = split_part(p_path, '/', 1) and player_id = v_pid
                    and created_at > now() - interval '10 minutes') then
    raise exception 'Fotoğrafın süresi doldu, tekrar seç.';
  end if;
  if exists (select 1 from messages where player_id = v_pid and at > now() - interval '2 seconds') then
    raise exception 'Biraz yavaş, 2 saniyede bir mesaj atabilirsin.';
  end if;
  delete from messages where at < public.chat_week_start();
  insert into messages(player_id, body, image_path) values (v_pid, v_body, p_path)
    returning id, at into v_id, v_at;
  return json_build_object('id', v_id, 'player_id', v_pid, 'body', v_body, 'image_path', p_path, 'at', v_at);
end $$;

-- Sahipsiz fotoğraflar (mesajı silinmiş ya da pazar sıfırlamasında gitmiş, 15 dakikadan eski)
create or replace function public.orphan_photos()
returns setof text language sql stable security definer set search_path = public, storage as $$
  select o.name from storage.objects o
   where o.bucket_id = 'chat'
     and o.created_at < now() - interval '15 minutes'
     and not exists (select 1 from public.messages m where m.image_path = o.name)
   limit 100
$$;

revoke execute on function public.photo_ticket(uuid), public.send_photo(uuid, text, text),
  public.valid_ticket(text), public.photo_unused(text), public.orphan_photos() from public;
grant execute on function public.photo_ticket(uuid), public.send_photo(uuid, text, text),
  public.valid_ticket(text), public.photo_unused(text), public.orphan_photos() to anon, authenticated;

-- Depo kuralları: yükleme sadece geçerli biletle; silme sadece sahipsiz fotoğraflar için
drop policy if exists "peengo chat yukleme" on storage.objects;
create policy "peengo chat yukleme" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'chat' and public.valid_ticket((storage.foldername(name))[1]));

drop policy if exists "peengo chat sahipsiz okuma" on storage.objects;
create policy "peengo chat sahipsiz okuma" on storage.objects for select to anon, authenticated
  using (bucket_id = 'chat' and created_at < now() - interval '15 minutes' and public.photo_unused(name));

drop policy if exists "peengo chat sahipsiz silme" on storage.objects;
create policy "peengo chat sahipsiz silme" on storage.objects for delete to anon, authenticated
  using (bucket_id = 'chat' and created_at < now() - interval '15 minutes' and public.photo_unused(name));

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


create or replace function public.hunt(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_no int; v_boss boolean; v_cost int; v_have int; v_removed smallint[];
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  perform pg_advisory_xact_lock(hashtext('hunt:' || v_pid::text));

  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  v_boss := v_no % 10 = 0;
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


alter table public.players add column if not exists is_admin boolean not null default false;

-- Oyuncu listesi: kimin yönetici olduğu herkese açık (şeffaflık), şifre yine gizli
create or replace view public.players_public as
  select id, name, color, created_at, is_admin from public.players;
grant select on public.players_public to anon, authenticated;

-- Kayıtlı cihaz: yönetici bilgisi de döner
create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'color', p.color, 'is_admin', p.is_admin,
                           'last_pee_at', p.last_pee_at, 'intro_seen', p.intro_seen, 'now', now())
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
$$;

-- Uygulama ziyaretleri: açılış (started_at) ve son görülme (last_seen_at ≈ çıkış). 30 gün tutulur.
create table if not exists public.visits (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists visits_player_seen_idx on public.visits (player_id, last_seen_at desc);
alter table public.visits enable row level security;
revoke all on public.visits from anon, authenticated;

create or replace function public.heartbeat(p_token uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_id bigint;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then return; end if;
  select id into v_id from visits
   where player_id = v_pid and last_seen_at > now() - interval '3 minutes'
   order by last_seen_at desc limit 1;
  if v_id is null then
    insert into visits(player_id) values (v_pid);
  else
    update visits set last_seen_at = now() where id = v_id;
  end if;
  if random() < 0.02 then delete from visits where last_seen_at < now() - interval '30 days'; end if;
end $$;

-- Yönetici kontrolü
create or replace function public.admin_pid(p_token uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_pid uuid;
begin
  select p.id into v_pid from sessions s join players p on p.id = s.player_id
   where s.token = p_token and p.is_admin;
  if v_pid is null then raise exception 'Bu işlem için yönetici olmalısın.'; end if;
  return v_pid;
end $$;

create or replace function public.admin_rename(p_token uuid, p_player uuid, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  perform admin_pid(p_token);
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'Kullanıcı adı 2 ile 20 karakter arasında olmalı.';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name) and id <> p_player) then
    raise exception 'Bu kullanıcı adı alınmış. Başka bir isim yaz.';
  end if;
  update players set name = v_name where id = p_player;
  if not found then raise exception 'Oyuncu bulunamadı.'; end if;
  return json_build_object('id', p_player, 'name', v_name);
exception when unique_violation then
  raise exception 'Bu kullanıcı adı az önce alındı. Başka bir isim yaz.';
end $$;

create or replace function public.admin_delete_mark(p_token uuid, p_player uuid, p_minute int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform admin_pid(p_token);
  delete from marks where player_id = p_player and minute = p_minute;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

create or replace function public.admin_delete_message(p_token uuid, p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform admin_pid(p_token);
  delete from messages where id = p_id;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

create or replace function public.admin_visits(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform admin_pid(p_token);
  return coalesce((
    select json_agg(json_build_object('player_id', v.player_id, 'name', p.name,
                                      'started_at', v.started_at, 'last_seen_at', v.last_seen_at)
                    order by v.started_at desc)
      from (select * from visits order by started_at desc limit 300) v
      join players p on p.id = v.player_id), '[]'::json);
end $$;

revoke execute on function public.heartbeat(uuid), public.admin_pid(uuid), public.admin_rename(uuid, uuid, text),
  public.admin_delete_mark(uuid, uuid, int), public.admin_delete_message(uuid, bigint), public.admin_visits(uuid) from public;
grant execute on function public.heartbeat(uuid), public.admin_rename(uuid, uuid, text),
  public.admin_delete_mark(uuid, uuid, int), public.admin_delete_message(uuid, bigint), public.admin_visits(uuid)
  to anon, authenticated;


create or replace function public.admin_delete_player(p_token uuid, p_player uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_admin uuid; v_name text; v_is_admin boolean; v_marks int; v_msgs int;
begin
  v_admin := admin_pid(p_token);
  if p_player = v_admin then raise exception 'Kendi admin hesabını buradan silemezsin.'; end if;
  select name, is_admin into v_name, v_is_admin from players where id = p_player;
  if v_name is null then raise exception 'Oyuncu bulunamadı.'; end if;
  if v_is_admin then raise exception 'Başka bir yönetici hesabı silinemez.'; end if;
  select count(*) into v_marks from marks where player_id = p_player;
  select count(*) into v_msgs from messages where player_id = p_player;
  delete from players where id = p_player;
  return json_build_object('id', p_player, 'name', v_name, 'marks', v_marks, 'messages', v_msgs);
end $$;

revoke execute on function public.admin_delete_player(uuid, uuid) from public;
grant execute on function public.admin_delete_player(uuid, uuid) to anon, authenticated;


create table if not exists public.pees (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  minute smallint not null,
  is_new boolean not null default true,
  at timestamptz not null default now()
);
create index if not exists pees_player_at_idx on public.pees (player_id, at desc);
alter table public.pees enable row level security;
revoke all on public.pees from anon, authenticated;

-- İlk kurulum: son 24 saatteki dakikaları geçmiş işeme olarak ekle (tablo boşsa)
insert into public.pees(player_id, minute, is_new, at)
select player_id, minute, true, at from public.marks
 where at > now() - interval '24 hours'
   and not exists (select 1 from public.pees);

-- Herkese açık özet: sadece sayı, saatler gizli
create or replace view public.pee_counts as
  select player_id, count(*)::int as last24
    from public.pees
   where at > now() - interval '24 hours'
   group by player_id;
grant select on public.pee_counts to anon, authenticated;

-- İşedim: her basış bir işeme; yeni dakikaysa duvara da eklenir. 15 dk bekleme her işemede.
create or replace function public.pee(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_last timestamptz; v_left int;
  v_local timestamp := now() at time zone 'Europe/Istanbul';
  v_min int; v_at timestamptz; v_new boolean;
begin
  select s.player_id, p.last_pee_at into v_pid, v_last
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
   for update of p;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;

  if v_last is not null and v_last > now() - interval '15 minutes' then
    v_left := ceil(extract(epoch from (v_last + interval '15 minutes' - now())))::int;
    raise exception 'Dinlenme süresindesin. % dk % sn sonra tekrar basabilirsin.', v_left / 60, v_left % 60;
  end if;

  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  insert into marks(player_id, minute) values (v_pid, v_min)
    on conflict do nothing returning at into v_at;
  v_new := v_at is not null;
  if not v_new then
    select at into v_at from marks where player_id = v_pid and minute = v_min;
  end if;

  insert into pees(player_id, minute, is_new) values (v_pid, v_min, v_new);
  update players set last_pee_at = now() where id = v_pid;
  if random() < 0.02 then delete from pees where at < now() - interval '30 days'; end if;

  return json_build_object('minute', v_min, 'at', v_at, 'new', v_new, 'counted', true, 'now', now(),
                           'cooldown_until', now() + interval '15 minutes');
end $$;

-- Geri al: son 70 saniyedeki işemeyi siler; yeni dakikaysa duvardan da kaldırır; bekleme sıfırlanır
create or replace function public.undo(p_token uuid, p_minute int)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_id bigint; v_new boolean; v_min int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  select id, is_new, minute into v_id, v_new, v_min from pees
   where player_id = v_pid and at > now() - interval '70 seconds'
   order by at desc limit 1;
  if v_id is null then return false; end if;
  delete from pees where id = v_id;
  if v_new then
    delete from marks where player_id = v_pid and minute = v_min and at > now() - interval '70 seconds';
  end if;
  update players set last_pee_at = null where id = v_pid;
  return true;
end $$;
