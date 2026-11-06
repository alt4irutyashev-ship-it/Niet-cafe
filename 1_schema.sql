-- Niet Café: схема + права доступа. Выполнить целиком в Supabase -> SQL Editor.
create table profiles(id uuid primary key references auth.users on delete cascade, name text, role text not null default 'none');
create table cats(id int primary key, name text);
create table dishes(id int primary key, cat_id int, name text, price numeric, station text default 'kitchen');
create table products(id serial primary key, name text, unit text default 'кг', price numeric default 0, s_main numeric default 0, s_kitchen numeric default 0, s_bar numeric default 0);
create table recipes(dish_id int references dishes on delete cascade, product_id int references products on delete cascade, qty numeric, primary key(dish_id,product_id));
create table orders(id serial primary key, tbl int, status text default 'open', pay text, waiter uuid default auth.uid(), created timestamptz default now(), closed timestamptz);
create table order_items(id serial primary key, order_id int references orders on delete cascade, tbl int, dish_id int references dishes, qty int default 1, station text, status text default 'new', created timestamptz default now());
create table movements(id serial primary key, t timestamptz default now(), kind text, info text, uid uuid default auth.uid());
create table settings(key text primary key, val numeric);
insert into settings values('labor',1200000),('rent',600000),('util',250000),('portions',6000);

create function my_role() returns text language sql stable security definer set search_path=public as
$$select coalesce((select role from profiles where id=auth.uid()),'none')$$;

-- первый зарегистрированный пользователь становится руководителем, остальные без роли
create function new_user() returns trigger language plpgsql security definer set search_path=public as
$$begin insert into profiles(id,name,role) values(new.id,split_part(new.email,'@',1),case when exists(select 1 from profiles) then 'none' else 'boss' end);return new;end$$;
create trigger on_new_user after insert on auth.users for each row execute function new_user();

-- при закрытии заказа: время + автосписание по техкартам
create function on_close() returns trigger language plpgsql security definer set search_path=public as $$begin
 if new.status='closed' and old.status<>'closed' then
  new.closed=now();
  update products p set s_kitchen=p.s_kitchen-x.q from (select r.product_id pid,sum(r.qty*i.qty) q from order_items i join recipes r on r.dish_id=i.dish_id where i.order_id=new.id and i.station='kitchen' group by 1) x where p.id=x.pid;
  update products p set s_bar=p.s_bar-x.q from (select r.product_id pid,sum(r.qty*i.qty) q from order_items i join recipes r on r.dish_id=i.dish_id where i.order_id=new.id and i.station='bar' group by 1) x where p.id=x.pid;
 end if; return new; end$$;
create trigger orders_close before update on orders for each row execute function on_close();

-- права: руководитель может всё
alter table profiles enable row level security;
do $$ declare t text; begin
 foreach t in array array['cats','dishes','products','recipes','orders','order_items','movements','settings'] loop
  execute format('alter table %I enable row level security',t);
  execute format('create policy boss_all on %I for all using (my_role()=''boss'') with check (my_role()=''boss'')',t);
 end loop; end$$;
create policy p_self on profiles for select using (id=auth.uid() or my_role()='boss');
create policy p_boss on profiles for update using (my_role()='boss');

-- меню читают все сотрудники с ролью
create policy cats_r on cats for select using (my_role()<>'none');
create policy dishes_r on dishes for select using (my_role()<>'none');
-- склад: только кладовщик (и руководитель)
create policy store_p on products for all using (my_role()='store') with check (my_role()='store');
create policy store_m on movements for all using (my_role()='store') with check (my_role()='store');
-- официант: заказы и позиции
create policy w_o on orders for all using (my_role()='waiter') with check (my_role()='waiter');
create policy w_i on order_items for all using (my_role()='waiter') with check (my_role()='waiter');
-- кухня и бар: только позиции своей станции
create policy s_r on order_items for select using (station=my_role());
create policy s_u on order_items for update using (station=my_role()) with check (station=my_role());

alter publication supabase_realtime add table order_items;
