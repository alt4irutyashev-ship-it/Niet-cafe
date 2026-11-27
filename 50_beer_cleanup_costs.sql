-- Niet Café 50: ПИВО В МЕНЮ, ЦЕНЫ ПО НАКЛАДНЫМ 19–24.11, УБОРКА СКЛАДА, ДОПОЛНИТЕЛЬНЫЕ РАСХОДЫ.
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять после 36_invoice_prices.sql и 49_fixes.sql. Можно запускать повторно.
--
--   1) Уборка склада (выполняется после пунктов 2–3): продукты, которых нет ни в одной техкарте (и в составе сетов), уходят в АРХИВ.
--      Не трогаются продукты, у которых есть остаток или которые закупались за последние 30 дней —
--      их список будет в таблице внизу, уберите вручную, если не нужны (Склад → продукт → «🗄 В архив»).
--      Вернуть из архива: Склад → «🗄 Архив» → «↩ Восстановить».
--   2) Цены по накладным (только эти позиции; остальные цены не меняются):
--        • ИП Муллаева, №18151 от 19.11.2026 — пиво «Pražačka», кега 30 л — 20 700 → 690 ₸/л;
--        • ТОО «BBS TRADE», №120463 от 20.11.2026 — сиропы Barbados 1 л: манго-маракуйя 2 100, Berry Twist 2 100, лайм 1 900, ананас 2 000;
--        • IN YOUR ICE, 24.11.2026 — лёд 10 кг × 300 = 3 000 (доставка 1 000 — в дополнительные расходы).
--      Чего нет на складе — создаётся (бар, остаток 0). Приход оформите как обычно, если ещё не оформили.
--   3) Пиво в меню: категория «Пиво», «Пиво Pražačka разливное 0,5 л» — перепродажа, в техкарте 0,5 л пива.
--      ⛔ Блюдо в СТОПЕ с ценой 0: Меню → «⛔ В стопе» → впишите цену → снимите стоп → Сохранить.
--   4) Дополнительные расходы: таблица extra_costs (сумма, комментарий, дата). Руководитель вносит их
--      в «Команда и затраты» → «Доп. расходы»; они вычитаются из итоговой прибыли в отчётах за свой день.
--      Первая запись — доставка льда 1 000 ₸ (24.11.2026).
-- Внизу — таблица результата.

do $chk$ begin
  if to_regclass('public.invoice_ref') is null then raise exception 'Сначала выполните 36_invoice_prices.sql'; end if;
  if to_regclass('public.orders_one_open_per_tbl') is null then raise exception 'Сначала выполните 49_fixes.sql'; end if;
end $chk$;

create temp table if not exists r50(ord int, act text, name text, info text);
truncate r50;

-- ===================== 2. ЦЕНЫ ПО НАКЛАДНЫМ =====================
create temp table if not exists inv2711(
  key text primary key, title text, unit text, price numeric, inc text[], exc text[], prio int,
  doc date, src text, note text, kg_l boolean, manual boolean, new_name text, new_station text);
truncate inv2711;

insert into inv2711 values
('beer_prazacka','Пиво «Pražačka» разливное, кега 30 л','л',690,array['пив'],array['кревет|закус|сет|кольц|чипс|орех|соус|тесто|кляр'],26,date '2026-11-19',
 'Накладная №18151 от 19.11.2026, ИП Муллаева И. А.: 1 кега 30 л — 20 700','690 ₸ за 1 л',false,false,'Пиво Pražačka (разливное)','bar'),
('syrup_mango','Сироп BARBADOS Mango-Passionfruit 1 л','л',2100,array['сироп.*(манго|маракуй|mango|passion)'],'{}',26,date '2026-11-20',
 'Накладная №120463 от 20.11.2026, ТОО «BBS TRADE»: 2 × 2 100','',false,false,'Сироп Barbados Манго-маракуйя','bar'),
('syrup_berry','Сироп BARBADOS Berry Twist 1 л','л',2100,array['сироп.*(berry|ягод)'],'{}',26,date '2026-11-20',
 'Накладная №120463 от 20.11.2026, ТОО «BBS TRADE»: 1 × 2 100','',false,false,'Сироп Barbados Berry Twist (ягодный)','bar'),
('syrup_lime','Сироп BARBADOS Lime 1 л','л',1900,array['сироп.*(лайм|lime)'],'{}',26,date '2026-11-20',
 'Накладная №120463 от 20.11.2026, ТОО «BBS TRADE»: 1 × 1 900','',false,false,'Сироп Barbados Лайм','bar'),
('syrup_pineapple','Сироп BARBADOS Pineapple 1 л','л',2000,array['сироп.*(ананас|pineapple)'],'{}',26,date '2026-11-20',
 'Накладная №120463 от 20.11.2026, ТОО «BBS TRADE»: 1 × 2 000','',false,false,'Сироп Barbados Ананас','bar'),
('ice','Лёд пищевой (IN YOUR ICE)','кг',300,array['(^|[^а-я])лед($|[^а-я])'],array['чай|кофе|морожен|кубик.*сах'],26,date '2026-11-24',
 'Накладная IN YOUR ICE от 24.11.2026: 10 кг × 300 = 3 000','Доставка 1 000 ₸ — в дополнительных расходах',false,false,'Лёд пищевой','bar');

insert into invoice_ref(key,title,unit,price,inc,exc,prio,doc_date,src,note,kg_l,manual)
select key,title,unit,price,inc,exc,prio,doc,src,note,kg_l,manual from inv2711
on conflict (key) do update set title=excluded.title, unit=excluded.unit, price=excluded.price, doc_date=excluded.doc_date,
  src=excluded.src, note=excluded.note, kg_l=excluded.kg_l, manual=excluded.manual, inc=excluded.inc, exc=excluded.exc;

do $apply$
begin
  perform set_config('niet.nopush','1',true);
  delete from invoice_last_run;
  insert into invoice_last_run(id,name,unit,old_price,new_price,st,key,title,ref_unit,doc_date,src,note)
  with p as (
    select p.id, p.name, p.unit, coalesce(p.price,0) old_price,
           translate(lower(p.name),'ё','е') n,
           case lower(trim(coalesce(p.unit,''))) when 'кг.' then 'кг' when 'kg' then 'кг' when 'л.' then 'л' when 'l' then 'л'
             when 'шт.' then 'шт' when 'бут' then 'шт' when 'уп' then 'шт' when 'пач' then 'шт' when 'пучок' then 'шт'
             when 'гр' then 'г' when 'гр.' then 'г' else lower(trim(coalesce(p.unit,''))) end u
      from products p where not coalesce(p.archived,false)),
  m as (
    select distinct on (p.id) p.*, r.key, r.title, r.unit ref_unit, r.doc_date, r.src, r.note, r.manual,
           invoice_unit_price(r.unit, r.price, p.u, r.kg_l) new_price
      from p join invoice_ref r
        on r.key in (select key from inv2711)
       and not exists (select 1 from unnest(r.inc) x where p.n !~ x)
       and not exists (select 1 from unnest(r.exc) x where p.n ~ x)
     order by p.id, (invoice_unit_price(r.unit, r.price, p.u, r.kg_l) is not null) desc, r.prio desc, r.doc_date desc nulls last, r.key)
  select m.id, m.name, m.unit, m.old_price, round(m.new_price,2), case
      when m.new_price is null then 'unit'
      when m.manual then 'manual'
      when m.old_price > 0 and (m.new_price / m.old_price > 2.5 or m.new_price / m.old_price < 0.4) then 'big'
      when round(m.old_price,2) = round(m.new_price,2) then 'same'
      else 'ok' end,
      m.key, m.title, m.ref_unit, m.doc_date, m.src, m.note
    from m;

  update products pr set price = i.new_price from invoice_last_run i where i.id = pr.id and i.st = 'ok';

  -- новые продукты (или возврат из архива, если такой уже был)
  update products p set archived = false, archived_at = null, price = v.price
    from inv2711 v
   where lower(p.name) = lower(v.new_name) and p.archived
     and not exists (select 1 from invoice_last_run r where r.key = v.key);
  with n as (
    insert into products(name, unit, price, station)
    select v.new_name, v.unit, v.price, v.new_station
      from inv2711 v
     where v.new_name is not null and not v.manual
       and not exists (select 1 from invoice_last_run r where r.key = v.key)
       and not exists (select 1 from products p where lower(p.name) = lower(v.new_name))
    returning id, name, unit, price)
  insert into invoice_last_run(id,name,unit,old_price,new_price,st,key,title,ref_unit,doc_date,src,note)
  select n.id, n.name, n.unit, null, n.price, 'new', v.key, v.title, v.unit, v.doc, v.src, v.note
    from n join inv2711 v on lower(v.new_name) = lower(n.name);
  insert into invoice_last_run(id,name,unit,old_price,new_price,st,key,title,ref_unit,doc_date,src,note)
  select p.id, p.name, p.unit, null, p.price, 'same', v.key, v.title, v.unit, v.doc, v.src, v.note
    from inv2711 v join products p on lower(p.name) = lower(v.new_name)
   where not exists (select 1 from invoice_last_run r where r.key = v.key);

  insert into price_source(product_id, price, doc_date, src, ref_key, set_at)
  select id, new_price, doc_date, src, key, now() from invoice_last_run where st in ('ok','same','new')
  on conflict (product_id) do update set price = excluded.price, doc_date = excluded.doc_date, src = excluded.src, ref_key = excluded.ref_key, set_at = now();

  insert into r50
  select 2, case st when 'ok' then '✅ цена обновлена' when 'same' then '✅ цена уже такая' when 'new' then '🆕 новый продукт'
               when 'manual' then '⚠ проверьте вручную' when 'big' then '⚠ не изменено: разница больше чем в 2,5 раза'
               else '⚠ не изменено: в накладной '||ref_unit||', у вас '||unit end,
         name, coalesce(trim_scale(old_price)::text||' → ','')||trim_scale(new_price)||' ₸/'||unit||' · '||src
    from invoice_last_run;
end $apply$;

-- ===================== 3. ПИВО В МЕНЮ =====================
do $beer$
declare c int; d int; pid int;
begin
  perform set_config('niet.nopush','1',true);
  select id into c from cats where lower(name) = 'пиво' order by id limit 1;
  if c is null then
    select coalesce(max(id),0) + 1 into c from cats;
    insert into cats(id, name) values (c, 'Пиво');
    insert into r50 values (1, '🆕 новая категория', 'Пиво', '');
  end if;
  select id into pid from products where name = 'Пиво Pražačka (разливное)' order by archived, id limit 1;
  if pid is null then
    select r.id into pid from invoice_last_run r where r.key = 'beer_prazacka' limit 1;
  end if;
  select id into d from dishes where lower(name) = lower('Пиво Pražačka разливное 0,5 л') order by archived, id limit 1;
  if d is null then
    select coalesce(max(id),0) + 1 into d from dishes;
    insert into dishes(id, cat_id, name, price, station, stop, resale, descr, descr_kz)
    values (d, c, 'Пиво Pražačka разливное 0,5 л', 0, 'bar', true, true,
            'Светлое разливное пиво Pražačka, 0,5 л', 'Pražačka ашық құйма сырасы, 0,5 л');
    insert into r50 values (1, '🆕 в меню (⛔ в стопе, цена 0 — впишите цену)', 'Пиво Pražačka разливное 0,5 л', 'перепродажа, бар');
  else
    update dishes set archived = false, resale = true, station = 'bar' where id = d;
    insert into r50 values (1, '✅ уже в меню', 'Пиво Pražačka разливное 0,5 л', '');
  end if;
  if pid is not null then
    insert into recipes(dish_id, product_id, qty) values (d, pid, 0.5)
    on conflict (dish_id, product_id) do update set qty = excluded.qty;
  end if;
end $beer$;

-- ===================== 4. УБОРКА СКЛАДА (после накладных и пива) =====================
do $clean$
declare p record; used boolean; recent boolean;
begin
  perform set_config('niet.nopush','1',true);
  for p in select * from products where not coalesce(archived,false) order by name loop
    used := exists(select 1 from recipes r join dishes d on d.id = r.dish_id and not coalesce(d.archived,false) where r.product_id = p.id)
         or (to_regclass('public.set_items') is not null and exists(select 1 from set_items s join dishes d on d.id = s.set_id and not coalesce(d.archived,false) where s.product_id = p.id));
    continue when used or exists(select 1 from invoice_last_run i where i.id = p.id);   -- позиции этих накладных не трогаем
    recent := exists(select 1 from receipts where product_id = p.id and t > now() - interval '30 days')
           or exists(select 1 from price_source where product_id = p.id and doc_date > current_date - 30);
    if greatest(coalesce(p.s_kitchen,0),0) + greatest(coalesce(p.s_bar,0),0) > 0 then
      insert into r50 values (3, '⚠ не в техкартах, но есть остаток — оставлен', p.name,
        'остаток '||trim_scale(round(greatest(coalesce(p.s_kitchen,0),0) + greatest(coalesce(p.s_bar,0),0),3))||' '||coalesce(p.unit,''));
    elsif recent then
      insert into r50 values (3, '⚠ не в техкартах, но закупался за 30 дней — оставлен', p.name, '');
    else
      update products set archived = true, archived_at = now() where id = p.id;
      insert into movements(kind,info,product_id) values('Удалён в архив', p.name||' (не используется в техкартах)', p.id);
      insert into r50 values (4, '🗄 в архив: нет в техкартах', p.name, '');
    end if;
  end loop;
end $clean$;

-- ===================== 5. ДОПОЛНИТЕЛЬНЫЕ РАСХОДЫ =====================
create table if not exists extra_costs(
  id bigint generated always as identity primary key,
  bdate date not null default current_date,     -- день, к которому относится расход (день смены)
  amount numeric not null check (amount > 0),
  note text not null check (length(trim(note)) > 0),
  uid uuid default auth.uid(),
  created timestamptz not null default now()
);
create index if not exists extra_costs_d on extra_costs(bdate);
alter table extra_costs enable row level security;
drop policy if exists extra_costs_boss on extra_costs;
create policy extra_costs_boss on extra_costs for all using (my_role() = 'boss') with check (my_role() = 'boss');
revoke all on extra_costs from anon;

insert into extra_costs(bdate, amount, note)
select date '2026-11-24', 1000, 'Доставка льда (IN YOUR ICE, накладная от 24.11.2026)'
 where not exists (select 1 from extra_costs where note like 'Доставка льда (IN YOUR ICE%');

-- сброс статистики (файл 32) очищает и доп. расходы
notify pgrst, 'reload schema';

-- ===================== ИТОГ =====================
select act as "Что сделано", name as "Позиция", info as "Подробности" from (
  select ord, act, name, info from r50
  union all
  select 5, '💸 доп. расходы', 'записей: '||count(*), 'на '||trim_scale(coalesce(sum(amount),0))||' ₸' from extra_costs) x
order by ord, act, name;
