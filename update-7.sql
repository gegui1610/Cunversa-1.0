-- =====================================================================
-- CUNVERSA — atualização 7 (todos os emojis)
-- Permite emojis Unicode completos, incluindo tons de pele, profissões,
-- bandeiras e famílias/composições usadas pelos dispositivos Apple.
-- =====================================================================

alter table public.message_reactions drop constraint if exists message_reactions_emoji_check;
alter table public.message_reactions add constraint message_reactions_emoji_check check (length(emoji) between 1 and 64);
