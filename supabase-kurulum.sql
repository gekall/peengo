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


-- ===================== ARENA (supabase-arena.sql) =====================
-- Peengo Arena: petler, ordu, sıra tabanlı savaş, günlük coin ve market
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
--
-- Kurallar:
--  * Kesilen her canavar envantere pet olarak gelir (eski avlar da bir kereye mahsus pet olur).
--  * Herkes en fazla 5 petlik ordu kurar. Ordu, sahibi çevrimdışıyken de savaşır.
--  * İstediğin oyuncuya saldırırsın (10 dk'da bir). Önce iki ordunun 1. petleri çarpışır,
--    sırayla vururlar; ölen petin yerine sıradaki çıkar. Savaşı sunucu hesaplar, kayıt tutulur.
--  * Kaybeden ordunun bütün petleri (üstlerindeki eşyalarla) kazananın envanterine geçer, kazanan +5 coin.
--  * Aynı seviyeden 2 pet birleşir: şans Sv 1'de %90, her seviyede %1 azalır; olmazsa ikisi de gider.
--  * Her gün ilk girişte 10 coin. Market: kılıç (saldırı +%) ve zırh (can +%).

alter table public.players add column if not exists coins int not null default 0;
alter table public.players add column if not exists coin_day date;
alter table public.players add column if not exists last_attack_at timestamptz;

-- Pet istatistikleri (13 seviye: av döngüsünde 10, sadece birleştirmeyle 3). index.html'deki PET_HP / PET_ATK ile aynı olmalı.
create or replace function public.pet_hp(t int) returns int language sql immutable as $$
  select (array[30,38,47,59,73,92,114,143,179,224,279,349,437])[t + 1] $$;
create or replace function public.pet_atk(t int) returns int language sql immutable as $$
  select (array[8,10,12,15,18,23,28,36,45,56,70,87,109])[t + 1] $$;
-- Market eşyaları: k = kılıç (saldırı yüzdesi), z = zırh (can yüzdesi). İsimler index.html ITEMS içinde.
create or replace function public.item_pct(c text) returns int language sql immutable as $$
  select case c when 'k1' then 20 when 'k2' then 40 when 'k3' then 70
                when 'z1' then 20 when 'z2' then 40 when 'z3' then 70 else 0 end $$;
create or replace function public.item_price(c text) returns int language sql immutable as $$
  select case c when 'k1' then 10 when 'k2' then 25 when 'k3' then 60
                when 'z1' then 10 when 'z2' then 25 when 'z3' then 60 end $$;
-- Kaçıncı av hangi pet: turun n. avı = Sv n (5. ve 10. boss). Sv 11-13 sadece birleştirmeyle. Ayrıntı: supabase-arena-v2.sql
create or replace function public.mob_tier(p_no int, p_boss boolean) returns int language sql immutable as $$
  select (p_no - 1) % 10 $$;
create table if not exists public.arena_meta (k text primary key, v text, at timestamptz not null default now());
alter table public.arena_meta enable row level security;
revoke all on public.arena_meta from anon, authenticated;
-- Yeni kurulumda petler baştan yeni sırayla oluşur, v2'deki taşıma gerekmez
insert into public.arena_meta (k, v) select 'tier_v2', 'yeni kurulum' where not exists (select 1 from public.pets);

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

-- Birleştir: bu pet + aynı seviyeden bir tane daha. Şans %(90 - tier), olmazsa ikisi de gider.
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
  v_ok := random() * 100 < 90 - v_tier;
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


-- ===================== ARENA v2 (supabase-arena-v2.sql) =====================
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


-- ===================== MAÇ PAYLAŞMA (supabase-mac-paylas.sql) =====================
-- Peengo: savaş kaydını sohbete at, millet izlesin
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

alter table public.messages add column if not exists battle_id bigint references public.battles(id) on delete set null;
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages add constraint messages_body_check
  check (char_length(body) <= 300 and (char_length(body) >= 1 or image_path is not null or battle_id is not null));

-- Maçı sohbete at: mesaj metnini sunucu yazar (kim kime saldırdı, kim kazandı)
create or replace function public.share_battle(p_token uuid, p_battle bigint)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_b battles%rowtype; v_a text; v_d text; v_body text; v_id bigint; v_at timestamptz;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  select * into v_b from battles where id = p_battle;
  if v_b.id is null then raise exception 'Bu savaşın kaydı bulunamadı.'; end if;
  if exists (select 1 from messages where player_id = v_pid and at > now() - interval '2 seconds') then
    raise exception 'Biraz yavaş, 2 saniyede bir mesaj atabilirsin.';
  end if;
  if exists (select 1 from messages where battle_id = p_battle and player_id = v_pid and at > now() - interval '10 minutes') then
    raise exception 'Bu maçı az önce sohbete attın.';
  end if;
  select name into v_a from players where id = v_b.attacker;
  select name into v_d from players where id = v_b.defender;
  v_body := '⚔️ ' || v_a || ' → ' || v_d || ' · ' || case when v_b.attacker_won then v_a else v_d end
            || ' kazandı, ' || v_b.captured || ' pet el değiştirdi';
  delete from messages where at < public.chat_week_start();
  insert into messages(player_id, body, battle_id) values (v_pid, v_body, p_battle)
    returning id, at into v_id, v_at;
  return json_build_object('id', v_id, 'player_id', v_pid, 'body', v_body, 'image_path', null, 'battle_id', p_battle, 'at', v_at);
end $$;

revoke execute on function public.share_battle(uuid, bigint) from public;
grant execute on function public.share_battle(uuid, bigint) to anon, authenticated;

select 'mac paylasma hazir' as durum,
       (select count(*) from information_schema.columns where table_name = 'messages' and column_name = 'battle_id') as battle_id_kolonu;


-- ===================== ARENA İNAKTİF (supabase-arena-pasif.sql) =====================
-- Peengo Arena: orduyu inaktif yapma (istemeyen savaşa zorlanmasın)
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
--  * İnaktif orduya kimse saldıramaz; inaktifken sen de kimseye saldıramazsın.
--  * Saldırdıktan sonraki 1 saat içinde inaktife geçilemez (saldırıp kaçmak yok).

alter table public.players add column if not exists arena_off boolean not null default false;

-- Oyuncu listesinde kimin ordusunun kapalı olduğu görünsün
create or replace view public.players_public as
  select id, name, color, created_at, is_admin, arena_off from public.players;
grant select on public.players_public to anon, authenticated;

create or replace function public.arena_toggle(p_token uuid, p_off boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_last timestamptz; v_left int;
begin
  v_pid := arena_pid(p_token);
  select last_attack_at into v_last from players where id = v_pid for update;
  if p_off and v_last is not null and v_last > now() - interval '1 hour' then
    v_left := ceil(extract(epoch from (v_last + interval '1 hour' - now())) / 60)::int;
    raise exception 'Saldırdıktan sonra 1 saat savaştan çekilemezsin. % dk sonra inaktif yapabilirsin.', v_left;
  end if;
  update players set arena_off = coalesce(p_off, false) where id = v_pid;
  return json_build_object('off', coalesce(p_off, false));
end $$;

create or replace function public.arena_state(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_admin boolean; v_coins int; v_day date; v_last timestamptz; v_unseen int; v_gift int := 0; v_off boolean;
  v_today date := (now() at time zone 'Europe/Istanbul')::date;
begin
  select p.id, p.is_admin, p.coins, p.coin_day, p.last_attack_at, p.arena_off
    into v_pid, v_admin, v_coins, v_day, v_last, v_off
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
    'cooldown_until', v_last + interval '10 minutes', 'now', now(),
    'off', v_off, 'leave_until', v_last + interval '1 hour');
end $$;

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
  if (select arena_off from players where id = v_pid) then
    raise exception 'Ordun inaktif. Saldırmak için önce Ordu sekmesinden aktif et.';
  end if;
  if (select arena_off from players where id = p_target) then
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

revoke execute on function public.arena_toggle(uuid, boolean) from public;
grant execute on function public.arena_toggle(uuid, boolean) to anon, authenticated;

select 'arena inaktif ayari hazir' as durum,
       (select count(*) from public.players where arena_off) as inaktif_oyuncu,
       position('arena_off' in pg_get_functiondef('public.arena_attack(uuid,uuid)'::regprocedure)) > 0 as saldiri_kontrolu;


-- ===================== YUMRUKLA AV (supabase-av-yumruk.sql) =====================
-- Peengo: canavarı dakika vermeden, butona vurarak kes (canavar 40 vuruş, boss 80 vuruş)
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Hile koruması: ilk vuruşta sunucu saati başlatır; canavar en az 3 sn, boss en az 6 sn sonra düşer
-- (40 vuruşu bundan hızlı atmak insan eliyle zaten zor).

alter table public.players add column if not exists tap_started_at timestamptz;
alter table public.players add column if not exists tap_mob int;
alter table public.hunts add column if not exists tapped boolean not null default false;

-- İlk vuruş: sıradaki canavar için sayaç başlar
create or replace function public.hunt_tap_start(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_no int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  update players set tap_started_at = now(), tap_mob = v_no where id = v_pid;
  return json_build_object('mob_no', v_no, 'need', case when v_no % 5 = 0 then 80 else 40 end, 'at', now());
end $$;

-- Son vuruş: canavar dakika almadan kesilir, pet olarak envantere gelir
create or replace function public.hunt_tap(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_no int; v_boss boolean; v_min int; v_started timestamptz; v_mob int; v_left numeric;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  perform pg_advisory_xact_lock(hashtext('hunt:' || v_pid::text));

  select count(*) + 1 into v_no from hunts where player_id = v_pid;
  v_boss := v_no % 5 = 0;
  v_min := case when v_boss then 6 else 3 end;
  select tap_started_at, tap_mob into v_started, v_mob from players where id = v_pid for update;
  if v_started is null or v_mob is distinct from v_no then
    raise exception 'Vuruşların sayılmadı, bu canavara baştan vur.';
  end if;
  v_left := v_min - extract(epoch from (now() - v_started));
  if v_left > 0 then
    raise exception 'Çok hızlı vurdun! % sn sonra canavar düşer.', ceil(v_left)::int;
  end if;

  insert into hunts(player_id, mob_no, boss, removed, tapped) values (v_pid, v_no, v_boss, '{}', true);
  update players set tap_started_at = null, tap_mob = null where id = v_pid;
  return json_build_object('mob_no', v_no, 'boss', v_boss, 'removed', '{}'::smallint[], 'kills', v_no, 'tapped', true);
end $$;

revoke execute on function public.hunt_tap_start(uuid), public.hunt_tap(uuid) from public;
grant execute on function public.hunt_tap_start(uuid), public.hunt_tap(uuid) to anon, authenticated;

select 'yumrukla av hazir' as durum,
       (select count(*) from information_schema.columns where table_name = 'hunts' and column_name = 'tapped') as tapped_kolonu;


-- ===================== ORDU SÖZÜ (supabase-arena-soz.sql) =====================
-- Peengo Arena: ordu sözü (herkes ordusunun yanına bir cümle yazar, ör. "Kaybetmek isteyen saldırsın")
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

alter table public.players add column if not exists arena_motto text;
alter table public.players drop constraint if exists players_arena_motto_check;
alter table public.players add constraint players_arena_motto_check check (char_length(arena_motto) <= 80);

create or replace view public.players_public as
  select id, name, color, created_at, is_admin, arena_off, arena_motto from public.players;
grant select on public.players_public to anon, authenticated;

create or replace function public.arena_motto(p_token uuid, p_text text)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_t text := nullif(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), '');
begin
  v_pid := arena_pid(p_token);
  if char_length(v_t) > 80 then raise exception 'Ordu sözü en fazla 80 karakter olabilir.'; end if;
  update players set arena_motto = v_t where id = v_pid;
  return json_build_object('motto', v_t);
end $$;

revoke execute on function public.arena_motto(uuid, text) from public;
grant execute on function public.arena_motto(uuid, text) to anon, authenticated;

select 'ordu sozu hazir' as durum,
       (select count(*) from information_schema.columns where table_name = 'players_public' and column_name = 'arena_motto') as gorunumde;


-- ===================== İNAKTİF 6 SAAT (supabase-arena-pasif-6saat.sql) =====================
-- Peengo Arena: inaktiflik 6 saat sürer, sonra ordu kendiliğinden aktif olur.
-- İnaktifken tekrar "inaktif" (süreyi uzat) denirse 6 saat baştan başlar.
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

alter table public.players add column if not exists arena_off_until timestamptz;

-- Eski açık/kapalı ayarından geçiş: şu an inaktif olanlar 6 saatlik inaktiflikle devam eder
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'players' and column_name = 'arena_off') then
    execute 'update public.players set arena_off_until = now() + interval ''6 hours'' where arena_off and arena_off_until is null';
  end if;
end $$;

create or replace view public.players_public as
  select id, name, color, created_at, is_admin, coalesce(arena_off_until > now(), false) as arena_off, arena_motto, arena_off_until
    from public.players;
grant select on public.players_public to anon, authenticated;

alter table public.players drop column if exists arena_off;

-- İnaktif yap / süreyi uzat (6 saat baştan) / aktif et
create or replace function public.arena_toggle(p_token uuid, p_off boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_last timestamptz; v_left int; v_until timestamptz;
begin
  v_pid := arena_pid(p_token);
  select last_attack_at into v_last from players where id = v_pid for update;
  if coalesce(p_off, false) then
    if v_last is not null and v_last > now() - interval '1 hour' then
      v_left := ceil(extract(epoch from (v_last + interval '1 hour' - now())) / 60)::int;
      raise exception 'Saldırdıktan sonra 1 saat savaştan çekilemezsin. % dk sonra inaktif yapabilirsin.', v_left;
    end if;
    v_until := now() + interval '6 hours';
  end if;
  update players set arena_off_until = v_until where id = v_pid;
  return json_build_object('off', v_until is not null, 'off_until', v_until);
end $$;

create or replace function public.arena_state(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_admin boolean; v_coins int; v_day date; v_last timestamptz; v_unseen int; v_gift int := 0; v_off timestamptz;
  v_today date := (now() at time zone 'Europe/Istanbul')::date;
begin
  select p.id, p.is_admin, p.coins, p.coin_day, p.last_attack_at, p.arena_off_until
    into v_pid, v_admin, v_coins, v_day, v_last, v_off
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
    'cooldown_until', v_last + interval '10 minutes', 'now', now(),
    'off', coalesce(v_off > now(), false), 'off_until', case when v_off > now() then v_off end,
    'leave_until', v_last + interval '1 hour');
end $$;

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

revoke execute on function public.arena_toggle(uuid, boolean) from public;
grant execute on function public.arena_toggle(uuid, boolean) to anon, authenticated;

select 'inaktif 6 saat hazir' as durum,
       (select count(*) from public.players where arena_off_until > now()) as inaktif_oyuncu,
       position('arena_off_until' in pg_get_functiondef('public.arena_attack(uuid,uuid)'::regprocedure)) > 0 as saldiri_kontrolu;


-- ===================== ŞİFRE (supabase-sifre.sql) =====================
-- Peengo: şifre sıfırlama (yönetici) ve kendi şifreni değiştirme
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Şifreler geri çevrilemez biçimde (bcrypt) saklanır; unutulan şifre okunamaz, yalnızca yenisi konur.

-- Yönetici: bir oyuncuya yeni şifre koyar (oyuncunun açık oturumları kapanmaz)
create or replace function public.admin_set_password(p_token uuid, p_player uuid, p_pass text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_admin uuid; v_name text; v_is_admin boolean;
begin
  v_admin := admin_pid(p_token);
  select name, is_admin into v_name, v_is_admin from players where id = p_player;
  if v_name is null then raise exception 'Oyuncu bulunamadı.'; end if;
  if v_is_admin and p_player <> v_admin then raise exception 'Başka bir yöneticinin şifresi buradan değiştirilemez.'; end if;
  if char_length(coalesce(p_pass, '')) < 4 then raise exception 'Şifre en az 4 karakter olmalı.'; end if;
  if char_length(p_pass) > 72 then raise exception 'Şifre en fazla 72 karakter olabilir.'; end if;
  update players set pass_hash = crypt(p_pass, gen_salt('bf')) where id = p_player;
  return json_build_object('id', p_player, 'name', v_name);
end $$;

-- Oyuncu: mevcut şifresini bilerek yenisini koyar
create or replace function public.change_password(p_token uuid, p_old text, p_new text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare v_pid uuid; v_ok boolean;
begin
  select s.player_id, p.pass_hash = crypt(coalesce(p_old, ''), p.pass_hash) into v_pid, v_ok
    from sessions s join players p on p.id = s.player_id where s.token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if not v_ok then
    perform pg_sleep(0.6);
    raise exception 'Şu anki şifren yanlış.';
  end if;
  if char_length(coalesce(p_new, '')) < 4 then raise exception 'Yeni şifre en az 4 karakter olmalı.'; end if;
  if char_length(p_new) > 72 then raise exception 'Yeni şifre en fazla 72 karakter olabilir.'; end if;
  update players set pass_hash = crypt(p_new, gen_salt('bf')) where id = v_pid;
  return true;
end $$;

revoke execute on function public.admin_set_password(uuid, uuid, text), public.change_password(uuid, text, text) from public;
grant execute on function public.admin_set_password(uuid, uuid, text), public.change_password(uuid, text, text) to anon, authenticated;

select 'sifre islemleri hazir' as durum;
