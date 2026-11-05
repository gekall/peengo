-- Peengo yönetici: oyuncu hesabını silme
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.
-- Silinen hesabın dakikaları, avları, mesajları, oturumları, bildirimleri ve giriş kayıtları da silinir
-- (tablolardaki "on delete cascade" sayesinde). Rengi ve kullanıcı adı boşa çıkar.

create or replace function public.admin_delete_player(p_token uuid, p_player uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v_admin uuid; v_name text; v_is_admin boolean; v_marks int; v_msgs int;
begin
  v_admin := admin_pid(p_token);
  if p_player = v_admin then raise exception 'Kendi admin hesabını buradan silemezsin.'; end if;
  select name, is_admin into v_name, v_is_admin from players where id = p_player;
  if v_name is null then raise exception 'Oyuncu bulunamadı.'; end if;
  if v_is_admin then raise exception 'Başka bir yönetici hesabı silinemez.'; end if;
  select count(*) into v_marks from marks where player_id = p_player;
  select count(*) into v_msgs from messages where player_id = p_player;
  delete from players where id = p_player;
  return json_build_object('id', p_player, 'name', v_name, 'marks', v_marks, 'messages', v_msgs);
end $$;

revoke execute on function public.admin_delete_player(uuid, uuid) from public;
grant execute on function public.admin_delete_player(uuid, uuid) to anon, authenticated;

select 'hesap silme hazir' as durum,
       (select count(*) from information_schema.referential_constraints rc
          join information_schema.key_column_usage k on k.constraint_name = rc.constraint_name
         where rc.unique_constraint_name = 'players_pkey' and rc.delete_rule = 'CASCADE') as bagli_tablolar_cascade;
