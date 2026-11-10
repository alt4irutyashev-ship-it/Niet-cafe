-- Niet Café: защита от дублей заказов + приходы товара + история цен продуктов.
-- Выполнить ОДИН раз в Supabase -> SQL Editor -> New query -> Run. Можно запускать повторно.
-- ВАЖНО: сначала выполните этот скрипт, и только потом загружайте новые index.html / guest.html / sw.js.

-- 1. Защита от повторной вставки позиции (повтор очереди, потеря связи, двойное нажатие):
--    каждая позиция получает уникальный ключ cid, повтор с тем же ключом игнорируется.
alter table order_items add column if not exists cid text;
create unique index if not exists order_items_cid_u on order_items(cid);

-- 2. Заказ с телефона гостя: ключ отправки + защита от повторов
alter table guest_orders add column if not exists token text;
create unique index if not exists guest_orders_token_u on guest_orders(token);

drop function if exists guest_order(int,jsonb,text);
create or replace function guest_order(t int, its jsonb, n text, k text default null) returns int
language plpgsql security definer set search_path=public as $$
declare oid int; clean jsonb; nn text := left(coalesce(n,''),300); kk text := nullif(left(coalesce(k,''),64),'');
begin
  if t is null or t < 1 or t > 30 then raise exception 'Неверный стол'; end if;
  if kk is not null then
    select id into oid from guest_orders where token=kk;
    if found then return oid; end if;
  end if;
  select jsonb_agg(jsonb_build_object('dish_id',d.id,'qty',least(greatest((x->>'qty')::int,1),20)))
    into clean
    from jsonb_array_elements(its) x join dishes d on d.id=(x->>'dish_id')::int and not coalesce(d.stop,false);
  if clean is null or jsonb_array_length(clean) > 40 then raise exception 'Пустой заказ'; end if;
  -- такой же заказ за этот стол ещё ждёт официанта — не создаём второй
  select id into oid from guest_orders
   where tbl=t and status='new' and items=clean and coalesce(note,'')=nn and created > now() - interval '3 minutes' limit 1;
  if found then return oid; end if;
  if (select count(*) from guest_orders where tbl=t and created > now() - interval '1 minute') >= 3 then raise exception 'Слишком часто'; end if;
  insert into guest_orders(tbl,items,note,token) values(t,clean,nn,kk)
    on conflict (token) do nothing returning id into oid;
  if oid is null then select id into oid from guest_orders where token=kk; end if;
  return oid;
end$$;
grant execute on function guest_order(int,jsonb,text,text) to anon, authenticated;

-- 3. Принять заказ гостя: один раз и атомарно (два официанта / двойное нажатие больше не удваивают заказ)
create or replace function guest_accept(p_id int) returns boolean
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; o int;
begin
  if my_role() not in ('waiter','boss') then raise exception 'Нет доступа'; end if;
  update guest_orders set status='accepted' where id=p_id and status='new' returning * into g;
  if not found then return false; end if;
  select id into o from orders where tbl=g.tbl and status='open' order by id limit 1;
  if o is null then insert into orders(tbl) values(g.tbl) returning id into o; end if;
  insert into order_items(order_id,tbl,dish_id,qty,station,note,cid)
  select o, g.tbl, d.id, least(greatest((x.v->>'qty')::int,1),20), d.station,
         case when x.n=1 then g.note end, 'g'||p_id||'_'||x.n
    from jsonb_array_elements(g.items) with ordinality as x(v,n)
    join dishes d on d.id=(x.v->>'dish_id')::int;
  return true;
end$$;
revoke execute on function guest_accept(int) from public, anon;
grant execute on function guest_accept(int) to authenticated;

-- 4. Приходы товара: что пришло, сколько, по какой цене и какой остаток на складе стал
create table if not exists receipts(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  product_id int not null references products(id) on delete cascade,
  qty numeric not null,
  price numeric not null default 0,      -- цена за единицу в этом приходе
  sum numeric not null default 0,        -- qty * price
  balance_after numeric,                 -- остаток на складе после прихода
  note text,
  uid uuid default auth.uid()
);
create index if not exists receipts_p on receipts(product_id,t);
alter table receipts enable row level security;
drop policy if exists receipts_r on receipts;
create policy receipts_r on receipts for select using (my_role() in ('boss','store'));

create or replace function stock_receive(p_id int, p_qty numeric, p_price numeric default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p products%rowtype; pr numeric; nb numeric;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Неверное количество'; end if;
  select * into p from products where id=p_id for update;
  if not found then raise exception 'Продукт не найден'; end if;
  pr := coalesce(nullif(p_price,0), p.price, 0);
  nb := coalesce(p.s_main,0) + p_qty;
  update products set s_main=nb, price=pr where id=p_id;      -- смена цены сама попадёт в историю цен
  insert into receipts(product_id,qty,price,sum,balance_after,note) values(p_id,p_qty,pr,pr*p_qty,nb,p_note);
  insert into movements(kind,info) values('Приход', p.name||': +'||p_qty||' '||p.unit||' × '||pr||' = '||round(pr*p_qty));
  return jsonb_build_object('balance',nb,'price',pr);
end$$;
revoke execute on function stock_receive(int,numeric,numeric,text) from public, anon;
grant execute on function stock_receive(int,numeric,numeric,text) to authenticated;

-- 5. Кладовщик тоже видит историю цен продуктов (раньше только руководитель)
drop policy if exists price_history_store on price_history;
create policy price_history_store on price_history for select using (my_role()='store' and kind='product');

-- ===== ПРОВЕРКА (необязательно, выполнить отдельно): уже существующие дубли позиций в открытых заказах =====
-- select order_id, label, dish_id, count(*) as штук, array_agg(id order by id) as ids
--   from order_items where status='new' group by 1,2,3 having count(*)>1;
