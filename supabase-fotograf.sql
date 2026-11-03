-- Peengo sohbet fotoğrafları
-- Supabase > SQL Editor > New query: yapıştır ve Run'a bas. Tekrar çalıştırmak güvenlidir.

-- Mesajlara fotoğraf alanı; fotoğraflı mesajda yazı zorunlu değil
alter table public.messages add column if not exists image_path text;
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages add constraint messages_body_check
  check (char_length(body) <= 300 and (char_length(body) >= 1 or image_path is not null));

-- Fotoğraf deposu: herkes bağlantıyla görüntüler, en fazla 2 MB, sadece resim
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat', 'chat', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Yükleme bileti: sadece giriş yapmış oyuncu alabilir, 10 dakika geçerli
create table if not exists public.upload_tickets (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.upload_tickets enable row level security;
revoke all on public.upload_tickets from anon, authenticated;

create or replace function public.photo_ticket(p_token uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_id uuid;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if (select count(*) from upload_tickets where player_id = v_pid and created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Çok hızlı fotoğraf atıyorsun, biraz bekle.';
  end if;
  delete from upload_tickets where created_at < now() - interval '1 day';
  insert into upload_tickets(player_id) values (v_pid) returning id into v_id;
  return v_id;
end $$;

create or replace function public.valid_ticket(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from upload_tickets
                  where id::text = p_folder and created_at > now() - interval '10 minutes')
$$;

-- Bir fotoğraf hâlâ bir mesajda kullanılıyor mu?
create or replace function public.photo_unused(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from messages where image_path = p_name)
$$;

-- Fotoğraflı mesaj gönder
create or replace function public.send_photo(p_token uuid, p_path text, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_pid uuid;
  v_body text := btrim(coalesce(p_body, ''));
  v_id bigint; v_at timestamptz;
begin
  select player_id into v_pid from sessions where token = p_token;
  if v_pid is null then raise exception 'Oturumun kapanmış. Tekrar giriş yap.'; end if;
  if char_length(v_body) > 300 then raise exception 'Mesaj en fazla 300 karakter olabilir.'; end if;
  if p_path is null or p_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}$' then
    raise exception 'Fotoğraf yüklenemedi, tekrar dene.';
  end if;
  if not exists (select 1 from upload_tickets
                  where id::text = split_part(p_path, '/', 1) and player_id = v_pid
                    and created_at > now() - interval '10 minutes') then
    raise exception 'Fotoğrafın süresi doldu, tekrar seç.';
  end if;
  if exists (select 1 from messages where player_id = v_pid and at > now() - interval '2 seconds') then
    raise exception 'Biraz yavaş, 2 saniyede bir mesaj atabilirsin.';
  end if;
  delete from messages where at < public.chat_week_start();
  insert into messages(player_id, body, image_path) values (v_pid, v_body, p_path)
    returning id, at into v_id, v_at;
  return json_build_object('id', v_id, 'player_id', v_pid, 'body', v_body, 'image_path', p_path, 'at', v_at);
end $$;

-- Sahipsiz fotoğraflar (mesajı silinmiş ya da pazar sıfırlamasında gitmiş, 15 dakikadan eski)
create or replace function public.orphan_photos()
returns setof text language sql stable security definer set search_path = public, storage as $$
  select o.name from storage.objects o
   where o.bucket_id = 'chat'
     and o.created_at < now() - interval '15 minutes'
     and not exists (select 1 from public.messages m where m.image_path = o.name)
   limit 100
$$;

revoke execute on function public.photo_ticket(uuid), public.send_photo(uuid, text, text),
  public.valid_ticket(text), public.photo_unused(text), public.orphan_photos() from public;
grant execute on function public.photo_ticket(uuid), public.send_photo(uuid, text, text),
  public.valid_ticket(text), public.photo_unused(text), public.orphan_photos() to anon, authenticated;

-- Depo kuralları: yükleme sadece geçerli biletle; silme sadece sahipsiz fotoğraflar için
drop policy if exists "peengo chat yukleme" on storage.objects;
create policy "peengo chat yukleme" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'chat' and public.valid_ticket((storage.foldername(name))[1]));

drop policy if exists "peengo chat sahipsiz okuma" on storage.objects;
create policy "peengo chat sahipsiz okuma" on storage.objects for select to anon, authenticated
  using (bucket_id = 'chat' and created_at < now() - interval '15 minutes' and public.photo_unused(name));

drop policy if exists "peengo chat sahipsiz silme" on storage.objects;
create policy "peengo chat sahipsiz silme" on storage.objects for delete to anon, authenticated
  using (bucket_id = 'chat' and created_at < now() - interval '15 minutes' and public.photo_unused(name));
