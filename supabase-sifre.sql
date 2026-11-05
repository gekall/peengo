-- Peengo: şifre sıfırlama (yönetici) ve kendi şifreni değiştirme
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Şifreler geri çevrilemez biçimde (bcrypt) saklanır; unutulan şifre okunamaz, yalnızca yenisi konur.

-- Yönetici: bir oyuncuya yeni şifre koyar (oyuncunun açık oturumları kapanmaz)
create or replace function public.admin_set_password(p_token uuid, p_player uuid, p_pass text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_admin uuid; v_name text; v_is_admin boolean;
begin
  v_admin := admin_pid(p_token);
  select name, is_admin into v_name, v_is_admin from players where id = p_player;
  if v_name is null then raise exception 'Oyuncu bulunamadı.'; end if;
  if v_is_admin and p_player <> v_admin then raise exception 'Başka bir yöneticinin şifresi buradan değiştirilemez.'; end if;
  if char_length(coalesce(p_pass, '')) < 4 then raise exception 'Şifre en az 4 karakter olmalı.'; end if;
  if char_length(p_pass) > 72 then raise exception 'Şifre en fazla 72 karakter olabilir.'; end if;
  update players set pass_hash = crypt(p_pass, gen_salt('bf')) where id = p_player;
  return json_build_object('id', p_player, 'name', v_name);
end $$;

-- Oyuncu: mevcut şifresini bilerek yenisini koyar
create or replace function public.change_password(p_token uuid, p_old text, p_new text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare v_pid uuid; v_ok boolean;
begin
  select s.player_id, p.pass_hash = crypt(coalesce(p_old, ''), p.pass_hash) into v_pid, v_ok
    from sessions s join players p on p.id = s.player_id where s.token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if not v_ok then
    perform pg_sleep(0.6);
    raise exception 'Şu anki şifren yanlış.';
  end if;
  if char_length(coalesce(p_new, '')) < 4 then raise exception 'Yeni şifre en az 4 karakter olmalı.'; end if;
  if char_length(p_new) > 72 then raise exception 'Yeni şifre en fazla 72 karakter olabilir.'; end if;
  update players set pass_hash = crypt(p_new, gen_salt('bf')) where id = v_pid;
  return true;
end $$;

revoke execute on function public.admin_set_password(uuid, uuid, text), public.change_password(uuid, text, text) from public;
grant execute on function public.admin_set_password(uuid, uuid, text), public.change_password(uuid, text, text) to anon, authenticated;

select 'sifre islemleri hazir' as durum;
