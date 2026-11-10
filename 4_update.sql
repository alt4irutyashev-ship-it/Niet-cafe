-- Niet Café: обновление. Выполнить целиком в Supabase -> SQL Editor (после 1_schema.sql и 2_menu.sql).
-- Можно запускать повторно — ничего не сломается. 3_techcards.sql отдельно запускать не нужно, он включён сюда.

-- новые поля
alter table dishes add column if not exists stop boolean default false;           -- стоп-лист
alter table order_items add column if not exists note text;                        -- комментарий к блюду
alter table orders add column if not exists service numeric default 0;             -- сумма обслуживания
alter table orders add column if not exists total numeric default 0;               -- итог чека
alter table orders add column if not exists p_cash numeric default 0;              -- оплата наличными
alter table orders add column if not exists p_card numeric default 0;              -- оплата картой
alter table orders add column if not exists p_kaspi numeric default 0;             -- оплата Kaspi
alter table products add column if not exists min numeric default 0;               -- минимальный остаток
insert into settings values('service',10) on conflict (key) do nothing;            -- обслуживание, %

-- процент обслуживания нужен официанту
drop policy if exists set_r on settings;
create policy set_r on settings for select using (my_role()<>'none');

-- техкарты: кухня, бар и руководитель (без цен закупки)
create or replace function tech_cards()
returns table(dish_id int, product text, unit text, qty numeric)
language sql stable security definer set search_path=public as $$
  select r.dish_id, p.name, p.unit, r.qty
  from recipes r join products p on p.id = r.product_id
  where my_role() in ('kitchen','bar','boss')
  order by p.name
$$;
revoke all on function tech_cards() from public, anon;
grant execute on function tech_cards() to authenticated;

-- стоп-лист: кухня и бар ставят на свои блюда, руководитель на любые
create or replace function set_stop(d int, s boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('kitchen','bar','boss') then raise exception 'Нет прав'; end if;
  update dishes set stop = s where id = d and (my_role() = 'boss' or station = my_role());
end$$;
revoke all on function set_stop(int,boolean) from public, anon;
grant execute on function set_stop(int,boolean) to authenticated;

-- при закрытии заказа: время, списание по техкартам, неготовые позиции убираются с экранов кухни и бара
create or replace function on_close() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status='closed' and old.status<>'closed' then
  new.closed=now();
  update products p set s_kitchen=p.s_kitchen-x.q from (select r.product_id pid,sum(r.qty*i.qty) q from order_items i join recipes r on r.dish_id=i.dish_id where i.order_id=new.id and i.station='kitchen' group by 1) x where p.id=x.pid;
  update products p set s_bar=p.s_bar-x.q from (select r.product_id pid,sum(r.qty*i.qty) q from order_items i join recipes r on r.dish_id=i.dish_id where i.order_id=new.id and i.station='bar' group by 1) x where p.id=x.pid;
  update order_items set status='done' where order_id=new.id and status in ('new','cooking');
 end if;
 return new;
end$$;

-- старые «зависшие» позиции оплаченных столов тоже убрать
update order_items i set status='done' from orders o
 where o.id=i.order_id and o.status='closed' and i.status in ('new','cooking');

-- стоп-лист и правки меню сразу видны официанту
do $$ begin alter publication supabase_realtime add table dishes; exception when duplicate_object then null; end $$;
