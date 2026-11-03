-- Peengo canavar avı
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

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
