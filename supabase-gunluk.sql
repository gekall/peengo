-- Peengo: her işemeyi kaydet + son 24 saatte kaç kez işendiği
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Not: zaten sahip olduğun bir dakikada işemek de artık sayılır (yeni dakika kazandırmaz, 15 dk bekleme başlatır).

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

select 'gunluk sayac hazir' as durum,
       (select count(*) from public.pees) as kayitli_iseme,
       (select coalesce(sum(last24), 0) from public.pee_counts) as son_24_saat;
