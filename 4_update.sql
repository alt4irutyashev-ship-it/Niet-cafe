-- Минимальные остатки для списка закупок. Выполнить в Supabase SQL Editor.
alter table products add column if not exists min_qty numeric default 0;
