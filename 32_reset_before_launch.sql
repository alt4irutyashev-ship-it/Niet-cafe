-- Niet Café 32: СБРОС ПЕРЕД ЗАПУСКОМ — удаляет всю статистику (и демо-данные, и любые тестовые заказы).
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run.  ⚠ Отменить нельзя!
--
-- УДАЛЯЕТСЯ: все заказы и позиции, отмены, заявки гостей (стол/доставка/самовывоз), вызовы официанта,
--            приходы, списания, инвентаризации, журнал склада, история цен. Номера заказов начнутся с 1.
-- ОСТАЁТСЯ:  меню, фото, описания, техкарты, продукты, сотрудники, настройки и затраты, ссылки, подписки на push.
-- ЦЕНЫ И ОСТАТКИ продуктов, стоп-лист: если загружали демо (файл 31) — возвращаются к состоянию ДО демо.
--
-- Хотите начать склад с нуля (а потом внести первые приходы / инвентаризацию) — уберите «--» в блоке «ПО ЖЕЛАНИЮ» внизу.

do $reset$
declare tb text; L text[] := '{}';
begin
  -- 1. вернуть цены, остатки и стоп-лист как до демо (автостоп на это время выключен, чтобы не писал в журнал)
  begin execute 'alter table products disable trigger products_autostop_t'; exception when others then null; end;
  if to_regclass('public.demo_backup_products') is not null then
    update products p set price = b.price, s_kitchen = b.s_kitchen, s_bar = b.s_bar from demo_backup_products b where b.id = p.id;
    drop table demo_backup_products;
  end if;
  if to_regclass('public.demo_backup_dishes') is not null then
    update dishes d set stop = b.stop, stop_auto = b.stop_auto from demo_backup_dishes b where b.id = d.id;
    drop table demo_backup_dishes;
  end if;
  update dishes set stop = false, stop_auto = false where stop_auto;   -- автоматический стоп от тестов снимаем
  begin execute 'alter table products enable trigger products_autostop_t'; exception when others then null; end;

  -- 2. удалить статистику (номера заказов начнутся с 1)
  foreach tb in array array['item_costs','order_log','order_items','orders','guest_orders','calls','receipts','movements','stock_log','price_history'] loop
    if to_regclass('public.'||tb) is not null then L := L || tb; end if;
  end loop;
  execute 'truncate table '||array_to_string(L, ', ')||' restart identity cascade';
end $reset$;

-- ПО ЖЕЛАНИЮ: обнулить остатки всех продуктов (кухня и бар). Уберите «--» в начале следующей строки:
-- alter table products disable trigger products_autostop_t; update products set s_kitchen = 0, s_bar = 0; alter table products enable trigger products_autostop_t;

select (select count(*) from orders) as "Заказов", (select count(*) from receipts) as "Приходов", (select count(*) from movements) as "Записей в журнале",
       (select count(*) from dishes where not coalesce(archived,false)) as "Блюд в меню", (select count(*) from recipes) as "Строк техкарт",
       (select count(*) from products) as "Продуктов";
