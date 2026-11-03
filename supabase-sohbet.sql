-- Peengo sohbet
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

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
