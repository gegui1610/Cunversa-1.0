-- =====================================================================
-- CUNVERSA — atualização 6 (respostas e reações)
-- Rode este arquivo se você já executou o schema.sql anteriormente.
-- =====================================================================

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
