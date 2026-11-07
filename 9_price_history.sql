-- Niet Café: история цен + фиксация цены и себестоимости в заказе.
-- Выполнить ОДИН раз ПОСЛЕ 8_fixes.sql: Supabase -> SQL Editor -> New query -> Run. Можно запускать повторно.
--
-- Что даёт:
--  • каждая позиция заказа запоминает цену блюда и себестоимость (по техкарте и ценам продуктов) НА МОМЕНТ заказа;
--    изменение цен в будущем не затрагивает прошлые продажи и отчёты;
--  • журнал изменения цен блюд и продуктов: когда, было → стало, кто изменил (вкладка «Хронология → Изменение цен»).
-- Важно: цены ДО запуска этого скрипта восстановить невозможно — старые заказы получают цены на момент запуска.

-- 1. Фиксация цены и себестоимости в позиции заказа
alter table order_items add column if not exists price numeric;
alter table order_items add column if not exists cost numeric;   -- себестоимость ОДНОЙ порции по продуктам

update order_items i set price=d.price from dishes d where d.id=i.dish_id and i.price is null;
update order_items i set cost=(select coalesce(sum(r.qty*p.price),0) from recipes r join products p on p.id=r.product_id where r.dish_id=i.dish_id) where i.cost is null;

create or replace function items_before() returns trigger language plpgsql security definer set search_path=public as $$
declare o orders%rowtype;
begin
  if tg_op='INSERT' then
    select * into o from orders where id=new.order_id;
    new.label := case when o.kind='take' then 'Вынос-'||coalesce(o.tk_no::text,'?') else 'Стол '||o.tbl end;
    new.tbl := o.tbl;
    new.batch := coalesce(new.batch, gen_random_uuid());
    new.waiter := coalesce(new.waiter, auth.uid());
    new.price := (select price from dishes where id=new.dish_id);   -- всегда из меню, подделать с клиента нельзя
    new.cost  := (select coalesce(sum(r.qty*p.price),0) from recipes r join products p on p.id=r.product_id where r.dish_id=new.dish_id);
  elsif new.status is distinct from old.status and auth.uid() is not null then
    if new.status='accepted' then new.accepted_at:=now(); new.accepted_by:=auth.uid();
    elsif new.status='ready' then
      new.ready_at:=now(); new.ready_by:=auth.uid();
      if new.accepted_at is null then new.accepted_at:=now(); new.accepted_by:=auth.uid(); end if;
    elsif new.status='served' then new.served_at:=now();
    end if;
  end if;
  return new;
end $$;

-- 2. Журнал изменения цен
create table if not exists price_history(
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('dish','product')),
  item_id bigint not null,
  price numeric not null,          -- новая цена
  old_price numeric,               -- прежняя цена (null = начальная запись)
  t timestamptz not null default now(),
  uid uuid default auth.uid()      -- кто изменил
);
create index if not exists price_history_i on price_history(kind,item_id,t);
alter table price_history enable row level security;
drop policy if exists price_history_boss on price_history;
create policy price_history_boss on price_history for select using (my_role()='boss');

create or replace function price_log() returns trigger language plpgsql security definer set search_path=public as $$
declare k text := case tg_table_name when 'dishes' then 'dish' else 'product' end;
begin
  if tg_op='INSERT' then
    insert into price_history(kind,item_id,price,old_price) values(k,new.id,coalesce(new.price,0),null);
  elsif new.price is distinct from old.price then
    insert into price_history(kind,item_id,price,old_price) values(k,new.id,coalesce(new.price,0),coalesce(old.price,0));
  end if;
  return null;
end $$;
drop trigger if exists dishes_price_log on dishes;
create trigger dishes_price_log after insert or update of price on dishes for each row execute function price_log();
drop trigger if exists products_price_log on products;
create trigger products_price_log after insert or update of price on products for each row execute function price_log();

-- начальные записи: текущая цена каждого блюда и продукта (точка отсчёта истории)
insert into price_history(kind,item_id,price) select 'dish',d.id,coalesce(d.price,0) from dishes d where not exists(select 1 from price_history h where h.kind='dish' and h.item_id=d.id);
insert into price_history(kind,item_id,price) select 'product',p.id,coalesce(p.price,0) from products p where not exists(select 1 from price_history h where h.kind='product' and h.item_id=p.id);
