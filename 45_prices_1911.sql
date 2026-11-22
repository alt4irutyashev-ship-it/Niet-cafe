-- Niet Café 45: ЦЕНЫ ИЗ ЧЕКОВ 19.11.2026 (кухня — чек 196026, бар — чек 196029).
-- Supabase -> SQL Editor -> вставить всё -> Run. Нужен ранее выполненный 36_invoice_prices.sql. Можно запускать повторно.
--
--   • Обновляет цены ТОЛЬКО по позициям этих двух чеков (остальные цены, в том числе исправленные вручную, не трогает).
--   • Фасовки пересчитаны в цену за единицу: «фри 2,5 кг за 2100» → 840 ₸/кг, «соя 0,5 за 750» → 1500 ₸/л.
--   • Продуктов, которых ещё нет на складе (пивные креветки, луковые кольца, ягоды, специи, орехи, чай…),
--     создаются автоматически — с ценой из чека, на кухне или в баре (по чеку). Остаток 0: приход внесите как обычно.
--   • Не меняет цену, если единица не совпадает, цена отличается больше чем в 2,5 раза или позиция помечена «проверьте».
-- Внизу — таблица результата.

do $chk$ begin
  if to_regclass('public.invoice_ref') is null then
    raise exception 'Сначала выполните 36_invoice_prices.sql';
  end if;
end $chk$;

create temp table if not exists inv1911(
  key text primary key, title text, unit text, price numeric, inc text[], exc text[], prio int,
  src text, note text, kg_l boolean, manual boolean, new_name text, new_station text);
truncate inv1911;

insert into inv1911 values
-- ===== КУХНЯ, чек 196026 от 19.11.2026 =====
('sour_cream','Сметана 20% 1 л','л',1150,array['сметан'],'{}',22,'Чек 196026 от 19.11.2026 (кухня): 2 × 1150','',true,false,'Сметана 20%','kitchen'),
('mayo','Майонез «Провансаль» 67% 5 л','кг',1100,array['майонез|провансал'],'{}',22,'Чек 196026 от 19.11.2026 (кухня): 5 л — 5500','Считаем 1 л ≈ 1 кг. В сентябре — 1021 ₸/кг (ведро 9,6 кг)',false,false,null,null),
('chicken_fil','Филе куриное на подложке (Казахстан)','кг',2100,array['(кур|цыпл).*(филе|грудк)|(филе|грудк).*(кур|цыпл)|^филе кур|куриное филе'],array['копч|х/к|бедр|утк|инде'],22,'Чек 196026 от 19.11.2026 (кухня): 5,215 кг × 2100','',false,false,null,null),
('oil_fry','Масло фритюрное 10 л','л',660,array['фритюр'],'{}',24,'Чек 196026 от 19.11.2026 (кухня): 10 л — 6600','В сентябре — 690 ₸/л',true,false,null,null),
('cream24','Сливки «Крем Арт» 20% (упаковка)','шт',1550,array['сливк'],array['растит|кокос|сух|масл|сыр'],22,'Чек 196026 от 19.11.2026 (кухня): 3 × 1550','В чеке сливки 20% без объёма упаковки, раньше брали «Шеф» 24% (2950). Проверьте, какие сливки в техкартах, и впишите цену вручную',false,true,null,null),
('ramen','Рамен Jin ramen','шт',560,array['рамен|ramen'],'{}',26,'Чек 196026 от 19.11.2026 (кухня): 10 × 560','В сентябре — 460',false,false,null,null),
('egg','Яйцо куриное С-1','шт',65,array['(^|[^а-я])яйц|яйцо'],array['перепел|лия|жидк|меланж|лапш|сух'],22,'Чек 196026 от 19.11.2026 (кухня): 60 × 65','',false,false,'Яйцо куриное С-1','kitchen'),
('starch','Крахмал кукурузный 1 кг','кг',850,array['крахмал'],'{}',24,'Чек 196026 от 19.11.2026 (кухня): 2 × 850','',false,false,'Крахмал кукурузный','kitchen'),
('cheese_sauce','Соус сырный «Астория» 1 кг','кг',1750,array['сырн.*соус|соус.*сырн'],'{}',26,'Чек 196026 от 19.11.2026 (кухня): 2 × 1750','',true,false,'Соус сырный «Астория»','kitchen'),
('rice_laser','Рис «Лазер» (5 кг × 1250)','кг',1250,array['(^|[^а-я])рис'],array['суш|уксус|бумаг|лапш|мук'],23,'Чек 196026 от 19.11.2026 (кухня): 5 кг × 1250','В 3 раза дороже прежнего риса (386 ₸/кг, мешок 25 кг). Проверьте, какой это рис и для чего, и впишите цену вручную',false,true,null,null),
('wedges','Картофельные дольки «Триумф» 2,5 кг','кг',1120,array['дольк'],'{}',26,'Чек 196026 от 19.11.2026 (кухня): 2,5 кг — 2800','В сентябре — 1320 ₸/кг (Авико)',false,false,null,null),
('fries','Картофель фри Амико 10 мм, 2,5 кг','кг',840,array['фри'],array['соус|фритюр|дольк|steak|стейк'],24,'Чек 196026 от 19.11.2026 (кухня): 2 × 2100','',false,false,null,null),
('shrimp_beer','Креветки пивные 90+, 5 кг','кг',4950,array['пивн.*кревет|кревет.*пивн|кревет.*90'],'{}',26,'Чек 196026 от 19.11.2026 (кухня): 5 кг — 24 750','',false,false,'Креветки пивные','kitchen'),
('onion_rings','Луковые кольца Авико 1 кг','кг',2850,array['кольц'],array['кальмар|ананас'],26,'Чек 196026 от 19.11.2026 (кухня): 2 × 2850','',false,false,'Луковые кольца (заморозка)','kitchen'),
('fettuccine','Феттучини Barilla 500 г','кг',4200,array['феттуч|тальятел'],'{}',24,'Чек 196026 от 19.11.2026 (кухня): 2 × 2100 за 500 г','',false,false,null,null),
('cremchees','Сыр сливочный «Кремета» 2,2 кг','кг',2955,array['кремет|творожн|сливочн(ый)? сыр|сыр сливочн|крем.?чиз|филадельф|cream'],array['масл|соус'],22,'Чек 196026 от 19.11.2026 (кухня): 2,2 кг — 6500','',false,false,null,null),
('mozz','Моцарелла «Экстра» брус 2 кг','кг',2350,array['моцарел'],array['шарик|рассол|буррат|мини'],22,'Чек 196026 от 19.11.2026 (кухня): 2 × 4700','',false,false,null,null),
('egg_quail','Яйцо перепелиное (уп. 20 шт — 750)','шт',37.5,array['перепел'],'{}',26,'Чек 196026 от 19.11.2026 (кухня): 2 уп. × 750','Цена за 1 яйцо',false,false,'Яйцо перепелиное','kitchen'),
('soy','Соус соевый 0,5 л','л',1500,array['соев|(^|[^а-я])соя'],array['мук|молок|бобы|ростк'],24,'Чек 196026 от 19.11.2026 (кухня): 2 × 750 за 0,5 л','',true,false,'Соус соевый','kitchen'),
('bouillon','Бульон Maggi курица/говядина на косточке','шт',1350,array['магги|maggi|бульон'],array['пельмен|суп'],24,'Чек 196026 от 19.11.2026 (кухня): 3 × 1350','Цена за упаковку',false,false,'Бульон Maggi (упаковка)','kitchen'),
('egg_noodle','«Лия яичная» (так в чеке)','шт',430,array['яичн.*лапш|лапш.*яичн|(^|[^а-я])лия'],'{}',26,'Чек 196026 от 19.11.2026 (кухня): 3 × 430','Неясно, что это (лапша яичная?) — проверьте и при необходимости заведите продукт сами',false,true,null,null),
('oil','Масло подсолнечное 5 л','л',730,array['подсолн|растит|^масло$|масло 5'],array['слив|оливк|кунжут|фритюр'],22,'Чек 196026 от 19.11.2026 (кухня): 5 л — 3650','31.10 — 710 ₸/л',false,false,null,null),
-- ===== БАР, чек 196029 от 19.11.2026 =====
('clove','Гвоздика весовая','кг',7300,array['гвоздик'],'{}',24,'Чек 196029 от 19.11.2026 (бар): 50 г — 365','',false,false,'Гвоздика','bar'),
('cinnamon','Корица палочки','кг',3800,array['кориц'],array['молот|сахар|булоч|сироп'],24,'Чек 196029 от 19.11.2026 (бар): 200 г — 760','',false,false,'Корица (палочки)','bar'),
('raspberry','Малина с/м','кг',3200,array['малин'],array['сироп|варен|пюре|чай|джем'],22,'Чек 196029 от 19.11.2026 (бар): 1 кг — 3200','',false,false,'Малина с/м','bar'),
('strawberry','Клубника с/м','кг',1450,array['клубник'],array['сироп|варен|пюре|чай|джем'],22,'Чек 196029 от 19.11.2026 (бар): 1 кг — 1450','',false,false,'Клубника с/м','bar'),
('peanut','Арахис','кг',1500,array['арахис'],array['паст|масл'],22,'Чек 196029 от 19.11.2026 (бар): 0,5 кг — 750','',false,false,'Арахис','bar'),
('pistachio','Фисташки','кг',6800,array['фисташ'],array['паст|морожен|соус'],22,'Чек 196029 от 19.11.2026 (бар): 0,5 кг — 3400','',false,false,'Фисташки','bar'),
('tea_greenfield','Чай Greenfield Kenyan Sunrise, 100 пак. × 2 г','шт',1850,array['greenfield|гринфилд'],'{}',26,'Чек 196029 от 19.11.2026 (бар): 1 × 1850','Цена за пачку 100 пакетиков',false,false,'Чай Greenfield Kenyan Sunrise (100 пак.)','bar');

-- справочник: новые позиции добавляются, старые с тем же ключом обновляются (правила поиска сохраняются)
insert into invoice_ref(key,title,unit,price,inc,exc,prio,doc_date,src,note,kg_l,manual)
select key,title,unit,price,inc,exc,prio,date '2026-11-19',src,note,kg_l,manual from inv1911
on conflict (key) do update set title=excluded.title, unit=excluded.unit, price=excluded.price, doc_date=excluded.doc_date,
  src=excluded.src, note=excluded.note, kg_l=excluded.kg_l, manual=excluded.manual;

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
        on not exists (select 1 from unnest(r.inc) x where p.n !~ x)
       and not exists (select 1 from unnest(r.exc) x where p.n ~ x)
     order by p.id, (invoice_unit_price(r.unit, r.price, p.u, r.kg_l) is not null) desc, r.prio desc, r.doc_date desc nulls last, r.key)
  select m.id, m.name, m.unit, m.old_price, round(m.new_price,2), case
      when m.new_price is null then 'unit'
      when m.manual then 'manual'
      when m.old_price > 0 and (m.new_price / m.old_price > 2.5 or m.new_price / m.old_price < 0.4) then 'big'
      when round(m.old_price,2) = round(m.new_price,2) then 'same'
      else 'ok' end,
      m.key, m.title, m.ref_unit, m.doc_date, m.src, m.note
    from m
   where m.key in (select key from inv1911);      -- только позиции чеков 19.11

  update products pr set price = i.new_price from invoice_last_run i where i.id = pr.id and i.st = 'ok';

  -- новые продукты: позиций чека, которых нет на складе
  with n as (
    insert into products(name, unit, price, station)
    select v.new_name, v.unit, v.price, v.new_station
      from inv1911 v
     where v.new_name is not null and not v.manual
       and not exists (select 1 from invoice_last_run r where r.key = v.key)
       and not exists (select 1 from products p where lower(p.name) = lower(v.new_name))
    returning id, name, unit, price)
  insert into invoice_last_run(id,name,unit,old_price,new_price,st,key,title,ref_unit,doc_date,src,note)
  select n.id, n.name, n.unit, null, n.price, 'new', v.key, v.title, v.unit, date '2026-11-19', v.src, v.note
    from n join inv1911 v on lower(v.new_name) = lower(n.name);

  insert into price_source(product_id, price, doc_date, src, ref_key, set_at)
  select id, new_price, doc_date, src, key, now() from invoice_last_run where st in ('ok','same','new')
  on conflict (product_id) do update set price = excluded.price, doc_date = excluded.doc_date, src = excluded.src, ref_key = excluded.ref_key, set_at = now();
end $apply$;

-- ================= ОТЧЁТ =================
select name as "Продукт", unit as "Ед.", old_price as "Было, ₸", new_price as "По чеку, ₸",
       case when old_price > 0 and new_price is not null then round((new_price-old_price)/old_price*100) end as "Разница, %",
       case st when 'ok' then '✅ обновлено' when 'same' then '✅ цена уже такая' when 'new' then '🆕 новый продукт создан'
               when 'manual' then '⚠ проверьте вручную' when 'big' then '⚠ не изменено: разница больше чем в 2,5 раза'
               else '⚠ не изменено: в чеке '||ref_unit||', у вас '||unit end as "Результат",
       title as "Позиция в чеке", src as "Документ", note as "Примечание",
       case st when 'ok' then 1 when 'new' then 2 when 'same' then 3 else 4 end as ord
  from invoice_last_run
union all
select null, null, null, null, null, '⚠ позиция «проверьте» — продукт не найден, ничего не изменено', v.title, v.src, v.note, 5
  from inv1911 v where v.manual and not exists (select 1 from invoice_last_run r where r.key = v.key)
order by ord, 1;
