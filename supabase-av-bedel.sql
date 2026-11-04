-- Peengo canavar avı bedeli: normal canavar 1 dakika, boss (her 10. canavar) 2 dakika
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

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

select 'av bedeli guncellendi' as durum,
       position('then 2 else 1' in pg_get_functiondef('public.hunt(uuid)'::regprocedure)) > 0 as yeni_bedel;
