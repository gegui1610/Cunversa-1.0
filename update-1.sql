-- =====================================================================
-- CUNVERSA — atualização 1 (fotos e figurinhas no chat)
-- Se você JÁ rodou o schema.sql antes, rode só este arquivo no SQL Editor.
-- (Quem está começando do zero usa só o schema.sql, que já inclui isto.)
-- =====================================================================

alter table public.messages add column if not exists image_url text;
alter table public.messages add column if not exists sticker   text;
alter table public.messages alter column content set default '';

do $$ begin
  alter table public.messages add constraint msg_nonempty
    check (content <> '' or image_url is not null or sticker is not null);
exception when duplicate_object then null; end $$;

create table if not exists public.stickers (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles on delete cascade,
  url        text not null,
  created_at timestamptz default now()
);
alter table public.stickers enable row level security;

drop policy if exists st_read   on public.stickers;
drop policy if exists st_insert on public.stickers;
drop policy if exists st_delete on public.stickers;
create policy st_read   on public.stickers for select to authenticated using (user_id = auth.uid());
create policy st_insert on public.stickers for insert to authenticated with check (user_id = auth.uid());
create policy st_delete on public.stickers for delete to authenticated using (user_id = auth.uid());


-- ---------- atualização 2: moderação de servidores ----------
alter table public.server_members add column if not exists muted_until timestamptz;
alter table public.server_members add column if not exists punishment_until timestamptz;
create table if not exists public.server_bans (
  server_id uuid not null references public.servers on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  banned_by uuid not null references public.profiles on delete cascade,
  created_at timestamptz default now(),
  primary key (server_id,user_id)
);
alter table public.server_bans enable row level security;

create or replace function public.is_server_admin(sid uuid) returns boolean language sql security definer stable set search_path=public as $$
 select exists(select 1 from servers where id=sid and owner=auth.uid()) or exists(select 1 from server_members where server_id=sid and user_id=auth.uid() and role in ('owner','admin')) $$;
create or replace function public.set_server_role(sid uuid,target uuid,new_role text) returns void language plpgsql security definer set search_path=public as $$ begin if not is_server_admin(sid) then raise exception 'Apenas administradores podem alterar cargos'; end if; if new_role not in ('member','mod','admin') or target=auth.uid() then raise exception 'Cargo inválido'; end if; update server_members set role=new_role where server_id=sid and user_id=target; end $$;
create or replace function public.set_server_mute(sid uuid,target uuid,muted boolean) returns void language plpgsql security definer set search_path=public as $$ begin if not is_server_admin(sid) then raise exception 'Apenas administradores podem silenciar'; end if; update server_members set muted_until=case when muted then now()+interval '100 years' else null end where server_id=sid and user_id=target; end $$;
create or replace function public.set_server_punishment(sid uuid,target uuid,seconds integer) returns void language plpgsql security definer set search_path=public as $$ begin if not is_server_admin(sid) then raise exception 'Apenas administradores podem aplicar castigo'; end if; if seconds<0 or seconds>31536000 then raise exception 'Duração inválida'; end if; update server_members set punishment_until=case when seconds=0 then null else now()+(seconds*interval '1 second') end where server_id=sid and user_id=target; end $$;
create or replace function public.ban_from_server(sid uuid,target uuid) returns void language plpgsql security definer set search_path=public as $$ begin if not is_server_admin(sid) or target=auth.uid() then raise exception 'Banimento não permitido'; end if; insert into server_bans(server_id,user_id,banned_by) values(sid,target,auth.uid()) on conflict(server_id,user_id) do update set banned_by=excluded.banned_by,created_at=now(); delete from server_members where server_id=sid and user_id=target; end $$;
grant execute on function public.is_server_admin(uuid),public.set_server_role(uuid,uuid,text),public.set_server_mute(uuid,uuid,boolean),public.set_server_punishment(uuid,uuid,integer),public.ban_from_server(uuid,uuid) to authenticated;
do $$ begin
  create policy ban_read on public.server_bans for select to authenticated using (public.is_server_admin(server_id) or user_id=auth.uid());
exception when duplicate_object then null; end $$;

create or replace function public.add_to_server(sid uuid, code text) returns text language plpgsql security definer set search_path=public as $$
declare t uuid;
begin
 if not public.is_server_admin(sid) then raise exception 'Apenas administradores podem adicionar pessoas'; end if;
 select id into t from profiles where replace(friend_code,'-','')=regexp_replace(code,'\D','','g');
 if t is null then return 'nao_encontrado'; end if;
 if exists(select 1 from server_bans where server_id=sid and user_id=t) then return 'banido'; end if;
 insert into server_members(server_id,user_id) values(sid,t) on conflict do nothing; return 'ok';
end $$;
grant execute on function public.add_to_server(uuid,text) to authenticated;


-- ---------- atualização 3: soundboard ----------
create table if not exists public.server_sounds (
 id uuid primary key default gen_random_uuid(), server_id uuid not null references public.servers on delete cascade,
 user_id uuid not null references public.profiles on delete cascade, name text not null, url text not null, created_at timestamptz default now()
);
alter table public.server_sounds enable row level security;
do $$ begin
 create policy sound_read on public.server_sounds for select to authenticated using (public.is_member(server_id));
 create policy sound_insert on public.server_sounds for insert to authenticated with check (public.is_server_admin(server_id) and user_id=auth.uid());
 create policy sound_delete on public.server_sounds for delete to authenticated using (public.is_server_admin(server_id));
exception when duplicate_object then null; end $$;


-- ---------- atualização 4: exclusão de mensagens ----------
create or replace function public.delete_message(mid uuid) returns void language plpgsql security definer set search_path=public as $$
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
