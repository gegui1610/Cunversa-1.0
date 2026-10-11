-- =====================================================================
-- CUNVERSA — schema do Supabase
-- Cole tudo no SQL Editor do Supabase e clique em RUN (uma vez só).
-- =====================================================================

-- ---------- tabelas ----------
create table public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  username    text not null,
  friend_code text unique not null,          -- ex: 4821-9035
  avatar_url  text,
  banner_url  text,
  bio         text default '',
  effect      int  default 0,                -- 0 = nenhum, 1..30 = efeito do perfil
  created_at  timestamptz default now()
);

create table public.friendships (
  id         uuid primary key default gen_random_uuid(),
  requester  uuid not null references public.profiles on delete cascade,
  addressee  uuid not null references public.profiles on delete cascade,
  status     text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz default now(),
  check (requester <> addressee)
);
create unique index friendships_pair on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table public.servers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  icon_url    text,
  owner       uuid not null references public.profiles on delete cascade,
  invite_code text unique not null,
  created_at  timestamptz default now()
);

create table public.server_members (
  server_id uuid references public.servers on delete cascade,
  user_id   uuid references public.profiles on delete cascade,
  role      text not null default 'member',
  primary key (server_id, user_id)
);

create table public.channels (
  id        uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers on delete cascade,
  name      text not null,
  type      text not null check (type in ('text','voice')),
  position  int  not null default 0
);

create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  channel_id uuid references public.channels on delete cascade,
  dm_key     text,                            -- mensagens diretas: ids ordenados "a_b"
  user_id    uuid not null references public.profiles on delete cascade,
  content    text not null default '' check (length(content) <= 2000),
  image_url  text,                            -- foto enviada
  sticker    text,                            -- figurinha: 'e:😂' (emoji) ou URL de imagem
  created_at timestamptz default now(),
  check ((channel_id is null) <> (dm_key is null)),
  constraint msg_nonempty check (content <> '' or image_url is not null or sticker is not null)
);
create index messages_channel on public.messages (channel_id, created_at desc);
create index messages_dm      on public.messages (dm_key, created_at desc);

-- ---------- funções auxiliares ----------
create or replace function public.is_member(sid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from server_members where server_id = sid and user_id = auth.uid())
$$;

create or replace function public.is_owner(sid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from servers where id = sid and owner = auth.uid())
$$;

create or replace function public.can_chat(cid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from channels c join server_members m on m.server_id = c.server_id
                where c.id = cid and c.type = 'text' and m.user_id = auth.uid())
$$;

create or replace function public.dm_ok(k text) returns boolean
language sql security definer stable set search_path = public as $$
  select position(auth.uid()::text in k) > 0 and exists(
    select 1 from friendships f where f.status = 'accepted'
      and ((f.requester::text || '_' || f.addressee::text) = k or (f.addressee::text || '_' || f.requester::text) = k))
$$;

create or replace function public.gen_code() returns text language plpgsql as $$
declare c text;
begin
  loop
    c := lpad(floor(random() * 100000000)::bigint::text, 8, '0');
    c := substr(c, 1, 4) || '-' || substr(c, 5, 4);
    exit when not exists (select 1 from public.profiles where friend_code = c);
  end loop;
  return c;
end $$;

create or replace function public.gen_invite() returns text language plpgsql as $$
declare c text; chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from public.servers where invite_code = c);
  end loop;
  return c;
end $$;

-- cria o perfil (e o código de amigo) quando alguém cria conta
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, friend_code)
  values (new.id,
          left(coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1)), 20),
          public.gen_code());
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- funções chamadas pelo app (RPC) ----------
create or replace function public.add_friend(code text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid; f public.friendships;
begin
  select id into t from profiles where replace(friend_code, '-', '') = regexp_replace(code, '\D', '', 'g');
  if t is null then return 'nao_encontrado'; end if;
  if t = auth.uid() then return 'voce_mesmo'; end if;
  select * into f from friendships
   where (requester = auth.uid() and addressee = t) or (requester = t and addressee = auth.uid());
  if found then
    if f.status = 'accepted' then return 'ja_amigos'; end if;
    if f.addressee = auth.uid() then
      update friendships set status = 'accepted' where id = f.id;
      return 'amigos';
    end if;
    return 'pedido_ja_enviado';
  end if;
  insert into friendships (requester, addressee) values (auth.uid(), t);
  return 'pedido_enviado';
end $$;

create or replace function public.create_server(sname text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  insert into servers (name, owner, invite_code)
  values (left(trim(sname), 30), auth.uid(), public.gen_invite()) returning id into v;
  insert into server_members (server_id, user_id, role) values (v, auth.uid(), 'owner');
  insert into channels (server_id, name, type, position) values (v, 'geral', 'text', 1), (v, 'Sala de voz', 'voice', 2);
  return v;
end $$;

create or replace function public.join_server(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from servers where invite_code = upper(trim(code));
  if v is null then raise exception 'Convite inválido'; end if;
  insert into server_members (server_id, user_id) values (v, auth.uid()) on conflict do nothing;
  return v;
end $$;

create or replace function public.add_to_server(sid uuid, code text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if not exists (select 1 from servers where id = sid and owner = auth.uid()) then
    raise exception 'Só o dono do servidor pode adicionar pessoas';
  end if;
  select id into t from profiles where replace(friend_code, '-', '') = regexp_replace(code, '\D', '', 'g');
  if t is null then return 'nao_encontrado'; end if;
  insert into server_members (server_id, user_id) values (sid, t) on conflict do nothing;
  return 'ok';
end $$;

grant execute on function public.add_friend(text), public.create_server(text), public.join_server(text), public.add_to_server(uuid, text) to authenticated;

-- ---------- segurança (RLS) ----------
alter table public.profiles       enable row level security;
alter table public.friendships    enable row level security;
alter table public.servers        enable row level security;
alter table public.server_members enable row level security;
alter table public.channels       enable row level security;
alter table public.messages       enable row level security;

create policy profiles_read   on public.profiles for select to authenticated using (true);
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant  update (username, avatar_url, banner_url, bio, effect) on public.profiles to authenticated;

create policy fr_read   on public.friendships for select to authenticated using (requester = auth.uid() or addressee = auth.uid());
create policy fr_accept on public.friendships for update to authenticated using (addressee = auth.uid()) with check (addressee = auth.uid());
create policy fr_delete on public.friendships for delete to authenticated using (requester = auth.uid() or addressee = auth.uid());

create policy srv_read   on public.servers for select to authenticated using (public.is_member(id));
create policy srv_update on public.servers for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy srv_delete on public.servers for delete to authenticated using (owner = auth.uid());

create policy mem_read   on public.server_members for select to authenticated using (public.is_member(server_id));
create policy mem_delete on public.server_members for delete to authenticated using (user_id = auth.uid() or public.is_owner(server_id));

create policy ch_read   on public.channels for select to authenticated using (public.is_member(server_id));
create policy ch_insert on public.channels for insert to authenticated with check (public.is_member(server_id));
create policy ch_delete on public.channels for delete to authenticated using (public.is_owner(server_id));

create policy msg_read on public.messages for select to authenticated using (
  (channel_id is not null and public.can_chat(channel_id))
  or (dm_key is not null and position(auth.uid()::text in dm_key) > 0));
create policy msg_insert on public.messages for insert to authenticated with check (
  user_id = auth.uid() and (
    (channel_id is not null and public.can_chat(channel_id))
    or (dm_key is not null and public.dm_ok(dm_key))));
create policy msg_delete on public.messages for delete to authenticated using (user_id = auth.uid());

-- ---------- tempo real ----------
alter publication supabase_realtime add table public.messages, public.channels, public.servers,
  public.server_members, public.friendships, public.profiles;

-- ---------- armazenamento das imagens (fotos, banners, ícones, GIFs) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', true, 10485760) on conflict (id) do nothing;

create policy media_read   on storage.objects for select using (bucket_id = 'media');
create policy media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy media_update on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- figurinhas pessoais ----------
create table public.stickers (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles on delete cascade,
  url        text not null,
  created_at timestamptz default now()
);
alter table public.stickers enable row level security;
create policy st_read   on public.stickers for select to authenticated using (user_id = auth.uid());
create policy st_insert on public.stickers for insert to authenticated with check (user_id = auth.uid());
create policy st_delete on public.stickers for delete to authenticated using (user_id = auth.uid());


-- ---------- moderação de servidores ----------
alter table public.server_members add column if not exists muted_until timestamptz;
alter table public.server_members add column if not exists punishment_until timestamptz;

create table if not exists public.server_bans (
  server_id uuid not null references public.servers on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  banned_by uuid not null references public.profiles on delete cascade,
  created_at timestamptz default now(),
  primary key (server_id, user_id)
);
alter table public.server_bans enable row level security;

create or replace function public.is_server_admin(sid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from servers s where s.id=sid and s.owner=auth.uid())
      or exists(select 1 from server_members m where m.server_id=sid and m.user_id=auth.uid() and m.role in ('owner','admin'))
$$;

create or replace function public.join_server(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from servers where invite_code = upper(trim(code));
  if v is null then raise exception 'Convite inválido'; end if;
  if exists(select 1 from server_bans where server_id=v and user_id=auth.uid()) then raise exception 'Você foi banido deste servidor'; end if;
  insert into server_members (server_id, user_id) values (v, auth.uid()) on conflict do nothing;
  return v;
end $$;

create or replace function public.add_to_server(sid uuid, code text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if not public.is_server_admin(sid) then raise exception 'Apenas administradores podem adicionar pessoas'; end if;
  select id into t from profiles where replace(friend_code, '-', '') = regexp_replace(code, '\D', '', 'g');
  if t is null then return 'nao_encontrado'; end if;
  if exists(select 1 from server_bans where server_id=sid and user_id=t) then return 'banido'; end if;
  insert into server_members (server_id, user_id) values (sid, t) on conflict do nothing;
  return 'ok';
end $$;

create or replace function public.set_server_role(sid uuid, target uuid, new_role text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_server_admin(sid) then raise exception 'Apenas administradores podem alterar cargos'; end if;
  if new_role not in ('member','mod','admin') then raise exception 'Cargo inválido'; end if;
  if target=auth.uid() then raise exception 'Você não pode alterar o próprio cargo'; end if;
  update server_members set role=new_role where server_id=sid and user_id=target;
end $$;

create or replace function public.set_server_mute(sid uuid, target uuid, muted boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_server_admin(sid) then raise exception 'Apenas administradores podem silenciar'; end if;
  update server_members set muted_until=case when muted then now()+interval '100 years' else null end
   where server_id=sid and user_id=target;
end $$;

create or replace function public.set_server_punishment(sid uuid, target uuid, seconds integer) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_server_admin(sid) then raise exception 'Apenas administradores podem aplicar castigo'; end if;
  if seconds < 0 or seconds > 31536000 then raise exception 'Duração inválida'; end if;
  update server_members set punishment_until=case when seconds=0 then null else now()+(seconds * interval '1 second') end
   where server_id=sid and user_id=target;
end $$;

create or replace function public.ban_from_server(sid uuid, target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_server_admin(sid) then raise exception 'Apenas administradores podem banir'; end if;
  if target=auth.uid() or exists(select 1 from servers where id=sid and owner=target) then raise exception 'Não é possível banir este membro'; end if;
  insert into server_bans(server_id,user_id,banned_by) values(sid,target,auth.uid()) on conflict(server_id,user_id) do update set banned_by=excluded.banned_by,created_at=now();
  delete from server_members where server_id=sid and user_id=target;
end $$;

grant execute on function public.is_server_admin(uuid), public.set_server_role(uuid,uuid,text), public.set_server_mute(uuid,uuid,boolean), public.set_server_punishment(uuid,uuid,integer), public.ban_from_server(uuid,uuid) to authenticated;

create policy ban_read on public.server_bans for select to authenticated using (public.is_server_admin(server_id) or user_id=auth.uid());

-- Bloqueia conversa enquanto o castigo estiver ativo.
create or replace function public.can_chat(cid uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from channels c join server_members m on m.server_id=c.server_id
                where c.id=cid and c.type='text' and m.user_id=auth.uid()
                  and (m.punishment_until is null or m.punishment_until <= now()))
$$;


-- ---------- soundboard por servidor ----------
create table if not exists public.server_sounds (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  name text not null,
  url text not null,
  created_at timestamptz default now()
);
alter table public.server_sounds enable row level security;
create policy sound_read on public.server_sounds for select to authenticated using (public.is_member(server_id));
create policy sound_insert on public.server_sounds for insert to authenticated with check (public.is_server_admin(server_id) and user_id=auth.uid());
create policy sound_delete on public.server_sounds for delete to authenticated using (public.is_server_admin(server_id));


-- ---------- exclusão de mensagens ----------
create or replace function public.delete_message(mid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.messages; sid uuid;
begin
  select * into m from messages where id=mid;
  if m.id is null then return; end if;
  if m.user_id=auth.uid() then delete from messages where id=mid; return; end if;
  select server_id into sid from channels where id=m.channel_id;
  if sid is not null and public.is_server_admin(sid) then delete from messages where id=mid; return; end if;
  raise exception 'Você não pode excluir esta mensagem';
end $$;
grant execute on function public.delete_message(uuid) to authenticated;


-- ---------- atualização 5: canais só para administradores + soundboard pessoal ----------
-- Só dono/administrador cria ou apaga canais (texto e voz).
drop policy if exists ch_insert on public.channels;
drop policy if exists ch_delete on public.channels;
create policy ch_insert on public.channels for insert to authenticated with check (public.is_server_admin(server_id));
create policy ch_delete on public.channels for delete to authenticated using (public.is_server_admin(server_id));

-- Soundboard pessoal: cada pessoa tem os próprios sons (valem em qualquer chamada).
create table if not exists public.user_sounds (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles on delete cascade,
  name       text not null check (length(name) between 1 and 60),
  url        text not null,
  created_at timestamptz default now()
);
alter table public.user_sounds enable row level security;
drop policy if exists us_read   on public.user_sounds;
drop policy if exists us_insert on public.user_sounds;
drop policy if exists us_delete on public.user_sounds;
create policy us_read   on public.user_sounds for select to authenticated using (user_id = auth.uid());
create policy us_insert on public.user_sounds for insert to authenticated
  with check (user_id = auth.uid() and (select count(*) from public.user_sounds where user_id = auth.uid()) < 40);
create policy us_delete on public.user_sounds for delete to authenticated using (user_id = auth.uid());


-- ---------- respostas e reações ----------
alter table public.messages add column if not exists reply_to uuid references public.messages(id) on delete set null;
create index if not exists messages_reply_to on public.messages(reply_to);

create table if not exists public.message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (length(emoji) between 1 and 16),
  created_at timestamptz default now(),
  unique(message_id, user_id, emoji)
);
alter table public.message_reactions enable row level security;
drop policy if exists mr_read on public.message_reactions;
drop policy if exists mr_insert on public.message_reactions;
drop policy if exists mr_delete on public.message_reactions;
create policy mr_read on public.message_reactions for select to authenticated using (
  exists (select 1 from public.messages m where m.id=message_id and ((m.channel_id is not null and public.can_chat(m.channel_id)) or (m.dm_key is not null and position(auth.uid()::text in m.dm_key)>0)))
);
create policy mr_insert on public.message_reactions for insert to authenticated with check (
  user_id=auth.uid() and exists (select 1 from public.messages m where m.id=message_id and ((m.channel_id is not null and public.can_chat(m.channel_id)) or (m.dm_key is not null and position(auth.uid()::text in m.dm_key)>0)))
);
create policy mr_delete on public.message_reactions for delete to authenticated using (user_id=auth.uid());
do $$ begin alter publication supabase_realtime add table public.message_reactions; exception when duplicate_object then null; end $$;
