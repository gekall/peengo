-- Peengo tanıtım notu: her hesap bir kez görür (telefon/bilgisayar fark etmez)
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

alter table public.players add column if not exists intro_seen int not null default 0;

create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'name', p.name, 'color', p.color,
                           'last_pee_at', p.last_pee_at, 'intro_seen', p.intro_seen, 'now', now())
    from sessions s join players p on p.id = s.player_id
   where s.token = p_token
$$;

create or replace function public.ack_intro(p_token uuid, p_version int)
returns void language sql security definer set search_path = public as $$
  update players set intro_seen = greatest(intro_seen, p_version)
   where id = (select player_id from sessions where token = p_token)
$$;

revoke execute on function public.ack_intro(uuid, int) from public;
grant execute on function public.ack_intro(uuid, int) to anon, authenticated;
