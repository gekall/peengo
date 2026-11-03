-- Peengo renk listesi: 24 renk
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

create or replace function public.register(p_name text, p_pass text, p_color text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_id uuid; v_token uuid;
begin
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception 'Kullanıcı adı 2 ile 20 karakter arasında olmalı.';
  end if;
  if char_length(coalesce(p_pass, '')) < 4 then
    raise exception 'Şifre en az 4 karakter olmalı.';
  end if;
  if p_color not in ('sari','kirmizi','mavi','yesil','mor','pembe','turkuaz','lacivert','fistik',
                     'turuncu','bordo','kahve','gokmavi','lila','somon','haki','zumrut','fusya',
                     'petrol','hardal','nane','indigo','bej','gul') then
    raise exception 'Geçersiz renk.';
  end if;
  if exists (select 1 from players where lower(name) = lower(v_name)) then
    raise exception 'Bu kullanıcı adı alınmış. Başka bir isim yaz.';
  end if;
  if exists (select 1 from players where color = p_color) then
    raise exception 'Bu renk alınmış. Başka bir renk seç.';
  end if;
  insert into players(name, color, pass_hash)
    values (v_name, p_color, crypt(p_pass, gen_salt('bf'))) returning id into v_id;
  insert into sessions(player_id) values (v_id) returning token into v_token;
  return json_build_object('token', v_token, 'id', v_id);
exception when unique_violation then
  raise exception 'Bu kullanıcı adı ya da renk az önce alındı. Tekrar dene.';
end $$;
