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
