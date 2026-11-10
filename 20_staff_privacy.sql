-- Niet Café: повар, бармен и официант не видят себестоимость и затраты кафе.
-- Выполнить ПОСЛЕ 19_fixes.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run.
-- Можно запускать повторно. Вместе с ним обязательно выложите новый index.html
-- (отчёт руководителя берёт себестоимость из новой таблицы).
--
-- Что было: экраны кухни и бара деньги не показывали, но через API любой сотрудник мог прочитать
--   • себестоимость каждой позиции заказа (order_items.cost) — она же приходила кухне в живых обновлениях;
--   • таблицу settings: ФОТ, аренда, коммунальные, прочие затраты, план порций.
-- Что стало:
--   • себестоимость позиции хранится в отдельной таблице item_costs — её видит только руководитель;
--   • из settings сотрудники видят только «обслуживание %» (нужно официанту для счёта).

-- ===== 1. Затраты кафе — только руководителю =====
drop policy if exists set_r on settings;
create policy set_r on settings for select using (my_role()='boss' or (my_role()<>'none' and key='service'));

-- ===== 2. Себестоимость позиций — отдельная таблица только для руководителя =====
create table if not exists item_costs(
  item_id int primary key references order_items(id) on delete cascade,
  cost numeric not null default 0);
alter table item_costs enable row level security;
drop policy if exists item_costs_boss on item_costs;
create policy item_costs_boss on item_costs for select using (my_role()='boss');
revoke all on item_costs from anon;

-- Перед вставкой: себестоимость (её уже посчитали триггеры oi_snap/items_before) запоминается
-- и стирается из строки заказа. После вставки: записывается в item_costs.
-- Два шага нужны из-за защиты от дублей: у пропущенного дубля «после вставки» не срабатывает.
create or replace function oi_cost_hide() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform set_config('niet.cost_'||new.id, coalesce(new.cost,0)::text, true);
  new.cost := null;
  return new;
end $$;
create or replace function oi_cost_save() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into item_costs(item_id,cost)
  values(new.id, coalesce(nullif(current_setting('niet.cost_'||new.id, true),''),'0')::numeric)
  on conflict(item_id) do update set cost=excluded.cost;
  return new;
end $$;
-- «zz_» — чтобы сработал последним, после расчёта себестоимости
drop trigger if exists zz_cost_hide_t on order_items;
create trigger zz_cost_hide_t before insert on order_items for each row execute function oi_cost_hide();
drop trigger if exists zz_cost_save_t on order_items;
create trigger zz_cost_save_t after insert on order_items for each row execute function oi_cost_save();
revoke execute on function oi_cost_hide() from public, anon;
revoke execute on function oi_cost_save() from public, anon;

-- Перенос уже сохранённой себестоимости старых заказов (триггеры на время отключаются,
-- чтобы не сработали уведомления и проверки статусов).
do $$
begin
  insert into item_costs(item_id,cost) select id, cost from order_items where cost is not null
  on conflict(item_id) do update set cost=excluded.cost;
  alter table order_items disable trigger user;
  update order_items set cost=null where cost is not null;
  alter table order_items enable trigger user;
end $$;

-- Проверка (необязательно): должно вернуть 0
-- select count(*) from order_items where cost is not null;
