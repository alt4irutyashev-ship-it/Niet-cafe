-- Niet Café 21: заказ с собой и доставка с сайта, push официанту, списание со склада ровно один раз,
-- рыночные цены в «Остатках». Выполнить ПОСЛЕ 20_staff_privacy.sql. Можно запускать повторно.
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Затем выложить новые index.html, guest.html, order.html, sw.js.
--
-- Правила доставки (меняются во вкладке «Затраты» у руководителя):
--   доставка 990 ₸, если сумма блюд меньше 5000 ₸, иначе бесплатно; 10% за обслуживание не берётся.
-- Номера: «Самовывоз-N» — столы 101–199, «Доставка-N» — 201–299 (100 и 200 — ещё не принятые заявки).

-- ===== 1. Настройки доставки (видны гостям и сотрудникам; остальные затраты — только руководителю) =====
insert into settings(key,val) values('delivery_fee',990) on conflict (key) do nothing;
insert into settings(key,val) values('delivery_free',5000) on conflict (key) do nothing;
drop policy if exists set_pub on settings;
create policy set_pub on settings for select to anon using (key in ('service','delivery_fee','delivery_free'));
drop policy if exists set_r on settings;
create policy set_r on settings for select using (my_role()='boss' or (my_role()<>'none' and key in ('service','delivery_fee','delivery_free')));

-- ===== 2. Данные клиента в заявке и в заказе =====
alter table guest_orders add column if not exists kind text not null default 'table';   -- table / take / delivery
alter table guest_orders add column if not exists phone text;
alter table guest_orders add column if not exists address text;
alter table guest_orders add column if not exists cname text;
alter table guest_orders add column if not exists sum numeric;
alter table guest_orders add column if not exists fee numeric not null default 0;
alter table orders add column if not exists phone text;
alter table orders add column if not exists address text;
alter table orders add column if not exists cname text;
alter table orders add column if not exists delivery_fee numeric not null default 0;

-- ===== 3. Заявка с сайта (без входа): самовывоз или доставка =====
create or replace function remote_order(p_items jsonb, p_kind text, p_phone text, p_address text default null,
                                        p_name text default null, p_note text default null, p_token text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare clean jsonb; s numeric; f numeric := 0; oid int; ph text; kk text := nullif(left(coalesce(p_token,''),64),'');
        v_fee numeric := coalesce((select val from settings where key='delivery_fee'),990);
        v_free numeric := coalesce((select val from settings where key='delivery_free'),5000);
begin
  if p_kind not in ('take','delivery') then raise exception 'Неверный тип заказа'; end if;
  if kk is not null then
    select g.id, g.sum, g.fee into oid, s, f from guest_orders g where g.token=kk;
    if found then return jsonb_build_object('id',oid,'sum',s,'fee',f); end if;
  end if;
  ph := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  if length(ph)=11 and left(ph,1) in ('7','8') then ph := '7'||right(ph,10);
  elsif length(ph)=10 then ph := '7'||ph;
  else raise exception 'Укажите номер телефона полностью: +7 XXX XXX XX XX'; end if;
  if p_kind='delivery' and length(trim(coalesce(p_address,''))) < 5 then raise exception 'Укажите адрес доставки'; end if;
  select jsonb_agg(jsonb_build_object('dish_id',d.id,'qty',least(greatest((x->>'qty')::int,1),20))), sum(d.price*least(greatest((x->>'qty')::int,1),20))
    into clean, s
    from jsonb_array_elements(p_items) x join dishes d on d.id=(x->>'dish_id')::int and not coalesce(d.stop,false) and coalesce(d.active,true);
  if clean is null or jsonb_array_length(clean) > 40 then raise exception 'Корзина пуста'; end if;
  -- защита от спама: не больше 3 заявок с одного номера за 10 минут и 40 заявок всего за 10 минут
  if (select count(*) from guest_orders where phone=ph and created > now() - interval '10 minutes') >= 3 then raise exception 'Слишком много заявок с этого номера. Подождите несколько минут'; end if;
  if (select count(*) from guest_orders where kind in ('take','delivery') and created > now() - interval '10 minutes') >= 40 then raise exception 'Сейчас слишком много заказов. Позвоните нам'; end if;
  f := case when p_kind='delivery' and s < v_free then v_fee else 0 end;
  insert into guest_orders(tbl,items,note,token,kind,phone,address,cname,sum,fee)
  values(case when p_kind='delivery' then 200 else 100 end, clean, left(coalesce(p_note,''),300), kk, p_kind, ph,
         nullif(left(trim(coalesce(p_address,'')),300),''), nullif(left(trim(coalesce(p_name,'')),60),''), s, f)
  on conflict (token) do nothing returning id into oid;
  if oid is null then select g.id, g.sum, g.fee into oid, s, f from guest_orders g where g.token=kk; end if;
  return jsonb_build_object('id',oid,'sum',s,'fee',f);
end $$;
revoke execute on function remote_order(jsonb,text,text,text,text,text,text) from public;
grant execute on function remote_order(jsonb,text,text,text,text,text,text) to anon, authenticated;

-- ===== 4. Официант подтверждает заявку: создаётся заказ и уходит на кухню и бар (один раз) =====
create or replace function guest_accept(p_id int) returns boolean
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; o int; tn int; k text;
begin
  if my_role() not in ('waiter','boss') then raise exception 'Нет доступа'; end if;
  update guest_orders set status='accepted' where id=p_id and status='new' returning * into g;
  if not found then return false; end if;
  if g.tbl >= 200 or g.kind='delivery' then
    k := 'delivery';
    select n into tn from generate_series(201,299) as n where not exists(select 1 from orders where tbl=n and status='open') order by n limit 1;
  elsif g.tbl >= 100 then
    k := 'take';
    select n into tn from generate_series(101,199) as n where not exists(select 1 from orders where tbl=n and status='open') order by n limit 1;
  end if;
  if k is not null then
    if tn is null then raise exception 'Нет свободных номеров для заказов'; end if;
    insert into orders(tbl,kind,phone,address,cname,delivery_fee) values(tn,k,g.phone,g.address,g.cname,coalesce(g.fee,0)) returning id into o;
  else
    select id into o from orders where tbl=g.tbl and status='open' order by id limit 1;
    if o is null then insert into orders(tbl,kind) values(g.tbl,'dine') returning id into o; end if;
  end if;
  insert into order_items(order_id,tbl,dish_id,qty,station,note,cid)
  select o, (select tbl from orders where id=o), d.id, least(greatest((x.v->>'qty')::int,1),20), d.station, case when x.n=1 then nullif(g.note,'') end, 'g'||p_id||'_'||x.n
    from jsonb_array_elements(g.items) with ordinality as x(v,n) join dishes d on d.id=(x.v->>'dish_id')::int
  on conflict (cid) do nothing;
  return true;
end $$;
revoke execute on function guest_accept(int) from public, anon;
grant execute on function guest_accept(int) to authenticated;

-- ===== 5. Тип заказа «доставка»: без обслуживания, свой номер и подпись на кухне =====
create or replace function orders_tk() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.kind='take' and new.tbl is not null then new.tk_no := new.tbl-100;
  elsif new.kind='delivery' and new.tbl is not null then new.tk_no := new.tbl-200; end if;
  return new;
end $$;

-- Точечные правки в существующих функциях (остальная логика не меняется). Если правка уже сделана — пропуск.
do $$
declare r record; def text; old_def text; n int := 0;
begin
  for r in select * from (values
     ('orders_service', $a$case when new.kind='take' then 0$a$, $b$case when new.kind in ('take','delivery') then 0$b$),
     ('items_before',  $a$case when o.kind='take' then 'Вынос-'||coalesce(o.tk_no::text,'?') else$a$,
                       $b$case when o.kind='take' then 'Вынос-'||coalesce(o.tk_no::text,'?') when o.kind='delivery' then 'Доставка-'||coalesce(o.tk_no::text,'?') else$b$),
     -- списание: и при «готово», и при «выдано»/закрытии, если кухня не успела нажать «готово». Флаг stocked — ровно один раз.
     ('items_before',  $a$if new.status='ready' and not old.stocked$a$, $b$if new.status in ('ready','served') and not old.stocked$b$)
  ) as v(fn,a,b)
  loop
    select pg_get_functiondef(p.oid) into old_def from pg_proc p where p.proname=r.fn and p.pronamespace='public'::regnamespace;
    if old_def is null then raise notice 'Нет функции %', r.fn; continue; end if;
    if position(r.a in old_def) > 0 then
      def := replace(old_def, r.a, r.b); execute def; n := n + 1;
    elsif position(r.b in old_def) = 0 then
      raise notice 'ВНИМАНИЕ: в функции % не найден ожидаемый фрагмент — правка не применена', r.fn;
    end if;
  end loop;
  raise notice 'Правок применено: %', n;
end $$;

-- старый триггер из migration.sql списывал склад при каждой вставке — повторное списание. Убираем навсегда.
drop trigger if exists order_items_stock on order_items;

-- ===== 6. Push официантам: новая заявка с сайта, вызов со стола =====
create or replace function push_guest_order() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send(jsonb_build_array(jsonb_build_object('kind','new','to_role','waiter','tag','g_'||new.id,
    'title', case new.kind when 'delivery' then '🛵 Доставка' when 'take' then '🥡 Самовывоз' else '📱 Заказ со стола '||new.tbl end,
    'body', (select string_agg((x->>'qty')||'× '||coalesce(d.name,'блюдо'),', ') from jsonb_array_elements(new.items) x left join dishes d on d.id=(x->>'dish_id')::int)
            || case when new.sum is not null then E'\n💰 '||round(new.sum+coalesce(new.fee,0))||' ₸' else '' end)));
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_guest_order_t on guest_orders;
create trigger push_guest_order_t after insert on guest_orders for each row execute function push_guest_order();

create or replace function push_call() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send(jsonb_build_array(jsonb_build_object('kind','new','to_role','waiter','tag','call_'||new.tbl,
    'title', case new.kind when 'bill' then '🧾 Стол '||new.tbl||' просит счёт' else '🙋 Стол '||new.tbl||' зовёт официанта' end, 'body','')));
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_call_t on calls;
create trigger push_call_t after insert on calls for each row execute function push_call();
revoke execute on function push_guest_order() from public, anon;
revoke execute on function push_call() from public, anon;

-- ===== 7. Рыночная цена рядом с закупочной («Остатки» у руководителя) =====
create table if not exists price_ref(
  key text primary key, title text, unit text, price numeric, lo numeric, hi numeric,
  inc text[], exc text[], prio int, source text, url text, note text, checked date default current_date);
alter table price_ref add column if not exists manual boolean not null default false;
alter table price_ref enable row level security;

create or replace function market_prices()
returns table(product_id int, title text, unit text, price numeric, lo numeric, hi numeric, source text, url text, checked date)
language sql stable security definer set search_path=public as $$
  with p as (
    select p.id, translate(lower(p.name),'ё','е') as n,
      case lower(trim(coalesce(p.unit,''))) when 'kg' then 'кг' when 'кг.' then 'кг' when 'l' then 'л' when 'л.' then 'л' when 'шт.' then 'шт'
        else lower(trim(coalesce(p.unit,''))) end as u
    from products p where my_role()='boss')
  select distinct on (p.id) p.id, r.title, r.unit, r.price, r.lo, r.hi, r.source, r.url, r.checked
  from p join price_ref r on r.unit=p.u
   and not exists (select 1 from unnest(r.inc) x where p.n !~ x)
   and not exists (select 1 from unnest(r.exc) x where p.n ~ x)
  order by p.id, r.prio desc, r.key
$$;
revoke execute on function market_prices() from public, anon;
grant execute on function market_prices() to authenticated;

-- обновить кэш схемы API (иначе сайт может писать «Could not find a relationship …»)
notify pgrst, 'reload schema';
