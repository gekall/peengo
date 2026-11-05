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
