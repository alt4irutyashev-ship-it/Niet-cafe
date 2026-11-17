-- Niet Café 41: скорость. Выполнить в Supabase -> SQL Editor -> New query -> вставить всё -> Run.
-- Можно запускать повторно. Данные не меняются — только индексы, правила доступа и одна новая функция.
--
-- Что было: правило доступа «какая у меня роль» (my_role) база проверяла заново для КАЖДОЙ строки,
--   а позиции заказа искались перебором всей таблицы. Отчёт за 30 дней (1 200 заказов) считался на сервере
--   больше 2 секунд и с каждым месяцем работы становился бы всё медленнее.
-- Что стало: роль проверяется один раз на запрос, позиции заказа находятся по индексу — тот же отчёт ≈ 0,02 с.
-- Плюс: добавление блюда официантом — один запрос вместо трёх.

-- ===== 1. Индексы =====
create index if not exists order_items_order_id_idx on order_items(order_id);
create index if not exists order_items_dish_idx on order_items(dish_id);
create index if not exists orders_open_tbl_idx on orders(tbl) where status='open';
create index if not exists guest_orders_new_idx on guest_orders(created) where status='new';
create index if not exists calls_open_idx on calls(created) where not done;

-- ===== 2. Правила доступа: роль и пользователь вычисляются один раз на запрос =====
-- my_role() → (select my_role()), auth.uid() → (select auth.uid()). Смысл правил не меняется.
do $$
declare r record; q text; w text; n int := 0;
begin
  for r in select * from pg_policies where schemaname='public'
           and (coalesce(qual,'')||coalesce(with_check,'')) ~ '(my_role|auth\.uid)\(\)' loop
    q := regexp_replace(regexp_replace(r.qual, '(?<!select )my_role\(\)', '(select my_role())', 'gi'), '(?<!select )auth\.uid\(\)', '(select auth.uid())', 'gi');
    w := regexp_replace(regexp_replace(r.with_check, '(?<!select )my_role\(\)', '(select my_role())', 'gi'), '(?<!select )auth\.uid\(\)', '(select auth.uid())', 'gi');
    if q is distinct from r.qual or w is distinct from r.with_check then
      execute format('alter policy %I on %I.%I %s %s', r.policyname, r.schemaname, r.tablename,
        case when q is not null then 'using ('||q||')' else '' end,
        case when w is not null then 'with check ('||w||')' else '' end);
      n := n + 1;
    end if;
  end loop;
  raise notice 'Ускорено правил доступа: %', n;
end $$;

-- ===== 3. Добавить блюдо в заказ стола одним запросом =====
-- Работает с правами официанта (security invoker): все проверки и триггеры те же, что и раньше.
create or replace function waiter_add(p_tbl int, p_dish int, p_station text, p_cid text, p_qty int default 1, p_note text default null)
returns jsonb language plpgsql set search_path=public as $$
declare o int;
begin
  select id into o from orders where tbl=p_tbl and status='open' order by id limit 1;
  if o is null then
    insert into orders(tbl,kind) values(p_tbl, case when p_tbl>=200 then 'delivery' when p_tbl>=100 then 'take' else 'dine' end)
    returning id into o;
  end if;
  insert into order_items(order_id,tbl,dish_id,station,qty,note,cid)
  values(o, p_tbl, p_dish, p_station, greatest(1,coalesce(p_qty,1)), nullif(trim(coalesce(p_note,'')),''), p_cid)
  on conflict (cid) do nothing;
  return jsonb_build_object('order_id', o);
end $$;
revoke execute on function waiter_add(int,int,text,text,int,text) from public, anon;
grant execute on function waiter_add(int,int,text,text,int,text) to authenticated;

analyze orders; analyze order_items; analyze item_costs;
notify pgrst, 'reload schema';
