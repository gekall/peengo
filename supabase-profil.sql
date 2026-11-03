-- Peengo profil düzenleme: kullanıcı kendi adını değiştirebilir
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

create or replace function public.rename(p_token uuid, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'Kullanıcı adı 2 ile 20 karakter arasında olmalı.';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name) and id <> v_pid) then
    raise exception 'Bu kullanıcı adı alınmış. Başka bir isim yaz.';
  end if;
  update players set name = v_name where id = v_pid;
  return json_build_object('id', v_pid, 'name', v_name);
exception when unique_violation then
  raise exception 'Bu kullanıcı adı az önce alındı. Başka bir isim yaz.';
end $$;

revoke execute on function public.rename(uuid, text) from public;
grant execute on function public.rename(uuid, text) to anon, authenticated;
