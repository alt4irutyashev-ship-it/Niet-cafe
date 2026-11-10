-- Niet Café 14: без «склада», история заказов со временем, снимок цен, заказ «с собой», приходы.
-- Выполнить ОДИН раз: Supabase -> SQL Editor -> New query -> Run. Можно запускать повторно.
-- Включает всё из 13_dups_receipts.sql (если 13 уже запускали — ничего страшного).
-- СНАЧАЛА этот скрипт, ПОТОМ загружайте index.html / guest.html / sw.js.

-- ===== 1. Заказ «с собой» =====
-- Заказы с собой живут под номерами стола 101, 102, ... (на экране «Вынос-1», «Вынос-2»); 100 = заказ с телефона гостя.
alter table orders add column if not exists kind text not null default 'dine';
alter table orders add column if not exists tk_no int;
create or replace function orders_tk() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.kind='take' and new.tbl is not null then new.tk_no := new.tbl-100; end if;
  return new;
end $$;
drop trigger if exists orders_tk_t on orders;
create trigger orders_tk_t before insert on orders for each row execute function orders_tk();

-- ===== 2. Время каждого этапа блюда: поступил / принят / готово / подано =====
alter table order_items add column if not exists accepted_at timestamptz;
alter table order_items add column if not exists ready_at timestamptz;
alter table order_items add column if not exists served_at timestamptz;
create or replace function oi_times() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status is distinct from old.status then
    if new.status in ('accepted','cooking') then new.accepted_at := coalesce(new.accepted_at, now());
    elsif new.status='ready' then new.accepted_at := coalesce(new.accepted_at, now()); new.ready_at := coalesce(new.ready_at, now());
    elsif new.status='served' then new.served_at := coalesce(new.served_at, now());
    end if;
  end if;
  return new;
end $$;
drop trigger if exists oi_times_t on order_items;
create trigger oi_times_t before update on order_items for each row execute function oi_times();

-- ===== 3. Снимок цены и себестоимости в позиции: смена цены не меняет прошлые отчёты =====
alter table order_items add column if not exists price numeric;
alter table order_items add column if not exists cost numeric;
update order_items i set price=d.price from dishes d where d.id=i.dish_id and i.price is null;
update order_items i set cost=(select coalesce(sum(r.qty*p.price),0) from recipes r join products p on p.id=r.product_id where r.dish_id=i.dish_id) where i.cost is null;
create or replace function oi_snap() returns trigger language plpgsql security definer set search_path=public as $$
begin
  new.price := (select price from dishes where id=new.dish_id);   -- всегда из меню, с клиента подделать нельзя
  new.cost  := (select coalesce(sum(r.qty*p.price),0) from recipes r join products p on p.id=r.product_id where r.dish_id=new.dish_id);
  return new;
end $$;
drop trigger if exists oi_snap_t on order_items;
create trigger oi_snap_t before insert on order_items for each row execute function oi_snap();

-- ===== 4. История изменения цен блюд и продуктов =====
create table if not exists price_history(
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('dish','product')),
  item_id bigint not null,
  price numeric not null,
  old_price numeric,
  t timestamptz not null default now(),
  uid uuid default auth.uid()
);
create index if not exists price_history_i on price_history(kind,item_id,t);
alter table price_history enable row level security;
drop policy if exists price_history_boss on price_history;
create policy price_history_boss on price_history for select using (my_role()='boss');
drop policy if exists price_history_store on price_history;
create policy price_history_store on price_history for select using (my_role()='store' and kind='product');
create or replace function price_log() returns trigger language plpgsql security definer set search_path=public as $$
declare k text := case tg_table_name when 'dishes' then 'dish' else 'product' end;
begin
  if tg_op='INSERT' then insert into price_history(kind,item_id,price,old_price) values(k,new.id,coalesce(new.price,0),null);
  elsif new.price is distinct from old.price then insert into price_history(kind,item_id,price,old_price) values(k,new.id,coalesce(new.price,0),coalesce(old.price,0));
  end if;
  return null;
end $$;
drop trigger if exists dishes_price_log on dishes;
create trigger dishes_price_log after insert or update of price on dishes for each row execute function price_log();
drop trigger if exists products_price_log on products;
create trigger products_price_log after insert or update of price on products for each row execute function price_log();
insert into price_history(kind,item_id,price) select 'dish',d.id,coalesce(d.price,0) from dishes d where not exists(select 1 from price_history h where h.kind='dish' and h.item_id=d.id);
insert into price_history(kind,item_id,price) select 'product',p.id,coalesce(p.price,0) from products p where not exists(select 1 from price_history h where h.kind='product' and h.item_id=p.id);

-- ===== 5. Защита от дублей (ключи позиций и заказов гостя) =====
alter table order_items add column if not exists cid text;
create unique index if not exists order_items_cid_u on order_items(cid);
alter table guest_orders add column if not exists token text;
create unique index if not exists guest_orders_token_u on guest_orders(token);

drop function if exists guest_order(int,jsonb,text);
create or replace function guest_order(t int, its jsonb, n text, k text default null) returns int
language plpgsql security definer set search_path=public as $$
declare oid int; clean jsonb; nn text := left(coalesce(n,''),300); kk text := nullif(left(coalesce(k,''),64),'');
begin
  if t is null or not (t between 1 and 30 or t=100) then raise exception 'Неверный стол'; end if;   -- 100 = заказ с собой
  if kk is not null then select id into oid from guest_orders where token=kk; if found then return oid; end if; end if;
  select jsonb_agg(jsonb_build_object('dish_id',d.id,'qty',least(greatest((x->>'qty')::int,1),20)))
    into clean from jsonb_array_elements(its) x join dishes d on d.id=(x->>'dish_id')::int and not coalesce(d.stop,false);
  if clean is null or jsonb_array_length(clean) > 40 then raise exception 'Пустой заказ'; end if;
  select id into oid from guest_orders where tbl=t and status='new' and items=clean and coalesce(note,'')=nn and created > now() - interval '3 minutes' limit 1;
  if found then return oid; end if;
  if (select count(*) from guest_orders where tbl=t and created > now() - interval '1 minute') >= 3 then raise exception 'Слишком часто'; end if;
  insert into guest_orders(tbl,items,note,token) values(t,clean,nn,kk) on conflict (token) do nothing returning id into oid;
  if oid is null then select id into oid from guest_orders where token=kk; end if;
  return oid;
end$$;
grant execute on function guest_order(int,jsonb,text,text) to anon, authenticated;

-- принять заказ гостя: один раз и атомарно; «с собой» (стол 100) получает свободный номер Вынос-N
create or replace function guest_accept(p_id int) returns boolean
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; o int; tn int;
begin
  if my_role() not in ('waiter','boss') then raise exception 'Нет доступа'; end if;
  update guest_orders set status='accepted' where id=p_id and status='new' returning * into g;
  if not found then return false; end if;
  if g.tbl >= 100 then
    select n into tn from generate_series(101,199) as n where not exists(select 1 from orders where tbl=n and status='open') order by n limit 1;
    insert into orders(tbl,kind) values(tn,'take') returning id into o;
  else
    select id into o from orders where tbl=g.tbl and status='open' order by id limit 1;
    if o is null then insert into orders(tbl,kind) values(g.tbl,'dine') returning id into o; end if;
  end if;
  insert into order_items(order_id,tbl,dish_id,qty,station,note,cid)
  select o, (select tbl from orders where id=o), d.id, least(greatest((x.v->>'qty')::int,1),20), d.station, case when x.n=1 then g.note end, 'g'||p_id||'_'||x.n
    from jsonb_array_elements(g.items) with ordinality as x(v,n) join dishes d on d.id=(x.v->>'dish_id')::int;
  return true;
end$$;
revoke execute on function guest_accept(int) from public, anon;
grant execute on function guest_accept(int) to authenticated;

-- ===== 6. Приходы: сразу на кухню или в бар (склада больше нет) =====
create table if not exists receipts(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  product_id int not null references products(id) on delete cascade,
  qty numeric not null, price numeric not null default 0, sum numeric not null default 0,
  balance_after numeric, note text, uid uuid default auth.uid()
);
alter table receipts add column if not exists loc text;     -- kitchen / bar
create index if not exists receipts_p on receipts(product_id,t);
alter table receipts enable row level security;
drop policy if exists receipts_r on receipts;
create policy receipts_r on receipts for select using (my_role() in ('boss','store'));

drop function if exists stock_receive(int,numeric,numeric,text);
create or replace function stock_receive(p_id int, p_qty numeric, p_price numeric default null, p_note text default null, p_to text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p products%rowtype; pr numeric; nb numeric; loc text;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Неверное количество'; end if;
  select * into p from products where id=p_id for update;
  if not found then raise exception 'Продукт не найден'; end if;
  loc := coalesce(nullif(p_to,''), p.station, 'kitchen');
  if loc not in ('kitchen','bar') then loc := 'kitchen'; end if;
  pr := coalesce(nullif(p_price,0), p.price, 0);
  nb := case loc when 'bar' then coalesce(p.s_bar,0) else coalesce(p.s_kitchen,0) end + p_qty;
  update products set s_bar=case when loc='bar' then nb else s_bar end, s_kitchen=case when loc='kitchen' then nb else s_kitchen end, price=pr where id=p_id;
  insert into receipts(product_id,qty,price,sum,balance_after,note,loc) values(p_id,p_qty,pr,pr*p_qty,nb,p_note,loc);
  insert into movements(kind,info) values('Приход', p.name||': +'||p_qty||' '||p.unit||' × '||pr||' → '||case loc when 'bar' then 'бар' else 'кухня' end);
  return jsonb_build_object('balance',nb,'price',pr,'loc',loc);
end$$;
revoke execute on function stock_receive(int,numeric,numeric,text,text) from public, anon;
grant execute on function stock_receive(int,numeric,numeric,text,text) to authenticated;
-- Остатки, которые раньше лежали на «складе» (колонка s_main), в приложении больше не показываются.
-- Если там что-то есть, внесите это в нужное место через «Инвентаризацию» (кухня / бар).
