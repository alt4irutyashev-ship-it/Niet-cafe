-- Niet Café: исправления расчётов и безопасности (по результатам проверки).
-- Выполнить ОДИН раз: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.

-- 1. СКЛАД: убираем двойное списание.
--    Раньше продукты списывались и при отправке блюда (stock_apply), и ещё раз при закрытии заказа (on_close).
--    Теперь при закрытии только ставится время; несданные позиции считаются выданными (билеты исчезают с кухни/бара).
create or replace function on_close() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status='closed' and old.status<>'closed' then
    new.closed=now();
    update order_items set status='served' where order_id=new.id and status<>'served';
  end if;
  return new;
end $$;

-- 2. ЦЕНА БЛЮДА ФИКСИРУЕТСЯ В МОМЕНТ ЗАКАЗА.
--    Раньше выручка за прошлые дни пересчитывалась по текущей цене меню: поменяли цену — «изменилась» вся история.
alter table order_items add column if not exists price numeric;
update order_items i set price=d.price from dishes d where d.id=i.dish_id and i.price is null;  -- старые заказы: по текущей цене (прежнюю цену восстановить нельзя)
create or replace function items_before() returns trigger language plpgsql security definer set search_path=public as $$
declare o orders%rowtype;
begin
  if tg_op='INSERT' then
    select * into o from orders where id=new.order_id;
    new.label := case when o.kind='take' then 'Вынос-'||coalesce(o.tk_no::text,'?') else 'Стол '||o.tbl end;
    new.tbl := o.tbl;
    new.batch := coalesce(new.batch, gen_random_uuid());
    new.waiter := coalesce(new.waiter, auth.uid());
    new.price := (select price from dishes where id=new.dish_id);   -- всегда из меню, подделать с клиента нельзя
  elsif new.status is distinct from old.status and auth.uid() is not null then
    if new.status='accepted' then new.accepted_at:=now(); new.accepted_by:=auth.uid();
    elsif new.status='ready' then
      new.ready_at:=now(); new.ready_by:=auth.uid();
      if new.accepted_at is null then new.accepted_at:=now(); new.accepted_by:=auth.uid(); end if;
    elsif new.status='served' then new.served_at:=now();
    end if;
  end if;
  return new;
end $$;

-- 3. БЕЗОПАСНОСТЬ: журнал склада и движение остатков — только руководителю.
--    Раньше любой вошедший сотрудник (в т.ч. официант) мог читать и менять stock_log и вызывать stock_move.
drop policy if exists stock_log_all on stock_log;
drop policy if exists stock_log_boss on stock_log;
create policy stock_log_boss on stock_log for all using (my_role()='boss') with check (my_role()='boss');
create or replace function stock_move(p_id bigint, p_kind text, p_qty numeric, p_sum numeric, p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare d numeric;
begin
  if my_role() is distinct from 'boss' then raise exception 'Нет доступа'; end if;
  if p_kind not in ('in','waste') or coalesce(p_qty,0)<=0 then raise exception 'Неверные данные'; end if;
  perform 1 from products where id=p_id for update;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set
    s_kitchen=case when station='kitchen' then s_kitchen+d else s_kitchen end,
    s_bar=case when station='bar' then s_bar+d else s_bar end
  where id=p_id;
  insert into stock_log(kind,product_id,qty,sum,note) values(p_kind,p_id,p_qty,coalesce(p_sum,0),p_note);
end $$;

-- 4. Колонка «В меню» (галочка в Меню) — в базе её не было, переключение выдавало ошибку.
alter table dishes add column if not exists active boolean not null default true;

-- 5. Ускорение отчётов
create index if not exists orders_closed_idx on orders(closed) where status='closed';
create index if not exists order_items_created_idx on order_items(created);

-- ===== ПРОВЕРКА (необязательно). Сколько продуктов было списано лишний раз из-за двойного списания =====
-- Подставьте дату, с которой работало списание по отправке (миграция migration.sql), и выполните отдельно:
-- select p.name, p.unit, round(sum(r.qty*i.qty)::numeric,3) as списано_лишний_раз
-- from orders o join order_items i on i.order_id=o.id join recipes r on r.dish_id=i.dish_id join products p on p.id=r.product_id
-- where o.status='closed' and o.closed >= '2026-01-01' group by 1,2 order by 3 desc;
-- Остатки после этого лучше пересчитать по факту: Продукты -> продукт -> поле «Остаток».
