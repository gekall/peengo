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
