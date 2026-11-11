-- Niet Café 34: склад (заканчивается, удаление продукта, дубли), «Доставлено / Получено», оценки и отзывы,
-- база клиентов доставки, история заказов: официант — без истории, кухня/бар — только 12 часов.
-- Выполнить ПОСЛЕ 33_push_all.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.

-- =====================================================================================================
-- 1. СКЛАД
-- =====================================================================================================

-- 1.1 Удаление продукта = в архив (история приходов/списаний остаётся, восстановить можно в «Остатки → Архив»)
alter table products add column if not exists archived boolean not null default false;
alter table products add column if not exists archived_at timestamptz;

create or replace function product_archive(p_id int, p_on boolean default true) returns boolean
language plpgsql security definer set search_path=public as $$
declare p products%rowtype; used text;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  select * into p from products where id = p_id;
  if not found then raise exception 'Продукт не найден'; end if;
  if p_on then
    select string_agg(d.name, ', ' order by d.name) into used
      from recipes r join dishes d on d.id = r.dish_id and not coalesce(d.archived,false)
     where r.product_id = p_id;
    if used is not null then
      raise exception 'Продукт есть в техкартах: %. Сначала уберите его из техкарт или объедините с другим продуктом', used;
    end if;
  end if;
  update products set archived = p_on, archived_at = case when p_on then now() end where id = p_id;
  insert into movements(kind,info,product_id) values(case when p_on then 'Удалён в архив' else 'Восстановлен' end, p.name, p_id);
  return true;
end $$;
revoke execute on function product_archive(int,boolean) from public, anon;
grant execute on function product_archive(int,boolean) to authenticated;

-- новый продукт: понятная ошибка, если такой есть в архиве
create or replace function product_add(p_name text, p_unit text, p_price numeric, p_min numeric default 0, p_loss numeric default 0, p_station text default 'kitchen')
returns int language plpgsql security definer set search_path=public as $$
declare v_id int; v_arc boolean;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  if coalesce(trim(p_name),'') = '' then raise exception 'Введите название'; end if;
  select archived into v_arc from products where lower(trim(name)) = lower(trim(p_name)) limit 1;
  if found then raise exception '%', case when v_arc then 'Такой продукт есть в архиве — восстановите его: Остатки → Архив' else 'Такой продукт уже есть' end; end if;
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

-- 1.2 Объединить дубли («Помидор» + «Помидоры»): остатки складываются, техкарты, приходы, журнал и история цен
--     переходят на основной продукт, дубль удаляется. Единицы должны совпадать.
create or replace function product_merge(p_from int, p_into int) returns text
language plpgsql security definer set search_path=public as $$
declare a products%rowtype; b products%rowtype;
begin
  if my_role() <> 'boss' then raise exception 'Объединять может только руководитель'; end if;
  if p_from = p_into then raise exception 'Выберите два разных продукта'; end if;
  select * into a from products where id = p_from for update;
  select * into b from products where id = p_into for update;
  if a.id is null or b.id is null then raise exception 'Продукт не найден'; end if;
  if lower(trim(a.unit)) is distinct from lower(trim(b.unit)) then
    raise exception 'Разные единицы: «%» в %, «%» в %. Сначала приведите к одной единице', a.name, a.unit, b.name, b.unit;
  end if;
  perform set_config('niet.nopush','1',true);
  -- техкарты: если в блюде есть оба — количества складываются
  update recipes r set qty = coalesce(r.qty,0) + coalesce(x.qty,0)
    from recipes x where x.product_id = p_from and r.product_id = p_into and r.dish_id = x.dish_id;
  delete from recipes x where x.product_id = p_from and exists(select 1 from recipes r where r.product_id = p_into and r.dish_id = x.dish_id);
  update recipes set product_id = p_into where product_id = p_from;
  update receipts set product_id = p_into where product_id = p_from;
  update movements set product_id = p_into where product_id = p_from;
  update price_history set item_id = p_into where kind = 'product' and item_id = p_from;
  if to_regclass('public.stock_log') is not null then update stock_log set product_id = p_into where product_id = p_from; end if;
  update products set s_kitchen = coalesce(s_kitchen,0) + coalesce(a.s_kitchen,0),
                      s_bar     = coalesce(s_bar,0) + coalesce(a.s_bar,0),
                      min       = greatest(coalesce(min,0), coalesce(a.min,0)),
                      loss_pct  = case when coalesce(loss_pct,0) = 0 then coalesce(a.loss_pct,0) else loss_pct end,
                      archived  = false
   where id = p_into;
  delete from products where id = p_from;
  insert into movements(kind,info,product_id) values('Объединение', '«'||a.name||'» объединён с «'||b.name||'»', p_into);
  return b.name;
end $$;
revoke execute on function product_merge(int,int) from public, anon;
grant execute on function product_merge(int,int) to authenticated;

-- 1.3 Средний расход продукта в день: продажи по техкартам (с учётом потерь) + списания, за последние p_days дней
create or replace function stock_usage(p_days int default 14) returns table(product_id int, per_day numeric, days int)
language plpgsql stable security definer set search_path=public as $$
declare d0 timestamptz := now() - make_interval(days => greatest(coalesce(p_days,14),1)); nd int;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  -- если кафе работает меньше p_days — делим на фактическое число дней
  select greatest(1, least(greatest(coalesce(p_days,14),1), ceil(extract(epoch from now() - min(created)) / 86400)::int)) into nd
    from order_items where created >= d0;
  nd := coalesce(nd, greatest(coalesce(p_days,14),1));
  return query
  with sold as (
    select r.product_id, sum(r.qty * i.qty / (1 - least(coalesce(p.loss_pct,0),99)/100)) q
      from order_items i
      join recipes r on r.dish_id = i.dish_id
      join products p on p.id = r.product_id
     where i.created >= d0 and i.status in ('ready','served')
     group by r.product_id
  ), lost as (
    select m.product_id, sum(m.qty) q from movements m
     where m.t >= d0 and m.kind = 'Списание' and m.product_id is not null and m.qty > 0
     group by m.product_id
  )
  select coalesce(s.product_id, l.product_id), round((coalesce(s.q,0) + coalesce(l.q,0)) / nd, 4), nd
    from sold s full join lost l on l.product_id = s.product_id;
end $$;
revoke execute on function stock_usage(int) from public, anon;
grant execute on function stock_usage(int) to authenticated;

-- 1.4 Минимумы автоматически: запас на p_days дней по среднему расходу (только где минимум ещё 0, если p_all = false)
create or replace function stock_auto_min(p_days numeric default 2, p_all boolean default false) returns int
language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if my_role() not in ('boss','store') then raise exception 'Нет доступа'; end if;
  perform set_config('niet.nopush','1',true);
  update products p set min = case when lower(trim(p.unit)) in ('шт','шт.','бут','уп','пач') then ceil(u.per_day * p_days) else round(u.per_day * p_days, 2) end
    from stock_usage(14) u
   where u.product_id = p.id and u.per_day > 0 and not p.archived and (p_all or coalesce(p.min,0) = 0);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function stock_auto_min(numeric,boolean) from public, anon;
grant execute on function stock_auto_min(numeric,boolean) to authenticated;

-- автостоп и уведомление «заканчивается» — не для архивных продуктов
create or replace function push_low_stock() returns trigger language plpgsql security definer set search_path=public as $$
declare o numeric; n numeric;
begin
  if coalesce(new.min,0) <= 0 or coalesce(new.archived,false) then return null; end if;
  o := coalesce(old.s_kitchen,0) + coalesce(old.s_bar,0);
  n := coalesce(new.s_kitchen,0) + coalesce(new.s_bar,0);
  if o >= new.min and n < new.min then
    perform push_send((select jsonb_agg(jsonb_build_object('kind','low','to_role',r,'tag','low_'||new.id,
      'title','⚠ Заканчивается: '||new.name,
      'body','Осталось '||trim_scale(round(n,2))||' '||new.unit||' (минимум '||trim_scale(new.min)||' '||new.unit||'). Пора заказать.'))
      from unnest(array['store','boss']) r));
  end if;
  return null;
exception when others then return null;
end $$;

-- =====================================================================================================
-- 2. «ДОСТАВЛЕНО» (официант) и «ПОЛУЧИЛ» (гость)
-- =====================================================================================================
alter table orders add column if not exists done_at timestamptz;            -- доставлен / выдан гостю
alter table guest_orders add column if not exists received_at timestamptz;  -- гость сам нажал «Получил»

create or replace function guest_order_status(i int) returns text
language plpgsql stable security definer set search_path=public as $$
declare g guest_orders%rowtype; cids text[]; v_oid int; v_st text; v_kind text; v_out timestamptz; v_done timestamptz;
        n int; n_ready int; n_served int; n_work int;
begin
  select * into g from guest_orders where id=i;
  if not found then return null; end if;
  if g.status is distinct from 'accepted' then return g.status; end if;   -- new / rejected
  cids := array(select 'g'||i||'_'||k from generate_series(1, greatest(jsonb_array_length(g.items),1)) k);
  select count(*),
         count(*) filter (where it.status in ('ready','served')),
         count(*) filter (where it.status = 'served'),
         count(*) filter (where it.status <> 'new'),
         max(it.order_id)
    into n, n_ready, n_served, n_work, v_oid
    from order_items it where it.cid = any(cids);
  if g.received_at is not null then return case when g.kind = 'table' then 'served' else 'done' end; end if;
  if n = 0 then return 'accepted'; end if;
  select status, kind, out_at, done_at into v_st, v_kind, v_out, v_done from orders where id = v_oid;
  if v_kind = 'delivery' then
    if v_st = 'closed' or v_done is not null then return 'done'; end if;
    if v_out is not null then return 'way'; end if;
  elsif v_kind = 'take' then
    if v_st = 'closed' or v_done is not null then return 'done'; end if;
  else
    if v_st = 'closed' or n_served = n then return 'served'; end if;
  end if;
  if n_ready = n then return 'ready'; end if;
  if n_work > 0 then return 'cooking'; end if;
  return 'accepted';
end $$;
revoke execute on function guest_order_status(int) from public;
grant execute on function guest_order_status(int) to anon, authenticated;

-- гость нажал «✅ Получил заказ» (нужен секретный ключ заказа, который есть только на телефоне гостя)
create or replace function guest_received(p_id int, p_token text) returns text
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; v_oid int;
begin
  select * into g from guest_orders where id = p_id;
  if not found or g.token is null or g.token is distinct from p_token then raise exception 'Заказ не найден'; end if;
  if g.status <> 'accepted' then return guest_order_status(p_id); end if;
  update guest_orders set received_at = coalesce(received_at, now()) where id = p_id;
  select max(order_id) into v_oid from order_items where cid like 'g'||p_id||'\_%';
  if v_oid is not null then
    update orders set done_at = coalesce(done_at, now()) where id = v_oid;
    perform push_send(jsonb_build_array(jsonb_build_object('kind','got','to_role','waiter','tag','got_'||p_id,
      'title','✅ Гость получил заказ №'||p_id,
      'body', coalesce(nullif(g.cname,''),'Гость')||case when g.kind='delivery' then ' подтвердил доставку' else ' забрал заказ' end)));
  end if;
  update guest_orders set push_st = guest_order_status(p_id) where id = p_id;
  return guest_order_status(p_id);
end $$;
revoke execute on function guest_received(int,text) from public;
grant execute on function guest_received(int,text) to anon, authenticated;

-- push гостю и при «Доставлено» от официанта
create or replace function gp_on_order() returns trigger language plpgsql security definer set search_path=public as $$
declare gid int;
begin
  if (new.out_at, new.status, new.done_at) is not distinct from (old.out_at, old.status, old.done_at) then return null; end if;
  for gid in select distinct substring(cid from '^g(\d+)_')::int from order_items where order_id = new.id and cid ~ '^g\d+_' loop
    perform guest_push_check(gid);
  end loop;
  return null;
exception when others then return null;
end $$;

-- =====================================================================================================
-- 3. ОЦЕНКИ И ОТЗЫВЫ: 5 ★ — гость уходит в 2ГИС, 1–4 ★ — внутренний отзыв руководителю
-- =====================================================================================================
create table if not exists reviews(
  id bigint generated always as identity primary key,
  gorder_id int unique,
  stars int not null check (stars between 1 and 5),
  text text,
  kind text,            -- table / delivery / take
  tbl int,
  phone text,
  cname text,
  created timestamptz not null default now(),
  done boolean not null default false,   -- руководитель разобрал отзыв
  reply text
);
alter table reviews enable row level security;
drop policy if exists reviews_boss on reviews;
create policy reviews_boss on reviews for all using (my_role() = 'boss') with check (my_role() = 'boss');

create or replace function guest_review(p_id int, p_token text, p_stars int, p_text text default null) returns boolean
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; r reviews%rowtype; tx text := nullif(left(trim(coalesce(p_text,'')),1000),'');
begin
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'Оценка от 1 до 5'; end if;
  select * into g from guest_orders where id = p_id;
  if not found or g.token is null or g.token is distinct from p_token then raise exception 'Заказ не найден'; end if;
  if g.status <> 'accepted' or g.created < now() - interval '2 days' then raise exception 'Оценить можно только полученный заказ'; end if;
  select * into r from reviews where gorder_id = p_id;
  if found and r.created < now() - interval '1 hour' then return false; end if;   -- менять оценку можно в течение часа
  insert into reviews(gorder_id,stars,text,kind,tbl,phone,cname)
  values(p_id,p_stars,tx,g.kind,g.tbl,g.phone,g.cname)
  on conflict (gorder_id) do update set stars = excluded.stars, text = coalesce(excluded.text, reviews.text);
  if p_stars <= 3 and (r.id is null or r.stars > 3 or (tx is not null and r.text is distinct from tx)) then
    perform push_send(jsonb_build_array(jsonb_build_object('kind','review','to_role','boss','tag','rev_'||p_id,
      'title', repeat('★',p_stars)||repeat('☆',5-p_stars)||' Отзыв: '||case g.kind when 'delivery' then 'доставка' when 'take' then 'самовывоз' else 'стол '||g.tbl end,
      'body', coalesce(tx,'Без комментария')||case when g.phone is not null then E'\n📞 '||g.phone else '' end)));
  end if;
  return true;
end $$;
revoke execute on function guest_review(int,text,int,text) from public;
grant execute on function guest_review(int,text,int,text) to anon, authenticated;

-- =====================================================================================================
-- 4. БАЗА КЛИЕНТОВ (имена и телефоны из доставки и самовывоза) — только руководителю
-- =====================================================================================================
create or replace function phone_key(p text) returns text language sql immutable as $$
  select case when length(d) >= 10 then '+7' || right(d,10) end from (select regexp_replace(coalesce(p,''),'\D','','g') d) x
$$;

drop function if exists clients_list();
create or replace function clients_list() returns table(
  phone text, name text, address text, orders int, total numeric, avg_check numeric,
  first_at timestamptz, last_at timestamptz, delivery int, take int, fav text, stars numeric, reviews int, open_now int)
language sql stable security definer set search_path=public as $$
  with o as (
    select phone_key(x.phone) pk, x.* from orders x
     where my_role() = 'boss' and x.kind in ('delivery','take') and phone_key(x.phone) is not null
  ), g as (
    select o.pk,
           count(*) filter (where o.status = 'closed')::int n,
           coalesce(sum(o.total) filter (where o.status = 'closed'),0) s,
           min(o.created) f, max(o.created) l,
           count(*) filter (where o.kind='delivery' and o.status='closed')::int nd,
           count(*) filter (where o.kind='take' and o.status='closed')::int nt,
           count(*) filter (where o.status='open')::int op,
           (array_agg(nullif(trim(o.cname),'') order by o.created desc) filter (where nullif(trim(o.cname),'') is not null))[1] nm,
           (array_agg(nullif(trim(o.address),'') order by o.created desc) filter (where nullif(trim(o.address),'') is not null))[1] ad
      from o group by o.pk
  ), fv as (
    select t.pk, string_agg(t.nm || ' ×' || t.q, ', ' order by t.q desc, t.nm) f from (
      select o.pk, d.name nm, sum(i.qty)::int q, row_number() over (partition by o.pk order by sum(i.qty) desc, d.name) rn
        from o join order_items i on i.order_id = o.id join dishes d on d.id = i.dish_id
       where o.status = 'closed' group by o.pk, d.name) t
     where t.rn <= 3 group by t.pk
  ), rv as (
    select phone_key(r.phone) pk, round(avg(r.stars),1) st, count(*)::int c from reviews r where phone_key(r.phone) is not null group by 1
  )
  select g.pk, g.nm, g.ad, g.n, g.s, case when g.n > 0 then round(g.s / g.n) end, g.f, g.l, g.nd, g.nt, fv.f, rv.st, coalesce(rv.c,0), g.op
    from g left join fv on fv.pk = g.pk left join rv on rv.pk = g.pk
   order by g.n desc, g.s desc, g.l desc
$$;
revoke execute on function clients_list() from public, anon;
grant execute on function clients_list() to authenticated;

-- заказы одного клиента (для карточки)
drop function if exists client_orders(text);
create or replace function client_orders(p_phone text) returns table(id int, created timestamptz, kind text, status text, total numeric, items text, address text)
language sql stable security definer set search_path=public as $$
  select o.id, o.created, o.kind, o.status, o.total,
         (select string_agg(i.qty||'× '||d.name, ', ' order by i.id) from order_items i join dishes d on d.id=i.dish_id where i.order_id=o.id),
         o.address
    from orders o
   where my_role() = 'boss' and o.kind in ('delivery','take') and phone_key(o.phone) = phone_key(p_phone)
   order by o.created desc limit 100
$$;
revoke execute on function client_orders(text) from public, anon;
grant execute on function client_orders(text) to authenticated;

-- =====================================================================================================
-- 5. ИСТОРИЯ ЗАКАЗОВ: официант видит только открытые заказы (+15 мин после оплаты, чтобы распечатать чек),
--    кухня и бар — только последние 12 часов (и всё, что ещё в работе). Руководитель — всё.
-- =====================================================================================================
drop policy if exists w_o_sel on orders;
create policy w_o_sel on orders for select using (my_role()='waiter' and (status='open' or closed > now() - interval '15 minutes'));
drop policy if exists w_o_upd on orders;
create policy w_o_upd on orders for update using (my_role()='waiter' and status='open') with check (my_role()='waiter');

drop policy if exists w_i_sel on order_items;
create policy w_i_sel on order_items for select using (my_role()='waiter' and exists(
  select 1 from orders o where o.id = order_items.order_id and (o.status='open' or o.closed > now() - interval '15 minutes')));

drop policy if exists s_r on order_items;
create policy s_r on order_items for select using (station = my_role() and (created > now() - interval '12 hours' or status in ('new','accepted','cooking')));
drop policy if exists s_u on order_items;
create policy s_u on order_items for update using (station = my_role() and (created > now() - interval '12 hours' or status in ('new','accepted','cooking'))) with check (station = my_role());

-- заявки гостей и вызовы: официанту — только за последние 12 часов (там телефоны и адреса)
drop policy if exists go_staff on guest_orders;
drop policy if exists go_boss on guest_orders;
drop policy if exists go_waiter on guest_orders;
create policy go_boss on guest_orders for all using (my_role()='boss') with check (my_role()='boss');
create policy go_waiter on guest_orders for all using (my_role()='waiter' and created > now() - interval '12 hours') with check (my_role()='waiter');

drop policy if exists calls_staff on calls;
drop policy if exists calls_boss on calls;
drop policy if exists calls_waiter on calls;
create policy calls_boss on calls for all using (my_role()='boss') with check (my_role()='boss');
create policy calls_waiter on calls for all using (my_role()='waiter' and created > now() - interval '12 hours') with check (my_role()='waiter');

notify pgrst, 'reload schema';
