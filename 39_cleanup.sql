-- Niet Café 39: уборка лишнего. Supabase -> SQL Editor -> вставить всё -> Run. Можно запускать повторно.
-- Удаляет старые «рыночные цены» (файлы 17 и 18): их заменили цены из накладных (36) и сравнение по закупам.
-- Цены продуктов, история цен, приходы и статистика НЕ трогаются.
drop function if exists market_prices();
drop table if exists price_ref;
notify pgrst, 'reload schema';
