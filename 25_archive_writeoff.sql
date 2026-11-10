-- Niet Café: архив блюд, списание и добавление продуктов, состав блюд для гостей.
-- Выполнить ПОСЛЕ 24_table_bill.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.

-- 1. АРХИВ БЛЮД --------------------------------------------------------------------------------
-- «Удалить из меню» = блюдо уходит в архив. Отчёты и история заказов не ломаются,
-- руководитель может вернуть блюдо в меню. Гость, официант и повар архивных блюд не видят.
alter table dishes add column if not exists archived boolean not null default false;
alter table dishes add column if not exists archived_at timestamptz;
-- гость (anon) видит только блюда не из архива
drop policy if exists dishes_pub on dishes;
create policy dishes_pub on dishes for select to anon using (not archived);

-- 2. СПИСАНИЕ НА СЕРВЕРЕ -----------------------------------------------------------------------
-- Раньше телефон читал остаток и записывал новый: при одновременной работе двух людей остаток мог сбиться.
-- Теперь списание — одна операция на сервере, с суммой и причиной в журнале.
alter table movements add column if not exists product_id int;
alter table movements add column if not exists qty numeric;
alter table movements add column if not exists amount numeric;
alter table movements add column if not exists reason text;
alter table movements add column if not exists loc text;

create or replace function stock_writeoff(p_id int, p_qty numeric, p_loc text, p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p products%rowtype; nb numeric; loc text; amt numeric;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Неверное количество'; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'Укажите причину'; end if;
  select * into p from products where id=p_id for update;
  if not found then raise exception 'Продукт не найден'; end if;
  loc := case when p_loc in ('bar','s_bar') then 'bar' else 'kitchen' end;
  nb := case loc when 'bar' then coalesce(p.s_bar,0) else coalesce(p.s_kitchen,0) end - p_qty;
  update products set s_bar=case when loc='bar' then nb else s_bar end, s_kitchen=case when loc='kitchen' then nb else s_kitchen end where id=p_id;
  amt := round(p_qty*coalesce(p.price,0));
  insert into movements(kind,info,product_id,qty,amount,reason,loc)
  values('Списание', p.name||': '||p_qty||' '||p.unit||' ('||case loc when 'bar' then 'бар' else 'кухня' end||') — '||trim(p_reason)||', '||amt||' ₸',
         p_id, p_qty, amt, trim(p_reason), loc);
  return jsonb_build_object('balance',nb,'amount',amt,'loc',loc);
end$$;
revoke execute on function stock_writeoff(int,numeric,text,text) from public, anon;
grant execute on function stock_writeoff(int,numeric,text,text) to authenticated;

-- 3. ДОБАВЛЕНИЕ ПРОДУКТА (с минимумом, потерей и местом хранения) ---------------------------------
alter table products add column if not exists min numeric not null default 0;
create or replace function product_add(p_name text, p_unit text, p_price numeric, p_min numeric default 0, p_loss numeric default 0, p_station text default 'kitchen')
returns int language plpgsql security definer set search_path=public as $$
declare v_id int;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Введите название'; end if;
  if exists(select 1 from products where lower(trim(name)) = lower(trim(p_name))) then raise exception 'Такой продукт уже есть'; end if;
  if coalesce(p_loss,0) < 0 or coalesce(p_loss,0) >= 100 then raise exception 'Потеря: от 0 до 99 %%'; end if;
  insert into products(name,unit,price,min,loss_pct,station)
  values(trim(p_name), coalesce(nullif(trim(p_unit),''),'кг'), coalesce(p_price,0), coalesce(p_min,0), coalesce(p_loss,0),
         case when p_station='bar' then 'bar' else 'kitchen' end)
  returning id into v_id;
  insert into movements(kind,info,product_id) values('Новый продукт', trim(p_name)||', '||coalesce(nullif(trim(p_unit),''),'кг')||', '||coalesce(p_price,0)||' ₸', v_id);
  return v_id;
end$$;
revoke execute on function product_add(text,text,numeric,numeric,numeric,text) from public, anon;
grant execute on function product_add(text,text,numeric,numeric,numeric,text) to authenticated;

-- 4. СОСТАВ БЛЮДА ДЛЯ ГОСТЯ (без граммовки) ------------------------------------------------------
-- Основные ингредиенты из техкарты: самые «весомые» по стоимости — первыми.
-- Не показываются: соль, сахар, вода, масло для жарки, специи, упаковка. Цены и граммы не передаются.
create or replace function guest_ingredients()
returns table(dish_id int, items text[]) language sql stable security definer set search_path=public as $$
  select r.dish_id,
         (array_agg(p.name order by r.qty*coalesce(p.price,0) desc, p.name))[1:8]
    from recipes r
    join products p on p.id = r.product_id
    join dishes d on d.id = r.dish_id and not d.archived
   where p.name !~* '(^|\s)(соль|сахар|вода|лёд|лед)(\s|$|,)|перец (черн|молот|душист)|масло (растит|подсолн|для фрит|фритюр)|фритюр|специ|приправ|упаков|контейнер|пакет|крышк|салфет|палочк|стакан|трубочк|ложк|вилк|соусник|ланч-бокс|бокс'
   group by r.dish_id
$$;
revoke execute on function guest_ingredients() from public;
grant execute on function guest_ingredients() to anon, authenticated;

notify pgrst, 'reload schema';
