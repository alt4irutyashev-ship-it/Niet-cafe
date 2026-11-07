-- Niet Café: «Потеря» в % у продуктов + предчек.
-- Выполнить ОДИН раз ПОСЛЕ 10_service_stock_techcard.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
--
--  1. У каждого продукта поле «Потеря, %» (чистка, обрезь, усушка). По умолчанию 0.
--     Со склада списывается: количество по техкарте × (1 + потеря/100). Пример: 200 г при потере 10% -> 220 г.
--     Себестоимость блюда в заказе тоже считается с потерей.
--  2. Предчек: время печати предчека сохраняется в заказе, стол при этом остаётся открытым.
--  Уже выданные заказы не пересчитываются: потеря действует на позиции, которые станут «Готово» после запуска.

alter table products add column if not exists loss_pct numeric not null default 0;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='products_loss_pct_chk') then
    alter table products add constraint products_loss_pct_chk check (loss_pct>=0 and loss_pct<100);
  end if;
end $$;

alter table orders add column if not exists precheck_at timestamptz;

-- триггер позиций: списание и себестоимость с учётом потери
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
    new.cost  := (select coalesce(sum(r.qty*p.price*(1+coalesce(p.loss_pct,0)/100)),0) from recipes r join products p on p.id=r.product_id where r.dish_id=new.dish_id);
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
        s_kitchen=case when p.station='kitchen' then p.s_kitchen-r.qty*new.qty*(1+coalesce(p.loss_pct,0)/100) else p.s_kitchen end,
        s_bar=case when p.station='bar' then p.s_bar-r.qty*new.qty*(1+coalesce(p.loss_pct,0)/100) else p.s_bar end
      from recipes r where r.product_id=p.id and r.dish_id=new.dish_id;
      new.stocked := true;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists items_before_t on order_items;
create trigger items_before_t before insert or update on order_items for each row execute function items_before();

-- техкарта для кухни/бара/руководителя: теперь с потерей
drop function if exists tech_card(int);
create or replace function tech_card(p_dish int)
returns table(name text, unit text, qty numeric, price numeric, loss_pct numeric)
language sql stable security definer set search_path=public as $$
  select p.name, p.unit, r.qty, case when my_role()='boss' then p.price end, p.loss_pct
  from recipes r
  join products p on p.id=r.product_id
  join dishes d on d.id=r.dish_id
  where r.dish_id=p_dish
    and (my_role()='boss' or (my_role() in ('kitchen','bar') and d.station=my_role()))
  order by p.name
$$;
revoke all on function tech_card(int) from public;
grant execute on function tech_card(int) to authenticated;
