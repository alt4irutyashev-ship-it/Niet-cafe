-- Niet Café: обслуживание 10%, списание склада после готовности, запрет отмены после принятия, техкарты для кухни/бара.
-- Выполнить ОДИН раз ПОСЛЕ 9_price_history.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run.
-- Можно запускать повторно (остатки склада при повторном запуске второй раз НЕ пересчитываются).
--
-- Что даёт:
--  1. Заказ «в зале» автоматически получает +10% за обслуживание, «с собой» — без наценки.
--     Процент фиксируется в заказе в момент создания, старые закрытые заказы не меняются.
--  2. Продукты списываются со склада ТОЛЬКО когда кухня/бар приняли позицию и нажали «Готово».
--     Пока позиция «новая» или «в работе» — склад не трогается.
--  3. Официант может убрать позицию только пока её не приняли. После принятия — нельзя
--     (проверяется на сервере, а не только в кнопках).
--  4. Техкарта блюда доступна кухне, бару (только их блюда) и руководителю по нажатию на блюдо.

-- ============ 1. ОБСЛУЖИВАНИЕ 10% ============
alter table orders add column if not exists service_pct numeric not null default 0;

create or replace function orders_service() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    new.service_pct := case when new.kind='take' then 0 else 10 end;   -- стол: 10%, с собой: 0
  elsif auth.uid() is not null and my_role() is distinct from 'boss' then
    new.service_pct := old.service_pct;   -- менять процент и тип заказа может только руководитель
    new.kind := old.kind;
  end if;
  return new;
end $$;
drop trigger if exists orders_service_t on orders;
create trigger orders_service_t before insert or update on orders for each row execute function orders_service();

-- уже открытые заказы в зале тоже получают 10% (закрытые не трогаем)
update orders set service_pct=10 where status='open' and kind<>'take' and service_pct=0;

-- ============ 2. СПИСАНИЕ СО СКЛАДА ПОСЛЕ «ГОТОВО» ============
alter table order_items add column if not exists stocked boolean not null default false;   -- true = продукты по этой позиции уже списаны

-- старая схема списывала при отправке заказа — отключаем
drop trigger if exists order_items_stock on order_items;

-- закрытие заказа: ставит время, невыданные позиции считаются выданными (метка нужна для защиты ниже)
create or replace function on_close() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status='closed' and old.status<>'closed' then
    new.closed=now();
    perform set_config('niet.closing','1',true);
    update order_items set status='served' where order_id=new.id and status<>'served';
  end if;
  return new;
end $$;

create or replace function items_before() returns trigger language plpgsql security definer set search_path=public as $$
declare o orders%rowtype;
begin
  if tg_op='INSERT' then
    select * into o from orders where id=new.order_id;
    new.label := case when o.kind='take' then 'Вынос-'||coalesce(o.tk_no::text,'?') else 'Стол '||o.tbl end;
    new.tbl := o.tbl;
    new.batch := coalesce(new.batch, gen_random_uuid());
    new.waiter := coalesce(new.waiter, auth.uid());
    new.price := (select price from dishes where id=new.dish_id);   -- цена и себестоимость — всегда из меню
    new.cost  := (select coalesce(sum(r.qty*p.price),0) from recipes r join products p on p.id=r.product_id where r.dish_id=new.dish_id);
    new.status := 'new';
    new.stocked := false;
  else
    -- официант: после принятия позицию менять нельзя; статус только «готово» -> «выдано»
    if auth.uid() is not null and my_role()='waiter' then
      if old.status<>'new' and (new.qty is distinct from old.qty or new.dish_id is distinct from old.dish_id) then
        raise exception 'Позицию уже приняли — изменить или отменить её нельзя';
      end if;
      if new.status is distinct from old.status
         and not (old.status='ready' and new.status='served')
         and coalesce(current_setting('niet.closing',true),'')<>'1' then
        raise exception 'Недопустимая смена статуса';
      end if;
    end if;
    if coalesce(current_setting('niet.migr',true),'')<>'1' then new.stocked := old.stocked; end if;   -- флаг списания с клиента не меняется
    if new.status is distinct from old.status and auth.uid() is not null then
      if new.status='accepted' then new.accepted_at:=now(); new.accepted_by:=auth.uid();
      elsif new.status='ready' then
        new.ready_at:=now(); new.ready_by:=auth.uid();
        if new.accepted_at is null then new.accepted_at:=now(); new.accepted_by:=auth.uid(); end if;
      elsif new.status='served' then new.served_at:=now();
      end if;
    end if;
    -- списание по техкарте: один раз, когда позиция принята и приготовлена
    if new.status='ready' and not old.stocked and coalesce(current_setting('niet.migr',true),'')<>'1' then
      update products p set
        s_kitchen=case when p.station='kitchen' then p.s_kitchen-r.qty*new.qty else p.s_kitchen end,
        s_bar=case when p.station='bar' then p.s_bar-r.qty*new.qty else p.s_bar end
      from recipes r where r.product_id=p.id and r.dish_id=new.dish_id;
      new.stocked := true;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists items_before_t on order_items;
create trigger items_before_t before insert or update on order_items for each row execute function items_before();

-- Одноразовый перенос: позиции, которые уже готовы/выданы, уже списаны (stocked=true).
-- Позиции «новые/в работе» были списаны при отправке — возвращаем продукты на склад, они спишутся при «Готово».
do $$ begin
  if not exists(select 1 from settings where key='migr_stock_on_ready') then
    perform set_config('niet.migr','1',true);   -- триггер позиций на время переноса не списывает и не трогает флаг
    update order_items set stocked=true where status in ('ready','served');
    update order_items set ready_at=coalesce(served_at,created) where stocked and ready_at is null;   -- чтобы история продуктов видела время

    update products p set
      s_kitchen=case when p.station='kitchen' then p.s_kitchen+x.q else p.s_kitchen end,
      s_bar=case when p.station='bar' then p.s_bar+x.q else p.s_bar end
    from (select r.product_id pid, sum(r.qty*i.qty) q
          from order_items i join recipes r on r.dish_id=i.dish_id
          where i.status in ('new','accepted','cooking') group by 1) x
    where p.id=x.pid;

    insert into settings(key,val) values('migr_stock_on_ready',1);
  end if;
end $$;

-- ============ 3. ОТМЕНА ТОЛЬКО ДО ПРИНЯТИЯ ============
-- заказы: официант создаёт и обновляет, но не удаляет
drop policy if exists w_o on orders;
drop policy if exists w_o_sel on orders;
drop policy if exists w_o_ins on orders;
drop policy if exists w_o_upd on orders;
create policy w_o_sel on orders for select using (my_role()='waiter');
create policy w_o_ins on orders for insert with check (my_role()='waiter');
create policy w_o_upd on orders for update using (my_role()='waiter') with check (my_role()='waiter');

-- позиции: официант видит и добавляет; удалять/менять количество — только пока статус «новый»
drop policy if exists w_i on order_items;
drop policy if exists w_i_sel on order_items;
drop policy if exists w_i_ins on order_items;
drop policy if exists w_i_upd on order_items;
drop policy if exists w_i_del on order_items;
create policy w_i_sel on order_items for select using (my_role()='waiter');
create policy w_i_ins on order_items for insert with check (my_role()='waiter');
create policy w_i_upd on order_items for update using (my_role()='waiter' and status in ('new','ready')) with check (my_role()='waiter');
create policy w_i_del on order_items for delete using (my_role()='waiter' and status='new');

-- ============ 4. ТЕХКАРТА ДЛЯ КУХНИ / БАРА / РУКОВОДИТЕЛЯ ============
-- Кухня и бар не имеют доступа к таблицам продуктов и техкарт, поэтому читают через эту функцию.
-- Кухня видит только блюда кухни, бар — только блюда бара, руководитель — все. Цены продуктов получает только руководитель.
create or replace function tech_card(p_dish int)
returns table(name text, unit text, qty numeric, price numeric)
language sql stable security definer set search_path=public as $$
  select p.name, p.unit, r.qty, case when my_role()='boss' then p.price end
  from recipes r
  join products p on p.id=r.product_id
  join dishes d on d.id=r.dish_id
  where r.dish_id=p_dish
    and (my_role()='boss' or (my_role() in ('kitchen','bar') and d.station=my_role()))
  order by p.name
$$;
revoke all on function tech_card(int) from public;
grant execute on function tech_card(int) to authenticated;
