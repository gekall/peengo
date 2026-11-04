-- Peengo yönetici (admin) yetkileri + giriş/çıkış kayıtları
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Admin yapmak için: update public.players set is_admin = true where lower(name) = 'admin';

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

select 'admin hazir' as durum,
       (select count(*) from players where is_admin) as yonetici_sayisi,
       (select count(*) from players where lower(name) = 'admin') as admin_adli_hesap;
