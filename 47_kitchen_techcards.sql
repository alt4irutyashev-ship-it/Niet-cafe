-- Niet Café 47: ПОВАР (и бармен) МЕНЯЮТ ТЕХКАРТЫ своих блюд — упрощённо.
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять ПОСЛЕ 46_techcards_draft.sql. Можно запускать повторно.
--
--   • Кухня правит техкарты блюд кухни, бар — блюд бара, руководитель — любые.
--   • Цены продуктов повар по-прежнему НЕ видит; себестоимость и фудкост пересчитываются сами.
--   • Техкарту сета повар не меняет: она собирается из блюд (меняется вместе с ними).
--   • Каждое изменение записывается в журнал: кто, когда, какой продукт, было → стало.
--     Руководитель видит журнал в карточке блюда («🕘 Изменения техкарты»).

create table if not exists techcard_log(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  uid uuid default auth.uid(),
  dish_id int references dishes(id) on delete cascade,
  product_id int references products(id) on delete set null,
  what text, unit text, old_qty numeric, new_qty numeric
);
create index if not exists techcard_log_dish_i on techcard_log(dish_id, t desc);
alter table techcard_log enable row level security;
drop policy if exists techcard_log_boss on techcard_log;
create policy techcard_log_boss on techcard_log for select using (my_role() = 'boss');

-- техкарты для экрана кухни/бара (с id продукта, без цен)
create or replace function kt_cards()
returns table(dish_id int, product_id int, product text, unit text, qty numeric, loss_pct numeric)
language sql stable security definer set search_path=public as $$
  select r.dish_id, p.id, p.name, p.unit, r.qty, coalesce(p.loss_pct, 0)
    from recipes r join products p on p.id = r.product_id join dishes d on d.id = r.dish_id
   where my_role() = 'boss' or (my_role() in ('kitchen','bar') and d.station = my_role())
   order by p.name
$$;
revoke all on function kt_cards() from public, anon;
grant execute on function kt_cards() to authenticated;

-- список продуктов для добавления в техкарту (без цен)
create or replace function kt_products()
returns table(id int, name text, unit text, station text)
language sql stable security definer set search_path=public as $$
  select p.id, p.name, p.unit, coalesce(p.station, 'kitchen')
    from products p
   where not coalesce(p.archived, false) and my_role() in ('kitchen','bar','boss')
   order by p.name
$$;
revoke all on function kt_products() from public, anon;
grant execute on function kt_products() to authenticated;

-- сохранить техкарту целиком: p_items = [{"product_id":1,"qty":0.15}, …] (кол-во в единицах продукта)
create or replace function kt_save(p_dish int, p_items jsonb, p_out_g int default null)
returns int language plpgsql security definer set search_path=public as $$
declare d dishes%rowtype; r record; n int := 0; role text := my_role();
begin
  select * into d from dishes where id = p_dish;
  if not found or coalesce(d.archived, false) then raise exception 'Блюдо не найдено'; end if;
  if not (role = 'boss' or (role in ('kitchen','bar') and d.station = role)) then
    raise exception 'Можно менять только техкарты своих блюд';
  end if;
  if coalesce(d.is_set, false) then
    raise exception 'Техкарта сета собирается из входящих блюд — измените сами блюда';
  end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_items, '[]'::jsonb)) > 60 then
    raise exception 'Неверный список продуктов';
  end if;

  create temp table if not exists kt_new(product_id int primary key, qty numeric) on commit drop;
  delete from kt_new;
  insert into kt_new
  select (x->>'product_id')::int, sum((x->>'qty')::numeric)
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
   group by 1;
  if exists (select 1 from kt_new where qty is null or qty <= 0 or qty > 50) then
    raise exception 'Количество каждого продукта должно быть больше 0 (и не больше 50 кг/л/шт)';
  end if;
  if exists (select 1 from kt_new k where not exists (select 1 from products p where p.id = k.product_id and not coalesce(p.archived, false))) then
    raise exception 'Продукт не найден';
  end if;

  -- убранные
  for r in select rc.product_id, rc.qty, p.name, p.unit from recipes rc join products p on p.id = rc.product_id
            where rc.dish_id = p_dish and not exists (select 1 from kt_new k where k.product_id = rc.product_id) loop
    delete from recipes where dish_id = p_dish and product_id = r.product_id;
    insert into techcard_log(dish_id, product_id, what, unit, old_qty, new_qty) values (p_dish, r.product_id, r.name, r.unit, r.qty, null);
    n := n + 1;
  end loop;
  -- изменённые и новые
  for r in select k.product_id, round(k.qty, 4) qty, rc.qty old_qty, p.name, p.unit
             from kt_new k join products p on p.id = k.product_id
             left join recipes rc on rc.dish_id = p_dish and rc.product_id = k.product_id
            where rc.qty is distinct from round(k.qty, 4) loop
    if r.old_qty is null then
      insert into recipes(dish_id, product_id, qty) values (p_dish, r.product_id, r.qty);
    else
      update recipes set qty = r.qty where dish_id = p_dish and product_id = r.product_id;
    end if;
    insert into techcard_log(dish_id, product_id, what, unit, old_qty, new_qty) values (p_dish, r.product_id, r.name, r.unit, r.old_qty, r.qty);
    n := n + 1;
  end loop;

  -- выход порции
  if p_out_g is not null and p_out_g > 0 and p_out_g is distinct from d.out_g then
    update dishes set out_g = p_out_g where id = p_dish;
    insert into techcard_log(dish_id, what, unit, old_qty, new_qty) values (p_dish, 'Выход порции', 'г', d.out_g, p_out_g);
    n := n + 1;
  end if;

  if n > 0 then
    insert into movements(kind, info) values ('Техкарта', d.name || ': изменений — ' || n);
    begin perform dish_nutrition_refresh(p_dish); exception when others then null; end;
  end if;
  return n;
end $$;
revoke all on function kt_save(int, jsonb, int) from public, anon;
grant execute on function kt_save(int, jsonb, int) to authenticated;

notify pgrst, 'reload schema';
