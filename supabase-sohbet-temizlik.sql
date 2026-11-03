-- Peengo sohbet: kendi mesajını silme + her pazar 00:00 (Türkiye) sohbet sıfırlama
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

-- Bu haftanın başlangıcı: en son pazar 00:00 (Türkiye saati)
create or replace function public.chat_week_start()
returns timestamptz language sql stable set search_path = public as $$
  select (date_trunc('week', (now() at time zone 'Europe/Istanbul') + interval '1 day') - interval '1 day')
         at time zone 'Europe/Istanbul'
$$;

-- Kendi mesajını sil
create or replace function public.delete_message(p_token uuid, p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_n int;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  delete from messages where id = p_id and player_id = v_pid;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

revoke execute on function public.delete_message(uuid, bigint) from public;
grant execute on function public.delete_message(uuid, bigint) to anon, authenticated;

-- Mesaj gönder: önce geçen haftadan kalanları temizler (zamanlayıcı çalışmasa bile sıfırlama garanti)
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
  delete from messages where at < public.chat_week_start();
  insert into messages(player_id, body) values (v_pid, v_body) returning id, at into v_id, v_at;
  return json_build_object('id', v_id, 'player_id', v_pid, 'body', v_body, 'at', v_at);
end $$;

-- Zamanlayıcı: her pazar 00:00 Türkiye = cumartesi 21:00 UTC
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('peengo-pazar-sohbet-sifirlama', '0 21 * * 6', 'delete from public.messages');
exception when others then
  raise notice 'Zamanlayıcı kurulamadı (%), sıfırlama ilk mesajda yapılacak.', sqlerrm;
end $$;
