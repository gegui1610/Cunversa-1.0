-- =====================================================================
-- CUNVERSA — atualização 5 (rode este arquivo no SQL Editor do Supabase)
-- Canais só para administradores + soundboard pessoal. Pode rodar mais de uma vez.
-- =====================================================================

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
