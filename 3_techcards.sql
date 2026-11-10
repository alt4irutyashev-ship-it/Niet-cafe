-- Niet Café: техкарты для кухни. Выполнить в Supabase -> SQL Editor (после 1_schema.sql).
-- Кухня видит состав блюд (продукт, единица, количество на порцию) без цен закупки.
-- Руководитель и так имеет полный доступ к recipes и products.
create or replace function tech_cards()
returns table(dish_id int, product text, unit text, qty numeric)
language sql stable security definer set search_path=public as $$
  select r.dish_id, p.name, p.unit, r.qty
  from recipes r join products p on p.id = r.product_id
  where my_role() in ('kitchen','boss')
  order by p.name
$$;
revoke all on function tech_cards() from public, anon;
grant execute on function tech_cards() to authenticated;
