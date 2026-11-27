-- Niet Café 49: надёжность заказов и склада.
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
--
-- 1. Один открытый заказ на стол. Если на столе уже есть два открытых заказа — позиции переносятся в первый,
--    лишний удаляется. Дальше база сама не даст открыть второй (даже если нажали одновременно).
-- 2. Номера выноса и доставки не задваиваются при одновременном приёме заявок.
-- 3. Перенос / объединение столов — одной операцией на сервере.
-- 4. Приход: цена продукта = средневзвешенная (остаток × старая цена + приход × цена прихода) / новый остаток.
--    В накладной (receipts) остаётся фактическая цена прихода.
-- После запуска выложите обновлённые index.html и sw.js (niet-v35).

-- ===== 1. Объединить уже задвоенные открытые заказы =====
do $merge$
declare r record; keep int; n_ord int := 0; n_it int := 0; c int;
begin
  perform set_config('niet.nopush','1',true);       -- без push-уведомлений при переносе
  for r in select tbl, array_agg(id order by id) ids from orders
           where status='open' and tbl is not null group by tbl having count(*) > 1 loop
    keep := r.ids[1];
    update order_items set order_id = keep, tbl = r.tbl where order_id = any(r.ids[2:]);
    get diagnostics c = row_count; n_it := n_it + c;
    if to_regclass('public.order_log') is not null then update order_log set order_id = keep where order_id = any(r.ids[2:]); end if;
    if to_regclass('public.reviews')   is not null then update reviews   set order_id = keep where order_id = any(r.ids[2:]); end if;
    delete from orders where id = any(r.ids[2:]);
    get diagnostics c = row_count; n_ord := n_ord + c;
  end loop;
  raise notice 'Объединено двойных заказов: %, перенесено позиций: %', n_ord, n_it;
  create temp table if not exists fix49_result(merged_orders int, moved_items int) on commit preserve rows;
  delete from fix49_result; insert into fix49_result values(n_ord, n_it);
end $merge$;

-- ===== 2. Запрет второго открытого заказа на том же столе =====
drop index if exists orders_open_tbl_idx;
create unique index if not exists orders_one_open_per_tbl on orders(tbl) where status = 'open';

-- ===== 3. Официант добавляет блюдо =====
create or replace function waiter_add(p_tbl int, p_dish int, p_station text, p_cid text, p_qty int default 1, p_note text default null)
returns jsonb language plpgsql set search_path=public as $$
declare o int;
begin
  loop
    select id into o from orders where tbl = p_tbl and status = 'open';
    exit when o is not null;
    insert into orders(tbl,kind)
    values(p_tbl, case when p_tbl >= 200 then 'delivery' when p_tbl >= 100 then 'take' else 'dine' end)
    on conflict (tbl) where status = 'open' do nothing
    returning id into o;
    exit when o is not null;          -- иначе заказ только что открыл кто-то другой — берём его
  end loop;
  insert into order_items(order_id,tbl,dish_id,station,qty,note,cid)
  values(o, p_tbl, p_dish, p_station, greatest(1,coalesce(p_qty,1)), nullif(trim(coalesce(p_note,'')),''), p_cid)
  on conflict (cid) do nothing;
  return jsonb_build_object('order_id', o);
end $$;
revoke execute on function waiter_add(int,int,text,text,int,text) from public, anon;
grant execute on function waiter_add(int,int,text,text,int,text) to authenticated;

-- ===== 4. Официант принимает заявку гостя (стол / самовывоз / доставка) =====
create or replace function guest_accept(p_id int) returns boolean
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; o int; tn int; k text; lo int; hi int;
begin
  if my_role() not in ('waiter','boss') then raise exception 'Нет доступа'; end if;
  update guest_orders set status='accepted' where id=p_id and status='new' returning * into g;
  if not found then return false; end if;
  if g.tbl >= 200 or g.kind='delivery' then k := 'delivery'; lo := 201; hi := 299;
  elsif g.tbl >= 100 then k := 'take'; lo := 101; hi := 199;
  end if;
  if k is not null then
    -- свободный номер: если его в ту же секунду занял другой заказ, берём следующий
    for tn in select n from generate_series(lo,hi) n
              where not exists(select 1 from orders where tbl=n and status='open') order by n loop
      insert into orders(tbl,kind,phone,address,cname,delivery_fee)
      values(tn,k,g.phone,g.address,g.cname,coalesce(g.fee,0))
      on conflict (tbl) where status = 'open' do nothing
      returning id into o;
      exit when o is not null;
    end loop;
    if o is null then raise exception 'Нет свободных номеров для заказов'; end if;
  else
    loop
      select id into o from orders where tbl=g.tbl and status='open';
      exit when o is not null;
      insert into orders(tbl,kind) values(g.tbl,'dine')
      on conflict (tbl) where status = 'open' do nothing
      returning id into o;
      exit when o is not null;
    end loop;
  end if;
  insert into order_items(order_id,tbl,dish_id,qty,station,note,cid)
  select o, (select tbl from orders where id=o), d.id, least(greatest((x.v->>'qty')::int,1),20), d.station, case when x.n=1 then nullif(g.note,'') end, 'g'||p_id||'_'||x.n
    from jsonb_array_elements(g.items) with ordinality as x(v,n) join dishes d on d.id=(x.v->>'dish_id')::int
  on conflict (cid) do nothing;
  return true;
end $$;
revoke execute on function guest_accept(int) from public, anon;
grant execute on function guest_accept(int) to authenticated;

-- ===== 5. Перенос стола (если новый стол занят — заказы объединяются) =====
create or replace function order_move(p_from int, p_to int) returns jsonb
language plpgsql security definer set search_path=public as $$
declare src int; dst int;
begin
  if my_role() not in ('waiter','boss') then raise exception 'Нет доступа'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'Неверный стол'; end if;
  select id into src from orders where tbl=p_from and status='open' for update;
  if src is null then raise exception 'На столе % нет открытого заказа', p_from; end if;
  loop
    select id into dst from orders where tbl=p_to and status='open' for update;
    if dst is not null then
      update order_items set order_id=dst, tbl=p_to where order_id=src;
      if to_regclass('public.order_log') is not null then execute 'update order_log set order_id=$1 where order_id=$2' using dst, src; end if;
      if to_regclass('public.reviews')   is not null then execute 'update reviews set order_id=$1 where order_id=$2' using dst, src; end if;
      delete from orders where id=src;
      return jsonb_build_object('merged', true, 'order_id', dst);
    end if;
    begin
      update orders set tbl=p_to where id=src;
      update order_items set tbl=p_to where order_id=src;
      return jsonb_build_object('merged', false, 'order_id', src);
    exception when unique_violation then
      null;                           -- стол только что заняли — объединяем на следующем круге
    end;
  end loop;
end $$;
revoke execute on function order_move(int,int) from public, anon;
grant execute on function order_move(int,int) to authenticated;

-- ===== 6. Приход: средневзвешенная цена =====
create or replace function stock_receive(p_id int, p_qty numeric, p_price numeric default null, p_note text default null, p_to text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p products%rowtype; pin numeric; pr numeric; nb numeric; loc text; old_q numeric;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Неверное количество'; end if;
  select * into p from products where id=p_id for update;
  if not found then raise exception 'Продукт не найден'; end if;
  loc := coalesce(nullif(p_to,''), p.station, 'kitchen');
  if loc not in ('kitchen','bar') then loc := 'kitchen'; end if;
  pin := coalesce(nullif(p_price,0), p.price, 0);                                   -- цена этого прихода
  old_q := greatest(coalesce(p.s_kitchen,0),0) + greatest(coalesce(p.s_bar,0),0);   -- что было в наличии (минус = 0)
  if old_q > 0 and coalesce(p.price,0) > 0 then
    pr := trim_scale(round((old_q * p.price + p_qty * pin) / (old_q + p_qty), 2));
  else
    pr := pin;
  end if;
  nb := case loc when 'bar' then coalesce(p.s_bar,0) else coalesce(p.s_kitchen,0) end + p_qty;
  update products set s_bar=case when loc='bar' then nb else s_bar end, s_kitchen=case when loc='kitchen' then nb else s_kitchen end, price=pr where id=p_id;
  insert into receipts(product_id,qty,price,sum,balance_after,note,loc) values(p_id,p_qty,pin,pin*p_qty,nb,p_note,loc);
  insert into movements(kind,info) values('Приход', p.name||': +'||p_qty||' '||p.unit||' × '||pin
    ||case when pr<>pin then ' (средняя цена '||pr||')' else '' end
    ||' → '||case loc when 'bar' then 'бар' else 'кухня' end);
  return jsonb_build_object('balance',nb,'price',pr,'in_price',pin,'loc',loc);
end$$;
revoke execute on function stock_receive(int,numeric,numeric,text,text) from public, anon;
grant execute on function stock_receive(int,numeric,numeric,text,text) to authenticated;

notify pgrst, 'reload schema';

select merged_orders as "Объединено двойных заказов", moved_items as "Перенесено позиций",
       (select count(*) from orders where status='open') as "Открытых заказов сейчас"
  from fix49_result;
