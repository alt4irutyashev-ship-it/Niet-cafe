-- Niet Café 29: отмена блюд руководителем, инвентаризация на сервере, % обслуживания из настроек,
-- автостоп блюд по остаткам, «Официант идёт ✓» для гостя, хиты для гостевой страницы.
-- Выполнить ПОСЛЕ 28_nutrition_auto.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.

alter table products add column if not exists station text not null default 'kitchen';

-- 1. ОТМЕНА БЛЮДА ПОСЛЕ КУХНИ ------------------------------------------------------------------------
-- Официант отменяет только то, что кухня ещё не приняла. Принятое/готовое отменяет руководитель:
-- с причиной, можно отменить часть порций; если продукты уже списаны — можно вернуть их на склад
-- (если блюдо не успели приготовить) или оставить списанными (блюдо испорчено — это потеря).
alter table order_log add column if not exists reason text;
alter table order_log add column if not exists returned boolean not null default false;
alter table order_log add column if not exists price numeric;
alter table order_log add column if not exists cost numeric;

create or replace function item_cancel(p_item bigint, p_qty int, p_reason text, p_return boolean default false)
returns jsonb language plpgsql security definer set search_path=public as $$
declare it order_items%rowtype; o orders%rowtype; q int; ret boolean; c numeric;
begin
  if my_role() is distinct from 'boss' then raise exception 'Отменять принятые блюда может только руководитель'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'Укажите причину отмены'; end if;
  select * into it from order_items where id = p_item for update;
  if not found then raise exception 'Позиция не найдена'; end if;
  select * into o from orders where id = it.order_id;
  if o.status is distinct from 'open' then raise exception 'Заказ уже закрыт'; end if;
  q := least(greatest(coalesce(p_qty, it.qty), 1), it.qty);
  c := coalesce((select cost from item_costs where item_id = it.id), it.cost);   -- себестоимость порции на момент заказа
  ret := coalesce(p_return,false) and coalesce(it.stocked,false);
  if ret then   -- вернуть продукты на склад (брутто, с учётом потери при чистке)
    update products p set
      s_kitchen = case when p.station='kitchen' then p.s_kitchen + r.qty*q/(1-least(coalesce(p.loss_pct,0),99)/100) else p.s_kitchen end,
      s_bar     = case when p.station='bar'     then p.s_bar     + r.qty*q/(1-least(coalesce(p.loss_pct,0),99)/100) else p.s_bar end
    from recipes r where r.product_id = p.id and r.dish_id = it.dish_id;
  end if;
  if q >= it.qty then
    delete from order_items where id = p_item;               -- журнал пишет триггер items_cancel_t
    update order_log set reason = trim(p_reason), returned = ret, price = it.price, cost = c
     where id = (select max(id) from order_log where order_id = it.order_id and dish_id = it.dish_id);
  else
    update order_items set qty = qty - q where id = p_item;
    insert into order_log(order_id,label,dish_id,qty,station,was,uid,reason,returned,price,cost)
    values(it.order_id,it.label,it.dish_id,q,it.station,it.status,auth.uid(),trim(p_reason),ret,it.price,c);
  end if;
  return jsonb_build_object('qty',q,'returned',ret,'sum',q*coalesce(it.price,0));
end$$;
revoke execute on function item_cancel(bigint,int,text,boolean) from public, anon;
grant execute on function item_cancel(bigint,int,text,boolean) to authenticated;

-- 2. ИНВЕНТАРИЗАЦИЯ НА СЕРВЕРЕ ---------------------------------------------------------------------
-- p_items = [{"id": 12, "fact": 3.5}, ...]; пустые строки не присылаются.
create or replace function stock_inventory(p_loc text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare x jsonb; p products%rowtype; loc text; cur numeric; f numeric; d numeric; sh numeric := 0; ex numeric := 0; n int := 0; ln text[] := '{}';
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  loc := case when p_loc in ('bar','s_bar') then 'bar' else 'kitchen' end;
  for x in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    f := (x->>'fact')::numeric;
    if f is null or f < 0 then continue; end if;
    select * into p from products where id = (x->>'id')::int for update;
    if not found then continue; end if;
    cur := case loc when 'bar' then coalesce(p.s_bar,0) else coalesce(p.s_kitchen,0) end;
    d := f - cur;
    if abs(d) < 1e-9 then continue; end if;
    update products set s_bar = case when loc='bar' then f else s_bar end, s_kitchen = case when loc='kitchen' then f else s_kitchen end where id = p.id;
    if d < 0 then sh := sh + (-d)*coalesce(p.price,0); else ex := ex + d*coalesce(p.price,0); end if;
    ln := ln || (p.name||': '||case when d>0 then '+' else '' end||round(d,3)||' '||p.unit);
    insert into movements(kind,info,product_id,qty,amount,reason,loc)
    values(case when d<0 then 'Недостача' else 'Излишек' end, p.name||': '||round(d,3)||' '||p.unit||' ('||case loc when 'bar' then 'бар' else 'кухня' end||')',
           p.id, d, round(abs(d)*coalesce(p.price,0)), 'инвентаризация', loc);
    n := n + 1;
  end loop;
  if n = 0 then return jsonb_build_object('n',0,'short',0,'extra',0); end if;
  insert into movements(kind,info,amount,reason,loc)
  values('Инвентаризация', case loc when 'bar' then 'бар' else 'кухня' end||': '||array_to_string(ln,'; ')||'. Недостача '||round(sh)||' ₸, излишки '||round(ex)||' ₸',
         round(sh), 'инвентаризация', loc);
  return jsonb_build_object('n',n,'short',round(sh),'extra',round(ex));
end$$;
revoke execute on function stock_inventory(text,jsonb) from public, anon;
grant execute on function stock_inventory(text,jsonb) to authenticated;

-- 3. ПРОЦЕНТ ОБСЛУЖИВАНИЯ — ИЗ НАСТРОЕК («Затраты»), а не всегда 10% ------------------------------
create or replace function orders_service() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    new.service_pct := case when new.kind in ('take','delivery') then 0 else coalesce((select val from settings where key='service'),10) end;
  elsif auth.uid() is not null and my_role() is distinct from 'boss' then
    new.service_pct := old.service_pct;   -- менять процент и тип заказа может только руководитель
    new.kind := old.kind;
  end if;
  return new;
end $$;
-- руководитель поменял % в «Затратах» → открытые заказы в зале получают новый %
create or replace function settings_service_sync() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.key = 'service' and new.val is distinct from coalesce(old.val, -1) then
    update orders set service_pct = new.val where status = 'open' and coalesce(kind,'dine') not in ('take','delivery');
  end if;
  return null;
end $$;
drop trigger if exists settings_service_t on settings;
create trigger settings_service_t after insert or update on settings for each row execute function settings_service_sync();
update orders set service_pct = coalesce((select val from settings where key='service'),10)
 where status = 'open' and coalesce(kind,'dine') not in ('take','delivery');

-- 4. АВТОСТОП ПО ОСТАТКАМ ----------------------------------------------------------------------------
-- Когда продукта на складе становится меньше, чем нужно на одну порцию, блюда с ним сами уходят в «Стоп»
-- (только при переходе «было — закончилось», поэтому продукты, которые вы не ведёте по складу и у которых 0, ничего не стопят).
-- Пришёл продукт (приход, инвентаризация) — блюдо само возвращается, если на порцию хватает всех продуктов.
-- Блюда, поставленные в стоп вручную, автоматика не трогает. Выключить: «Остатки» → «Автостоп».
alter table dishes add column if not exists stop_auto boolean not null default false;
insert into settings(key,val) values('autostop',1) on conflict (key) do nothing;

create or replace function dish_can_make(p_dish int) returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(bool_and((case when p.station='bar' then p.s_bar else p.s_kitchen end) >= r.qty/(1-least(coalesce(p.loss_pct,0),99)/100) - 1e-9), true)
    from recipes r join products p on p.id = r.product_id where r.dish_id = p_dish
$$;

create or replace function products_autostop() returns trigger language plpgsql security definer set search_path=public as $$
declare d record; need numeric; was_ok boolean; now_ok boolean;
begin
  if coalesce((select val from settings where key='autostop'),1) = 0 then return null; end if;
  if (new.s_kitchen, new.s_bar, new.station) is not distinct from (old.s_kitchen, old.s_bar, old.station) then return null; end if;
  for d in select ds.id, ds.name, ds.stop, ds.stop_auto, max(r.qty) qty
             from recipes r join dishes ds on ds.id = r.dish_id
            where r.product_id = new.id and not coalesce(ds.archived,false)
            group by ds.id, ds.name, ds.stop, ds.stop_auto loop
    need   := d.qty/(1-least(coalesce(new.loss_pct,0),99)/100);
    was_ok := (case when old.station='bar' then coalesce(old.s_bar,0) else coalesce(old.s_kitchen,0) end) >= need - 1e-9;
    now_ok := (case when new.station='bar' then coalesce(new.s_bar,0) else coalesce(new.s_kitchen,0) end) >= need - 1e-9;
    if was_ok and not now_ok and not coalesce(d.stop,false) then
      update dishes set stop = true, stop_auto = true where id = d.id;
      insert into movements(kind,info,product_id) values('Автостоп', '⛔ '||d.name||' — в стоп: закончился «'||new.name||'»', new.id);
    elsif now_ok and d.stop and d.stop_auto and dish_can_make(d.id) then
      update dishes set stop = false, stop_auto = false where id = d.id;
      insert into movements(kind,info,product_id) values('Автостоп', '✅ '||d.name||' — снова в меню: пополнен «'||new.name||'»', new.id);
    end if;
  end loop;
  return null;
end $$;
drop trigger if exists products_autostop_t on products;
create trigger products_autostop_t after update of s_kitchen, s_bar, station on products for each row execute function products_autostop();
revoke execute on function products_autostop() from public, anon;

-- 5. «ОФИЦИАНТ ИДЁТ ✓» ---------------------------------------------------------------------------
-- guest_call теперь возвращает номер вызова, гость видит, когда официант нажал «Иду».
alter table calls add column if not exists done_at timestamptz;
create or replace function calls_done_at() returns trigger language plpgsql as $$
begin
  if new.done and not coalesce(old.done,false) then new.done_at := now(); end if;
  return new;
end $$;
drop trigger if exists calls_done_at_t on calls;
create trigger calls_done_at_t before update on calls for each row execute function calls_done_at();

drop function if exists guest_call(int,text);
create function guest_call(t int, k text) returns int
language plpgsql security definer set search_path=public as $$
declare v int;
begin
  if t is null or t < 1 or t > 99 or k not in ('waiter','bill') then raise exception 'Неверный запрос'; end if;
  select id into v from calls where tbl=t and kind=k and not done and created > now() - interval '2 minutes' order by id desc limit 1;
  if v is not null then return v; end if;
  insert into calls(tbl,kind) values(t,k) returning id into v;
  return v;
end$$;
revoke execute on function guest_call(int,text) from public;
grant execute on function guest_call(int,text) to anon, authenticated;

create or replace function guest_call_status(i int) returns jsonb
language sql stable security definer set search_path=public as $$
  select jsonb_build_object('done', done, 'kind', kind) from calls where id = i and created > now() - interval '1 hour'
$$;
revoke execute on function guest_call_status(int) from public;
grant execute on function guest_call_status(int) to anon, authenticated;

-- 6. ХИТЫ ДЛЯ ГОСТЕВОЙ СТРАНИЦЫ: самые заказываемые блюда за 30 дней (только номера блюд, без сумм) --
create or replace function guest_hits() returns table(dish_id int, n bigint)
language sql stable security definer set search_path=public as $$
  select i.dish_id, sum(i.qty)::bigint
    from order_items i join dishes d on d.id = i.dish_id and not coalesce(d.archived,false) and not coalesce(d.stop,false)
   where i.created > now() - interval '30 days'
   group by i.dish_id order by 2 desc limit 10
$$;
revoke execute on function guest_hits() from public;
grant execute on function guest_hits() to anon, authenticated;

-- ручной «Стоп»/«Снять стоп» отключает автоматику для блюда (кухня, бар, руководитель)
create or replace function set_stop(d int, s boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('kitchen','bar','boss') then raise exception 'Нет прав'; end if;
  update dishes set stop = s, stop_auto = false where id = d and (my_role() = 'boss' or station = my_role());
end$$;
revoke all on function set_stop(int,boolean) from public, anon;
grant execute on function set_stop(int,boolean) to authenticated;

-- 7. РАЗНЫЕ ЗВУКИ: push-уведомления получают свой тип (вызов, счёт, заказ со стола, доставка, самовывоз) ---
create or replace function push_guest_order() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send(jsonb_build_array(jsonb_build_object('kind', case new.kind when 'delivery' then 'delivery' when 'take' then 'take' else 'gorder' end,
    'to_role','waiter','tag','g_'||new.id,
    'title', case new.kind when 'delivery' then '🛵 Доставка' when 'take' then '🥡 Самовывоз' else '📱 Заказ со стола '||new.tbl end,
    'body', (select string_agg((x->>'qty')||'× '||coalesce(d.name,'блюдо'),', ') from jsonb_array_elements(new.items) x left join dishes d on d.id=(x->>'dish_id')::int)
            || case when new.sum is not null then E'\n💰 '||round(new.sum+coalesce(new.fee,0))||' ₸' else '' end)));
  return null;
exception when others then return null;
end $$;
create or replace function push_call() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send(jsonb_build_array(jsonb_build_object('kind', case new.kind when 'bill' then 'bill' else 'call' end,'to_role','waiter','tag','call_'||new.tbl,
    'title', case new.kind when 'bill' then '🧾 Стол '||new.tbl||' просит счёт' else '🙋 Стол '||new.tbl||' зовёт официанта' end, 'body','')));
  return null;
exception when others then return null;
end $$;
revoke execute on function push_guest_order() from public, anon;
revoke execute on function push_call() from public, anon;

notify pgrst, 'reload schema';
