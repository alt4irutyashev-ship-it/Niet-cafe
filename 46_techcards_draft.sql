-- Niet Café 46: ЧЕРНОВЫЕ ТЕХКАРТЫ новых блюд + сливки «Крем Арт» + лапша домашняя яичная.
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять ПОСЛЕ 44_menu_update.sql и 45_prices_1911.sql.
-- Можно запускать повторно: уже заполненные техкарты НЕ перезаписываются.
--
--   1) Сливки: в техкартах и на складе — те, что купили 19.11: «Крем Арт» 20%, 1550 ₸ за упаковку (считаем упаковку 1 л).
--      Лапша «Лия яичная» = лапша домашняя яичная, 430 ₸ за упаковку.
--   2) Техкарты на 1 порцию (нетто, в единицах ВАШЕГО продукта) для 20 новых блюд и для блюд из пивных сетов,
--      если у блюда техкарты ещё нет. Продукты ищутся на вашем складе по названию; если продукта нет —
--      он создаётся с ценой из ваших чеков, а если в чеках его не было — с ПРИМЕРНОЙ рыночной ценой (⚠ в отчёте).
--   3) Выход порции (г) для новых блюд. В сеты добавлены луковые кольца и жареные пельмени.
--   4) Блюда остаются в СТОПЕ с ценой 0. В отчёте — себестоимость и цена для фудкоста 30 %.
--      Проверьте граммовки с поваром: Меню → блюдо → правьте количества → «Цена для фудкоста 30 % — поставить» → снять стоп.

create temp table if not exists tc_log(ord int, kind text, what text, info text);
truncate tc_log;

-- ================= 1. СЛИВКИ И ЛАПША =================
do $fix$
declare n int;
begin
  -- сливки: цену и название — по чеку 19.11
  update invoice_ref set title = 'Сливки «Крем Арт» 20% (упаковка 1 л)', manual = false,
         note = 'Цена за упаковку; для продукта в литрах считаем упаковку = 1 л'
   where key = 'cream24';
  select count(*) into n from products
   where not coalesce(archived, false) and translate(lower(name),'ё','е') ~ 'сливк'
     and translate(lower(name),'ё','е') !~ 'растит|кокос|сух|масл|сыр';
  if n = 0 then
    insert into products(name, unit, price, station) values ('Сливки «Крем Арт» 20%', 'л', 1550, 'kitchen');
    insert into tc_log values (1, 'Сливки', 'Сливки «Крем Арт» 20%', '🆕 создан: 1550 ₸ за 1 л (упаковка)');
  else
    with u as (
      update products set price = 1550,
             name = case when n = 1 then 'Сливки «Крем Арт» 20%' else name end
       where not coalesce(archived, false) and translate(lower(name),'ё','е') ~ 'сливк'
         and translate(lower(name),'ё','е') !~ 'растит|кокос|сух|масл|сыр'
      returning name, unit)
    insert into tc_log select 1, 'Сливки', name, '✅ цена 1550 ₸ за ' || case when lower(unit) in ('л','шт','уп','шт.') then
             case when lower(unit) = 'л' then '1 л (упаковка)' else 'упаковку' end else unit end from u;
  end if;

  -- лапша домашняя яичная
  update invoice_ref set title = 'Лапша домашняя яичная (упаковка)', manual = false, note = 'В чеке — «Лия яичная»'
   where key = 'egg_noodle';
  with u as (
    update products set price = 430
     where not coalesce(archived, false) and translate(lower(name),'ё','е') ~ 'яичн.*лапш|лапш.*яичн|лапша домашн|(^|[^а-я])лия'
    returning name)
  insert into tc_log select 1, 'Лапша', name, '✅ цена 430 ₸ за упаковку' from u;
  if not exists (select 1 from products where translate(lower(name),'ё','е') ~ 'яичн.*лапш|лапш.*яичн|лапша домашн|(^|[^а-я])лия') then
    insert into products(name, unit, price, station) values ('Лапша домашняя яичная (упаковка)', 'шт', 430, 'kitchen');
    insert into tc_log values (1, 'Лапша', 'Лапша домашняя яичная (упаковка)', '🆕 создан: 430 ₸ за упаковку');
  end if;
end $fix$;

-- ================= 2. ПРОДУКТЫ ДЛЯ ТЕХКАРТ =================
-- key, как искать (regex по названию), что исключить, название нового продукта, ед., цена, примерная ли цена,
-- где хранится, вес 1 «шт» в кг (для яиц, нори, пучков), размер 1 упаковки (для продукта в «шт»).
create temp table if not exists ing(
  key text primary key, inc text, exc text, new_name text, unit text, price numeric, est boolean,
  station text default 'kitchen', w1 numeric, pack numeric, pid int, pname text, punit text, pprice numeric, ploss numeric, pg numeric);
truncate ing;
insert into ing(key,inc,exc,new_name,unit,price,est,w1,pack) values
('shrimp_beer','пивн.*кревет|кревет.*пивн|кревет.*90',null,'Креветки пивные','кг',4950,false,null,null),
('shrimp','кревет','пивн|90|чипс|соус|палоч','Креветки тигровые 21/25','кг',4550,false,null,null),
('lemon','лимон','сок|кислот|lemonade|лимонад|сироп|чай','Лимон','кг',1300,false,null,null),
('garlic','чеснок','сух|молот|гранул|соус|паст','Чеснок','кг',1300,false,null,null),
('butter','масл.*слив|слив.*масл','сыр','Масло сливочное 82,5%','кг',4800,false,null,null),
('oil','подсолн|растит|^масло$|масло 5','слив|оливк|кунжут|фритюр','Масло подсолнечное','л',730,false,null,null),
('oil_fry','фритюр',null,'Масло фритюрное','л',660,false,null,null),
('flour','(^|[^а-я])мук','темпур|рис|кукуруз|миндал|панко','Мука в/с','кг',420,false,null,null),
('crucian','карас',null,'Карась (целый)','кг',1500,true,null,null),
('carp','сазан|(^|[^а-я])карп',null,'Сазан (целый)','кг',1800,true,null,null),
('bread','хлеб|батон|бородин|багет','сухар|панир|крошк|лаваш','Хлеб для гренок','кг',600,true,null,null),
('mayo','майонез|провансал',null,'Майонез 67%','кг',1100,false,null,null),
('tomato','помидор|томат','паст|соус|черри|чери|сок|сушен|вялен|кетчуп|консерв|пюре','Помидоры','кг',1300,false,null,null),
('onion_red','лук.*красн|красн.*лук|кр лук',null,'Лук красный','кг',600,false,null,null),
('onion','(^|[^а-я])лук','зелен|зел |порей|красн|шалот|фри|сушен|жарен|кольц','Лук репчатый','кг',200,false,null,null),
('pepper_hot','(полу)?горьк.*перец|перец.*(горьк|чили|остр)','молот|сух|хлоп','Перец полугорький','кг',1300,false,null,null),
('cilantro','кинз|киндз',null,'Кинза (пучок)','шт',200,false,0.05,null),
('avocado','авокад',null,'Авокадо','кг',3500,true,null,null),
('iceberg','айсберг|романо|латук|салат.*лист|лист.*салат|микс','соус|заправ|готов','Салат айсберг','кг',1800,false,null,null),
('cherry','черри|чери','желт','Помидоры черри','кг',2000,false,null,null),
('cucumber','огур','марин|солен|консерв|корнишон','Огурцы свежие','кг',750,false,null,null),
('olive_oil','оливк.*масл|масл.*оливк',null,'Масло оливковое','л',6000,true,null,null),
('parmesan','пармез','соус','Пармезан','кг',6600,false,null,null),
('lamb','баран','жир|курдюк|фарш','Баранина на кости','кг',5450,true,null,null),
('potato','картоф|картош','фри|дольк|пюре|батат|сладк|крахмал','Картофель','кг',210,false,null,null),
('carrot','морков','корейск|по-корейск','Морковь','кг',200,false,null,null),
('pepper','перец.*(болгар|сладк|светоф)|(болгар|сладк).*перец|светофор',null,'Перец болгарский','кг',2000,false,null,null),
('lentil','чечевиц',null,'Чечевица','кг',720,false,null,null),
('cream','сливк','растит|кокос|сух|масл|сыр','Сливки «Крем Арт» 20%','л',1550,false,null,1),
('bacon','бекон|грудинк',null,'Бекон','кг',4500,true,null,null),
('spaghetti','спагет',null,'Спагетти','кг',1400,true,null,null),
('egg','(^|[^а-я])яйц|яйцо|яйк','перепел|лия|жидк|меланж|лапш|сух','Яйцо куриное С-1','шт',65,false,0.05,null),
('rice','(^|[^а-я])рис','суш|уксус|бумаг|лапш|мук|японск|круглозерн|лазер','Рис','кг',386,false,null,null),
('beef','говяд|мясо гов|телят','кост|фарш|рибай|тибон|стейк|ребр|язык|печен|тушен|сервел|колбас|бекон|копч|бульон|кубик|жир','Говядина (мякоть)','кг',4800,false,null,null),
('chickpea','(^|[^а-я])нут',null,'Нут','кг',900,true,null,null),
('lagman','лагман','соус','Лапша для лагмана','кг',1500,false,null,null),
('cabbage','капуст','пекин|красн|цветн|брокк|квашен|морск|брюссел','Капуста белокочанная','кг',180,false,null,null),
('celery','сельдер',null,'Сельдерей','кг',1300,false,null,null),
('chicken','(кур|цыпл).*(филе|грудк)|(филе|грудк).*(кур|цыпл)|^филе кур|куриное филе','копч|х/к|бедр|утк|инде','Филе куриное','кг',2100,false,null,null),
('broccoli','брокк',null,'Брокколи с/м','кг',2500,true,null,null),
('sausage','колбаск|купат|колбас.*гриль|гриль.*колбас','сервел|варен|копч','Колбаски для гриля','кг',3500,true,null,null),
('ketchup','кетчуп',null,'Кетчуп','л',700,false,null,null),
('mustard','горчиц',null,'Горчица','кг',2714,false,null,null),
('milk','(^|[^а-я])молок','сгущ|кокос|сух|сыр|шоколад','Молоко 2,5%','л',430,true,null,null),
('zucchini','кабач|цукин','икр','Кабачки','кг',600,false,null,null),
('suluguni','сулугун',null,'Сулугуни','кг',2800,false,null,null),
('mozz','моцарел','шарик|рассол|буррат|мини','Моцарелла','кг',2350,false,null,null),
('sushi_rice','рис.*(суш|японик|лазер|круглозерн)|(суш|японик).*рис',null,'Рис для суши («Лазер»)','кг',1250,true,null,null),
('nori','нори',null,'Нори (лист)','шт',60,true,0.003,null),
('crab','краб|снежн',null,'Снежный краб (палочки)','кг',2500,true,null,null),
('cream_cheese','кремет|творожн.*сыр|сливочн(ый)? сыр|сыр сливочн|крем.?чиз|филадельф','масл|соус','Сыр сливочный «Кремета»','кг',2955,false,null,null),
('tempura','темпур',null,'Мука темпура','кг',1350,true,null,null),
('unagi','унаги|угр.*соус|соус.*угр',null,'Соус унаги','кг',1444,false,null,null),
('salmon','семг|лосос','копч|солен|слабосол|икр|соус','Сёмга','кг',5600,false,null,null),
('sriracha','шрирач|sriracha',null,'Соус шрирача','л',3043,false,null,null),
('tobiko','тобик|масаго|(^|[^а-я])икра','кабач|баклаж|лосос|красн','Икра тобико','кг',15400,false,null,null),
('onion_rings','кольц','кальмар|ананас','Луковые кольца (заморозка)','кг',2850,false,null,null),
('dumplings','пельмен','соус','Пельмени (полуфабрикат)','кг',2200,true,null,null),
('fries','(^|[^а-я])фри','соус|фритюр|дольк|steak|стейк','Картофель фри','кг',840,false,null,null),
('wedges','дольк',null,'Картофельные дольки','кг',1120,false,null,null),
('cheese_sticks','сырн.*палоч|палоч.*сыр',null,'Сырные палочки','кг',3700,false,null,null),
('nuggets','наггет|нагет',null,'Наггетсы','кг',1725,false,null,null),
('wings','крыл','утк|инде|соус','Крылья куриные','кг',1480,false,null,null),
('bbq','барбек|bbq',null,'Соус барбекю','кг',1500,true,null,null),
('chebureki','чебурек',null,'Чебуреки мини (полуфабрикат)','кг',2500,true,null,null);

-- ================= 3. ТЕХКАРТЫ (на 1 порцию, нетто; кг / л / шт) =================
create temp table if not exists tc(dish text, ord int, key text, qty numeric, out_g int);
truncate tc;
insert into tc values
-- пивные закуски
('Пивные креветки',1,'shrimp_beer',0.30,250),('Пивные креветки',2,'garlic',0.005,null),('Пивные креветки',3,'butter',0.01,null),('Пивные креветки',4,'lemon',0.02,null),
('Карась жареный',1,'crucian',0.40,300),('Карась жареный',2,'flour',0.03,null),('Карась жареный',3,'oil',0.03,null),('Карась жареный',4,'lemon',0.02,null),
('Сазан жареный',1,'carp',0.40,300),('Сазан жареный',2,'flour',0.03,null),('Сазан жареный',3,'oil',0.03,null),('Сазан жареный',4,'lemon',0.02,null),
('Гренки чесночные',1,'bread',0.15,200),('Гренки чесночные',2,'garlic',0.01,null),('Гренки чесночные',3,'oil_fry',0.03,null),('Гренки чесночные',4,'mayo',0.03,null),
-- салаты
('Ачучук',1,'tomato',0.15,200),('Ачучук',2,'onion_red',0.04,null),('Ачучук',3,'pepper_hot',0.005,null),('Ачучук',4,'cilantro',0.3,null),
('Салат с авокадо и креветками',1,'shrimp',0.08,220),('Салат с авокадо и креветками',2,'avocado',0.07,null),('Салат с авокадо и креветками',3,'iceberg',0.05,null),
('Салат с авокадо и креветками',4,'cherry',0.04,null),('Салат с авокадо и креветками',5,'cucumber',0.03,null),('Салат с авокадо и креветками',6,'lemon',0.01,null),
('Салат с авокадо и креветками',7,'olive_oil',0.015,null),('Салат с авокадо и креветками',8,'parmesan',0.01,null),
-- супы
('Шурпа из баранины',1,'lamb',0.18,450),('Шурпа из баранины',2,'potato',0.12,null),('Шурпа из баранины',3,'carrot',0.05,null),('Шурпа из баранины',4,'onion',0.04,null),
('Шурпа из баранины',5,'pepper',0.04,null),('Шурпа из баранины',6,'tomato',0.05,null),('Шурпа из баранины',7,'cilantro',0.1,null),
('Крем-суп чечевичный',1,'lentil',0.07,300),('Крем-суп чечевичный',2,'onion',0.03,null),('Крем-суп чечевичный',3,'carrot',0.03,null),('Крем-суп чечевичный',4,'cream',0.05,null),
('Крем-суп чечевичный',5,'butter',0.01,null),('Крем-суп чечевичный',6,'bread',0.02,null),
-- паста
('Спагетти «Карбонара»',1,'spaghetti',0.10,300),('Спагетти «Карбонара»',2,'bacon',0.05,null),('Спагетти «Карбонара»',3,'cream',0.08,null),
('Спагетти «Карбонара»',4,'parmesan',0.02,null),('Спагетти «Карбонара»',5,'egg',1,null),('Спагетти «Карбонара»',6,'garlic',0.003,null),('Спагетти «Карбонара»',7,'oil',0.005,null),
-- горячее
('Плов ташкентский',1,'rice',0.12,350),('Плов ташкентский',2,'beef',0.12,null),('Плов ташкентский',3,'carrot',0.10,null),('Плов ташкентский',4,'onion',0.04,null),
('Плов ташкентский',5,'oil',0.03,null),('Плов ташкентский',6,'chickpea',0.015,null),('Плов ташкентский',7,'garlic',0.01,null),
('Суйру лагман',1,'lagman',0.15,400),('Суйру лагман',2,'beef',0.10,null),('Суйру лагман',3,'pepper',0.05,null),('Суйру лагман',4,'tomato',0.04,null),
('Суйру лагман',5,'onion',0.03,null),('Суйру лагман',6,'cabbage',0.03,null),('Суйру лагман',7,'celery',0.02,null),('Суйру лагман',8,'garlic',0.005,null),('Суйру лагман',9,'oil',0.02,null),
('Куриное филе с брокколи',1,'chicken',0.18,300),('Куриное филе с брокколи',2,'broccoli',0.12,null),('Куриное филе с брокколи',3,'cream',0.05,null),
('Куриное филе с брокколи',4,'parmesan',0.01,null),('Куриное филе с брокколи',5,'garlic',0.003,null),('Куриное филе с брокколи',6,'oil',0.01,null),
-- мангал
('Колбасный микс',1,'sausage',0.30,350),('Колбасный микс',2,'onion_red',0.03,null),('Колбасный микс',3,'ketchup',0.03,null),('Колбасный микс',4,'mustard',0.01,null),
-- гарниры
('Картофельное пюре',1,'potato',0.20,200),('Картофельное пюре',2,'butter',0.015,null),('Картофельное пюре',3,'milk',0.05,null),
('Брокколи на пару',1,'broccoli',0.16,150),('Брокколи на пару',2,'butter',0.005,null),
('Овощи на пару',1,'broccoli',0.07,200),('Овощи на пару',2,'carrot',0.05,null),('Овощи на пару',3,'zucchini',0.06,null),('Овощи на пару',4,'pepper',0.04,null),('Овощи на пару',5,'butter',0.005,null),
-- выпечка
('Хачапури с сыром',1,'flour',0.15,350),('Хачапури с сыром',2,'suluguni',0.10,null),('Хачапури с сыром',3,'mozz',0.05,null),('Хачапури с сыром',4,'egg',1,null),
('Хачапури с сыром',5,'butter',0.015,null),('Хачапури с сыром',6,'milk',0.06,null),
-- суши (порция = 8 шт)
('Аляска темпура',1,'sushi_rice',0.12,250),('Аляска темпура',2,'nori',1,null),('Аляска темпура',3,'crab',0.05,null),('Аляска темпура',4,'cream_cheese',0.04,null),
('Аляска темпура',5,'cucumber',0.03,null),('Аляска темпура',6,'tempura',0.04,null),('Аляска темпура',7,'oil_fry',0.03,null),('Аляска темпура',8,'unagi',0.01,null),
('Запечённый суши',1,'sushi_rice',0.12,220),('Запечённый суши',2,'nori',1,null),('Запечённый суши',3,'salmon',0.05,null),('Запечённый суши',4,'cream_cheese',0.03,null),
('Запечённый суши',5,'mayo',0.03,null),('Запечённый суши',6,'sriracha',0.005,null),('Запечённый суши',7,'tobiko',0.005,null),('Запечённый суши',8,'unagi',0.01,null),
('Запечённый ролл с лососем',1,'sushi_rice',0.12,250),('Запечённый ролл с лососем',2,'nori',1,null),('Запечённый ролл с лососем',3,'salmon',0.06,null),
('Запечённый ролл с лососем',4,'cream_cheese',0.04,null),('Запечённый ролл с лососем',5,'cucumber',0.02,null),('Запечённый ролл с лососем',6,'mayo',0.03,null),
('Запечённый ролл с лососем',7,'tobiko',0.005,null),('Запечённый ролл с лососем',8,'unagi',0.01,null),
-- блюда из пивных сетов — ТОЛЬКО если у них ещё нет техкарты
('Картошка фри',1,'fries',0.15,150),('Картошка фри',2,'oil_fry',0.02,null),('Картошка фри',3,'ketchup',0.03,null),
('Картофель по-деревенски',1,'wedges',0.15,150),('Картофель по-деревенски',2,'oil_fry',0.02,null),
('Сырные палочки',1,'cheese_sticks',0.15,150),('Сырные палочки',2,'oil_fry',0.02,null),
('Хрустящие нагетсы',1,'nuggets',0.18,180),('Хрустящие нагетсы',2,'oil_fry',0.02,null),
('Крылышки барбекю',1,'wings',0.35,300),('Крылышки барбекю',2,'bbq',0.04,null),('Крылышки барбекю',3,'oil',0.01,null),
('Мини-чебуреки',1,'chebureki',0.20,200),('Мини-чебуреки',2,'oil_fry',0.03,null);

-- пересчёт количества из «моей» единицы в единицу продукта на складе
create or replace function pg_temp.tc_conv(q numeric, u1 text, u2 text, w1 numeric, pack numeric, g_unit numeric) returns numeric
language sql immutable as $$
  select case
    when u1 = u2 then q
    when u1 = 'шт' and w1 is not null and u2 in ('кг','л') then q * w1
    when u1 = 'шт' and w1 is not null and u2 in ('г','мл') then q * w1 * 1000
    when u1 in ('кг','л') and u2 in ('кг','л') then q
    when u1 in ('кг','л') and u2 in ('г','мл') then q * 1000
    when u1 in ('кг','л') and u2 = 'шт' and pack > 0 then q / pack
    when u1 in ('кг','л') and u2 = 'шт' and g_unit > 0 then q * 1000 / g_unit
    else null end
$$;

do $tc$
declare r record; d record; v numeric; n int; miss text; newid int;
begin
  perform set_config('niet.nopush','1',true);

  -- подобрать продукт со склада для каждого ингредиента (активный, лучше — с той же единицей и коротким названием)
  update ing i set pid = m.id, pname = m.name, punit = m.u, pprice = m.price, ploss = m.loss_pct, pg = m.g_unit
    from (select distinct on (i2.key) i2.key, p.id, p.name, p.price, coalesce(p.loss_pct,0) loss_pct, p.g_unit,
                 case lower(trim(coalesce(p.unit,''))) when 'кг.' then 'кг' when 'kg' then 'кг' when 'л.' then 'л' when 'l' then 'л'
                   when 'шт.' then 'шт' when 'бут' then 'шт' when 'уп' then 'шт' when 'пач' then 'шт' when 'пучок' then 'шт'
                   when 'гр' then 'г' when 'гр.' then 'г' else lower(trim(coalesce(p.unit,''))) end u
            from ing i2 join products p on not coalesce(p.archived,false)
             and translate(lower(p.name),'ё','е') ~ i2.inc
             and (i2.exc is null or translate(lower(p.name),'ё','е') !~ i2.exc)
           order by i2.key, (lower(p.unit) = i2.unit) desc, length(p.name), p.id) m
   where m.key = i.key;

  -- нужные, но отсутствующие продукты — создать
  for r in select * from ing where pid is null and key in (select key from tc union select unnest(array['onion_rings','dumplings','oil_fry'])) loop
    insert into products(name, unit, price, station) values (r.new_name, r.unit, r.price, r.station) returning id into newid;
    update ing set pid = newid, pname = r.new_name, punit = r.unit, pprice = r.price, ploss = 0 where key = r.key;
    insert into tc_log values (2, 'Новый продукт', r.new_name,
      r.price || ' ₸/' || r.unit || case when r.est then ' — ⚠ цена ПРИМЕРНАЯ (рынок Астаны), впишите свою' else ' — цена из ваших чеков' end);
  end loop;

  -- техкарты: только блюдам без техкарты
  for d in select distinct t.dish, x.id, x.is_set from tc t join dishes x on lower(x.name) = lower(t.dish) and not coalesce(x.archived,false) loop
    if d.is_set then continue; end if;
    if exists (select 1 from recipes where dish_id = d.id) then
      insert into tc_log values (4, 'Пропущено', d.dish, 'техкарта уже есть — не трогали');
      continue;
    end if;
    miss := null;
    for r in select t.qty, i.* from tc t join ing i on i.key = t.key where lower(t.dish) = lower(d.dish) order by t.ord loop
      v := pg_temp.tc_conv(r.qty, r.unit, r.punit, r.w1, r.pack, r.pg);
      if v is null or v <= 0 then
        miss := coalesce(miss || ', ', '') || r.pname || ' (единица «' || r.punit || '» — впишите количество сами)';
        continue;
      end if;
      insert into recipes(dish_id, product_id, qty) values (d.id, r.pid, round(v, 4))
      on conflict (dish_id, product_id) do update set qty = recipes.qty + excluded.qty;
    end loop;
    update dishes set out_g = t.out_g from tc t where dishes.id = d.id and lower(t.dish) = lower(d.dish) and t.out_g is not null and dishes.out_g is null;
    insert into tc_log values (3, 'Техкарта составлена', d.dish, coalesce('⚠ не вошло: ' || miss, ''));
  end loop;

  -- сеты: луковые кольца и жареные пельмени
  for r in select * from (values ('Пивной сет №1','onion_rings',0.15),('Пивной сет №3','onion_rings',0.15),('Пивной сет №2','dumplings',0.15),('Пивной сет №2','oil_fry',0.02)) s(nm,key,q) loop
    select id into n from dishes where lower(name) = lower(r.nm) and is_set limit 1;
    select * into d from ing where key = r.key;
    if n is null or d.pid is null then continue; end if;
    if not exists (select 1 from set_items where set_id = n and product_id = d.pid) then
      v := pg_temp.tc_conv(r.q, d.unit, d.punit, d.w1, d.pack, d.pg);
      if v is not null then
        insert into set_items(set_id, product_id, qty, pos) values (n, d.pid, round(v,4), (select count(*) from set_items where set_id = n));
        insert into tc_log values (5, 'В сет добавлено', r.nm, d.pname || ' ' || rtrim(rtrim(round(v,4)::text,'0'),'.') || ' ' || d.punit);
      end if;
    end if;
  end loop;

  -- КБЖУ по новым техкартам (если функция есть)
  begin perform dish_nutrition_refresh(); exception when others then null; end;
end $tc$;

-- ================= ОТЧЁТ =================
select kind as "Что", what as "Позиция", info as "Подробности", null::numeric as "Себестоимость, ₸", null::numeric as "Цена для фудкоста 30 %, ₸", ord
  from tc_log where ord <> 3
union all
select 'Техкарта', d.name || coalesce(' · выход ' || d.out_g || ' г', ''),
       string_agg(p.name || ' ' || rtrim(rtrim(round(r.qty,4)::text,'0'),'.') || ' ' || p.unit, ', ' order by p.name)
         || coalesce(' · ' || max(l.info) filter (where l.info <> ''), ''),
       round(sum(r.qty * p.price * (1 + coalesce(p.loss_pct,0)/100))),
       ceil(sum(r.qty * p.price * (1 + coalesce(p.loss_pct,0)/100)) / 0.3 / 10) * 10, 3
  from tc_log l join dishes d on lower(d.name) = lower(l.what)
  join recipes r on r.dish_id = d.id join products p on p.id = r.product_id
 where l.ord = 3 group by d.name, d.out_g
union all
select 'Сет (собран сам)', d.name, string_agg(coalesce(x.name, p.name) || ' × ' || rtrim(rtrim(round(s.qty,4)::text,'0'),'.'), ', ' order by s.pos),
       (select round(sum(r.qty * pp.price * (1 + coalesce(pp.loss_pct,0)/100))) from recipes r join products pp on pp.id = r.product_id where r.dish_id = d.id),
       (select ceil(sum(r.qty * pp.price * (1 + coalesce(pp.loss_pct,0)/100)) / 0.3 / 10) * 10 from recipes r join products pp on pp.id = r.product_id where r.dish_id = d.id), 6
  from dishes d join set_items s on s.set_id = d.id left join dishes x on x.id = s.dish_id left join products p on p.id = s.product_id
 where d.is_set and not coalesce(d.archived,false) group by d.id, d.name
order by ord, 2;
