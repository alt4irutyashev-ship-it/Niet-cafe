-- Niet Café 40: время работы, смена через полночь, закрытие смены (Z-отчёт), QR-отзыв на пречеке,
-- инвентаризация с недостачей в деньгах. Выполнить ПОСЛЕ 39_cleanup.sql. Можно запускать повторно.
-- Время — астанинское (UTC+5), берётся с сервера, а не с телефона.

-- =====================================================================================================
-- 1. ВРЕМЯ РАБОТЫ И «ДЕНЬ СМЕНЫ»
--    Смена 11:00–03:00: заказ 06.07 в 01:30 относится к смене 05.07.
--    Граница дня — середина времени, когда кафе закрыто (для 11:00–03:00 это 07:00).
-- =====================================================================================================
insert into settings(key,val) values ('open_min',660),('close_min',180) on conflict (key) do nothing;   -- минуты от полуночи: 660 = 11:00, 180 = 03:00

create or replace function biz_cfg() returns table(open_min int, close_min int, bound_min int)
language sql stable security definer set search_path=public as $$
  with s as (select coalesce((select val from settings where key='open_min'),660)::int o, coalesce((select val from settings where key='close_min'),180)::int c)
  select o, c, ((c + ((o - c + 1440) % 1440) / 2) % 1440)::int from s
$$;
-- астанинское «настенное» время
create or replace function ast(t timestamptz default now()) returns timestamp language sql stable as $$ select (t at time zone 'UTC') + interval '5 hours' $$;
-- дата смены, к которой относится момент t
create or replace function biz_date(t timestamptz default now()) returns date language sql stable security definer set search_path=public as $$
  select (ast(t) - make_interval(mins => (select bound_min from biz_cfg())))::date
$$;
-- начало смены (момент) для даты смены
create or replace function biz_start(d date) returns timestamptz language sql stable security definer set search_path=public as $$
  select ((d::timestamp + make_interval(mins => (select bound_min from biz_cfg()))) - interval '5 hours') at time zone 'UTC'
$$;
create or replace function biz_open(t timestamptz default now()) returns boolean language sql stable security definer set search_path=public as $$
  select case when c.open_min = c.close_min then true
              when c.open_min < c.close_min then m >= c.open_min and m < c.close_min
              else m >= c.open_min or m < c.close_min end
    from biz_cfg() c, (select (extract(hour from ast(t)) * 60 + extract(minute from ast(t)))::int m) x
$$;
-- для гостевой страницы и для приложения: часы работы + серверное время
create or replace function guest_hours() returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('open_min', c.open_min, 'close_min', c.close_min, 'bound_min', c.bound_min,
                            'now', now(), 'is_open', biz_open(), 'biz_date', biz_date())
    from biz_cfg() c
$$;
grant execute on function guest_hours() to anon, authenticated;
grant execute on function biz_date(timestamptz), biz_start(date), biz_open(timestamptz), ast(timestamptz), biz_cfg() to authenticated;

-- доставка и самовывоз только в рабочее время (проверка на сервере)
create or replace function guest_orders_hours() returns trigger language plpgsql security definer set search_path=public as $$
declare c record;
begin
  if coalesce(new.kind,'table') in ('delivery','take') and not biz_open() then
    select * into c from biz_cfg();
    raise exception 'Сейчас мы закрыты. Принимаем заказы с % до %',
      lpad((c.open_min/60)::text,2,'0')||':'||lpad((c.open_min%60)::text,2,'0'),
      lpad((c.close_min/60)::text,2,'0')||':'||lpad((c.close_min%60)::text,2,'0');
  end if;
  return new;
end $$;
drop trigger if exists guest_orders_hours_t on guest_orders;
create trigger guest_orders_hours_t before insert on guest_orders for each row execute function guest_orders_hours();

-- =====================================================================================================
-- 2. ЗАКРЫТИЕ СМЕНЫ (Z-ОТЧЁТ)
-- =====================================================================================================
create table if not exists shifts(
  id bigint generated always as identity primary key,
  bdate date not null unique,
  closed_at timestamptz not null default now(),
  closed_by uuid,
  data jsonb,                       -- итоги смены на момент закрытия
  cash_fact numeric, card_fact numeric, kaspi_fact numeric,
  diff numeric,                     -- факт − ожидание (минус = недостача)
  note text
);
alter table shifts enable row level security;
drop policy if exists shifts_read on shifts;
create policy shifts_read on shifts for select using (my_role() = 'boss' or (my_role() = 'waiter' and closed_at > now() - interval '2 days'));

create or replace function shift_summary(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare d date := coalesce(p_date, biz_date()); a timestamptz; b timestamptz; r jsonb;
begin
  if my_role() not in ('boss','waiter') then raise exception 'Нет доступа'; end if;
  a := biz_start(d); b := biz_start(d + 1);
  with o as (select * from orders where status = 'closed' and closed >= a and closed < b),
  w as (select coalesce(p.name,'—') nm, count(*) n, sum(o.total) s from o left join profiles p on p.id = o.waiter group by 1 order by 3 desc),
  dsh as (select d.name nm, sum(i.qty) q, sum(i.qty*i.price) s from o join order_items i on i.order_id = o.id join dishes d on d.id = i.dish_id group by 1 order by 2 desc limit 5),
  op as (select o2.id, o2.tbl, o2.kind, (select coalesce(sum(i.qty*i.price),0) from order_items i where i.order_id = o2.id) s
           from orders o2 where o2.status = 'open' and exists(select 1 from order_items i where i.order_id = o2.id))
  select jsonb_build_object(
    'bdate', d, 'from', a, 'to', b, 'now', now(),
    'checks', (select count(*) from o),
    'total', (select coalesce(sum(total),0) from o),
    'cash', (select coalesce(sum(p_cash),0) from o),
    'card', (select coalesce(sum(p_card),0) from o),
    'kaspi', (select coalesce(sum(p_kaspi),0) from o),
    'service', (select coalesce(sum(service),0) from o),
    'delivery_fee', (select coalesce(sum(delivery_fee),0) from o),
    'dine', (select jsonb_build_object('n',count(*),'s',coalesce(sum(total),0)) from o where coalesce(kind,'dine') not in ('take','delivery')),
    'take', (select jsonb_build_object('n',count(*),'s',coalesce(sum(total),0)) from o where kind = 'take'),
    'delivery', (select jsonb_build_object('n',count(*),'s',coalesce(sum(total),0)) from o where kind = 'delivery'),
    'items', (select coalesce(sum(i.qty),0) from o join order_items i on i.order_id = o.id),
    'first', (select min(created) from o), 'last', (select max(closed) from o),
    'cancels', (select jsonb_build_object('n',count(*),'s',coalesce(sum(qty*price),0)) from order_log where t >= a and t < b),
    'writeoffs', (select coalesce(sum(amount),0) from movements where kind = 'Списание' and t >= a and t < b),
    'open', (select jsonb_build_object('n',count(*),'s',coalesce(sum(s),0),'tables',coalesce(jsonb_agg(tbl order by tbl),'[]')) from op),
    'waiters', (select coalesce(jsonb_agg(jsonb_build_object('name',nm,'n',n,'s',s)),'[]') from w),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('name',nm,'q',q,'s',s)),'[]') from dsh),
    'closed', (select jsonb_build_object('at',s.closed_at,'by',coalesce(p.name,'—'),'cash',s.cash_fact,'card',s.card_fact,'kaspi',s.kaspi_fact,'diff',s.diff,'note',s.note)
                 from shifts s left join profiles p on p.id = s.closed_by where s.bdate = d)
  ) into r;
  return r;
end $$;
revoke execute on function shift_summary(date) from public, anon;
grant execute on function shift_summary(date) to authenticated;

create or replace function shift_close(p_date date, p_cash numeric, p_card numeric, p_kaspi numeric, p_note text default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s jsonb; df numeric;
begin
  if my_role() not in ('boss','waiter') then raise exception 'Нет доступа'; end if;
  if exists(select 1 from shifts where bdate = p_date) and my_role() <> 'boss' then raise exception 'Смена уже закрыта. Исправить может руководитель'; end if;
  s := shift_summary(p_date);
  df := coalesce(p_cash,0) - (s->>'cash')::numeric + coalesce(p_card,0) - (s->>'card')::numeric + coalesce(p_kaspi,0) - (s->>'kaspi')::numeric;
  insert into shifts(bdate,closed_at,closed_by,data,cash_fact,card_fact,kaspi_fact,diff,note)
  values(p_date, now(), auth.uid(), s - 'closed', p_cash, p_card, p_kaspi, df, nullif(trim(coalesce(p_note,'')),''))
  on conflict (bdate) do update set closed_at = now(), closed_by = auth.uid(), data = excluded.data, cash_fact = excluded.cash_fact,
     card_fact = excluded.card_fact, kaspi_fact = excluded.kaspi_fact, diff = excluded.diff, note = excluded.note;
  perform push_send(jsonb_build_array(jsonb_build_object('kind','shift','to_role','boss','tag','shift_'||p_date,
    'title','🔒 Смена '||to_char(p_date,'DD.MM')||' закрыта · '||trim(to_char((s->>'total')::numeric,'FM999 999 999'))||' ₸',
    'body', 'Чеков: '||(s->>'checks')||case when abs(df) >= 1 then E'\n'||case when df < 0 then '⚠ Недостача ' else 'Излишек ' end||trim(to_char(abs(df),'FM999 999 999'))||' ₸' else E'\nКасса сошлась ✅' end)));
  return shift_summary(p_date);
end $$;
revoke execute on function shift_close(date,numeric,numeric,numeric,text) from public, anon;
grant execute on function shift_close(date,numeric,numeric,numeric,text) to authenticated;

-- =====================================================================================================
-- 3. QR ДЛЯ ОТЗЫВА НА ПРЕЧЕКЕ
-- =====================================================================================================
alter table orders add column if not exists review_token text;
alter table reviews add column if not exists order_id int unique;

create or replace function order_review_token(p_order int) returns text
language plpgsql security definer set search_path=public as $$
declare t text;
begin
  if my_role() not in ('boss','waiter') then raise exception 'Нет доступа'; end if;
  select review_token into t from orders where id = p_order;
  if not found then raise exception 'Заказ не найден'; end if;
  if t is null then
    t := substr(md5(random()::text || clock_timestamp()::text || p_order), 1, 10);
    update orders set review_token = t where id = p_order;
  end if;
  return t;
end $$;
revoke execute on function order_review_token(int) from public, anon;
grant execute on function order_review_token(int) to authenticated;

create or replace function guest_review_order(p_order int, p_token text, p_stars int, p_text text default null) returns boolean
language plpgsql security definer set search_path=public as $$
declare o orders%rowtype; r reviews%rowtype; tx text := nullif(left(trim(coalesce(p_text,'')),1000),''); k text;
begin
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'Оценка от 1 до 5'; end if;
  select * into o from orders where id = p_order;
  if not found or o.review_token is null or o.review_token is distinct from p_token then raise exception 'Ссылка недействительна'; end if;
  if o.created < now() - interval '7 days' then raise exception 'Срок для отзыва истёк'; end if;
  k := case when o.kind in ('take','delivery') then o.kind else 'table' end;
  select * into r from reviews where order_id = p_order;
  if found and r.created < now() - interval '1 hour' then return false; end if;
  insert into reviews(order_id,stars,text,kind,tbl,phone,cname)
  values(p_order,p_stars,tx,k,o.tbl,o.phone,o.cname)
  on conflict (order_id) do update set stars = excluded.stars, text = coalesce(excluded.text, reviews.text);
  if p_stars <= 3 and (r.id is null or r.stars > 3 or (tx is not null and r.text is distinct from tx)) then
    perform push_send(jsonb_build_array(jsonb_build_object('kind','review','to_role','boss','tag','rev_o'||p_order,
      'title', repeat('★',p_stars)||repeat('☆',5-p_stars)||' Отзыв по пречеку: '||case k when 'delivery' then 'доставка' when 'take' then 'самовывоз' else 'стол '||o.tbl end,
      'body', coalesce(tx,'Без комментария'))));
  end if;
  return true;
end $$;
revoke execute on function guest_review_order(int,text,int,text) from public;
grant execute on function guest_review_order(int,text,int,text) to anon, authenticated;

-- =====================================================================================================
-- 4. ИНВЕНТАРИЗАЦИЯ: документ с недостачей и излишками в деньгах
-- =====================================================================================================
create table if not exists inventories(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  uid uuid default auth.uid(),
  loc text,
  items jsonb,             -- [{id,name,unit,book,fact,diff,price,sum}] — все посчитанные позиции
  n int, counted int,
  short numeric, extra numeric
);
alter table inventories enable row level security;
drop policy if exists inventories_read on inventories;
create policy inventories_read on inventories for select using (my_role() in ('boss','store'));

create or replace function stock_inventory(p_loc text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare x jsonb; p products%rowtype; loc text; cur numeric; f numeric; d numeric; sh numeric := 0; ex numeric := 0; n int := 0; cnt int := 0;
        ln text[] := '{}'; arr jsonb := '[]'; iid bigint;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  loc := case when p_loc in ('bar','s_bar') then 'bar' else 'kitchen' end;
  perform set_config('niet.nopush','1',true);
  for x in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    f := (x->>'fact')::numeric;
    if f is null or f < 0 then continue; end if;
    select * into p from products where id = (x->>'id')::int for update;
    if not found then continue; end if;
    cnt := cnt + 1;
    cur := case loc when 'bar' then coalesce(p.s_bar,0) else coalesce(p.s_kitchen,0) end;
    d := f - cur;
    arr := arr || jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'unit',p.unit,'book',round(cur,3),'fact',f,'diff',round(d,3),
                                                       'price',coalesce(p.price,0),'sum',round(d*coalesce(p.price,0),2)));
    if abs(d) < 1e-9 then continue; end if;
    update products set s_bar = case when loc='bar' then f else s_bar end, s_kitchen = case when loc='kitchen' then f else s_kitchen end where id = p.id;
    if d < 0 then sh := sh + (-d)*coalesce(p.price,0); else ex := ex + d*coalesce(p.price,0); end if;
    ln := ln || (p.name||': '||case when d>0 then '+' else '' end||round(d,3)||' '||p.unit);
    insert into movements(kind,info,product_id,qty,amount,reason,loc)
    values(case when d<0 then 'Недостача' else 'Излишек' end, p.name||': '||round(d,3)||' '||p.unit||' ('||case loc when 'bar' then 'бар' else 'кухня' end||')',
           p.id, d, round(abs(d)*coalesce(p.price,0)), 'инвентаризация', loc);
    n := n + 1;
  end loop;
  if cnt = 0 then return jsonb_build_object('n',0,'short',0,'extra',0); end if;
  insert into inventories(loc,items,n,counted,short,extra) values(loc, arr, n, cnt, round(sh), round(ex)) returning id into iid;
  if n > 0 then
    insert into movements(kind,info,amount,reason,loc)
    values('Инвентаризация', case loc when 'bar' then 'бар' else 'кухня' end||': '||array_to_string(ln,'; ')||'. Недостача '||round(sh)||' ₸, излишки '||round(ex)||' ₸',
           round(sh), 'инвентаризация', loc);
  end if;
  return jsonb_build_object('id',iid,'n',n,'counted',cnt,'short',round(sh),'extra',round(ex));
end$$;
revoke execute on function stock_inventory(text,jsonb) from public, anon;
grant execute on function stock_inventory(text,jsonb) to authenticated;

notify pgrst, 'reload schema';
