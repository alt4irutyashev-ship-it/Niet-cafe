-- Niet Café: история заказов. Выполнить ОДИН раз в Supabase -> SQL Editor -> New query -> Run. Можно запускать повторно.
-- 1. Быстрый поиск заказов по дате (вкладка «Хронология»)
create index if not exists orders_created_idx on orders(created);

-- 2. Журнал отмен: кто и когда убрал позицию из заказа (раньше такие позиции пропадали бесследно)
create table if not exists order_log(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  order_id int, label text, dish_id int, qty int, station text,
  was text,                       -- статус позиции в момент отмены
  uid uuid default auth.uid()     -- кто отменил
);
create index if not exists order_log_o on order_log(order_id);
create index if not exists order_log_t on order_log(t);
alter table order_log enable row level security;
drop policy if exists order_log_boss on order_log;
create policy order_log_boss on order_log for select using (my_role()='boss');

create or replace function items_cancel_log() returns trigger language plpgsql security definer set search_path=public as $$
begin
  -- если заказ удалён целиком (каскад) — не пишем
  if exists(select 1 from orders where id=old.order_id) then
    insert into order_log(order_id,label,dish_id,qty,station,was,uid)
    values(old.order_id,old.label,old.dish_id,old.qty,old.station,old.status,auth.uid());
  end if;
  return old;
end $$;
drop trigger if exists items_cancel_t on order_items;
create trigger items_cancel_t after delete on order_items for each row execute function items_cancel_log();
