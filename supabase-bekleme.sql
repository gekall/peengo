-- Peengo bekleme süresi: bir dakika kaydettikten sonra 15 dakika yeni kayıt yok
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

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
