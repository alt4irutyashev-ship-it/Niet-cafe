-- Для фото категорий меню (запустить один раз в Supabase SQL Editor)
alter table cats add column if not exists img text;
