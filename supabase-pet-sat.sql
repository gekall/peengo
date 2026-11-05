-- Peengo Arena: pet satma (coin küsuratlı oldu: 0,1 🪙)
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Fiyatlar: Sv1-8 0,1 · Sv9 0,2 · Sv10 0,3 · Sv11 1 · Sv12 4 · Sv13 25 coin.
--  * Açık bırakılan bir saatlik av (~75 pet) satılınca ~10 coin eder (bir günlük hediye kadar).
--  * Birleştirip satmak kâr getirmez (Sv10+Sv10=0,6 → %60×1 = 0,6; Sv12+Sv12=8 → %30×25 = 7,5).
--  * Satılan pet ordudaysa ordudan çıkar; üstündeki eşyalar çantaya döner.

alter table public.players alter column coins type numeric(10,1) using coins::numeric(10,1);

create or replace function public.pet_price(t int) returns numeric language sql immutable as $$
  select (array[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.2,0.3,1,4,25]::numeric[])[t + 1] $$;

create or replace function public.arena_sell(p_token uuid, p_pets bigint[])
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_want int; v_n int; v_sum numeric; v_items int; v_coins numeric;
begin
  v_pid := arena_pid(p_token);
  perform pg_advisory_xact_lock(hashtext('peengo-arena'));
  select count(distinct x) into v_want from unnest(coalesce(p_pets, '{}')) x;
  if v_want = 0 then raise exception 'Satılacak pet seçilmedi.'; end if;
  if v_want > 500 then raise exception 'Tek seferde en fazla 500 pet satabilirsin.'; end if;
  select count(*), coalesce(sum(pet_price(tier)), 0) into v_n, v_sum from pets where owner = v_pid and id = any(p_pets);
  if v_n <> v_want then raise exception 'Bu petlerden bazıları artık senin değil. Sayfayı yenile.'; end if;
  select count(*) into v_items from items where pet_id = any(p_pets);
  delete from pets where owner = v_pid and id = any(p_pets);
  update players set coins = coins + v_sum where id = v_pid returning coins into v_coins;
  return json_build_object('sold', v_n, 'gained', v_sum, 'coins', v_coins, 'items_back', v_items);
end $$;

-- coin küsuratlı olduğu için bu ikisi yeniden tanımlanır (değişken tipi numeric)
create or replace function public.arena_state(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid; v_admin boolean; v_coins numeric; v_day date; v_last timestamptz; v_unseen int; v_gift int := 0; v_off timestamptz;
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

create or replace function public.arena_buy(p_token uuid, p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_price int; v_coins numeric; v_id bigint;
begin
  v_pid := arena_pid(p_token);
  v_price := item_price(p_code);
  if v_price is null then raise exception 'Markette böyle bir eşya yok.'; end if;
  update players set coins = coins - v_price where id = v_pid and coins >= v_price returning coins into v_coins;
  if v_coins is null then raise exception 'Coinin yetmiyor. Bu eşya % coin.', v_price; end if;
  insert into items (owner, code) values (v_pid, p_code) returning id into v_id;
  return json_build_object('id', v_id, 'coins', v_coins);
end $$;

revoke execute on function public.arena_sell(uuid, bigint[]) from public;
grant execute on function public.arena_sell(uuid, bigint[]) to anon, authenticated;

select 'pet satma hazir' as durum,
       (select data_type from information_schema.columns where table_name = 'players' and column_name = 'coins') as coin_tipi,
       public.pet_price(0) as sv1, public.pet_price(9) as sv10, public.pet_price(12) as sv13;
