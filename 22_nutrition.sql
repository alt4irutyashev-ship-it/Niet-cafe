-- Niet Café 22: КБЖУ и основные аллергены для всех блюд (видят и гости).
-- Выполнить ПОСЛЕ 21_delivery.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
--
-- Как считается:
--   • у продуктов появляются КБЖУ на 100 г и аллергены (по справочнику; ваши ручные значения не трогаются);
--   • если у блюда есть техкарта и у всех её продуктов известны КБЖУ — КБЖУ блюда считается по техкарте
--     (нетто, сырые продукты); иначе берутся типовые значения порции для этого блюда;
--   • аллергены блюда = аллергены продуктов техкарты + типовые аллергены блюда (лучше предупредить лишний раз);
--   • при изменении техкарты КБЖУ блюда пересчитывается само. Если руководитель вписал КБЖУ вручную —
--     автопересчёт для этого блюда выключается (кнопка «КБЖУ по техкарте» в Меню включает его обратно).
-- Основные аллергены: глютен, молоко, яйца, рыба, ракообразные, соя, кунжут, орехи, арахис.
-- Если техкарта неполная (КБЖУ по ней отличается от типовой порции больше чем в 1,6 раза) —
-- берутся типовые значения, а руководитель видит подсказку в Меню.
-- Значения ориентировочные — гости видят пометку «≈».

alter table products add column if not exists kcal numeric;
alter table products add column if not exists prot numeric;
alter table products add column if not exists fat numeric;
alter table products add column if not exists carb numeric;
alter table products add column if not exists allerg text;
alter table products add column if not exists g_unit numeric;          -- граммов в 1 шт (яйцо, булочка, бутылка)
alter table products add column if not exists nut_manual boolean not null default false;
alter table dishes add column if not exists weight int;
alter table dishes add column if not exists kcal int;
alter table dishes add column if not exists prot numeric;
alter table dishes add column if not exists fat numeric;
alter table dishes add column if not exists carb numeric;
alter table dishes add column if not exists allerg text;
alter table dishes add column if not exists nut_auto boolean not null default true;
alter table dishes add column if not exists nut_src text;              -- techcard / typical / manual
alter table dishes add column if not exists nut_note text;             -- подсказка руководителю

-- уже заполненные вручную блюда не перезаписываем (только при первом запуске)
update dishes set nut_auto=false, nut_src='manual' where nut_src is null and kcal is not null;

-- ===== Справочник КБЖУ продуктов (на 100 г) =====
create table if not exists nut_ref(key text primary key, inc text[], exc text[], prio int, kcal numeric, prot numeric, fat numeric, carb numeric, allerg text, g_unit numeric);
alter table nut_ref enable row level security;
drop policy if exists nut_ref_boss on nut_ref;
create policy nut_ref_boss on nut_ref for select using (my_role()='boss');
delete from nut_ref;
insert into nut_ref values
('beef_mince',array['фарш']::text[],array['кур','рыб','инде']::text[],30,254,17.2,20.0,0,null,null),
('beef',array['(говяд|телят|рибай|тибон|антрекот|вырезк|стейк)']::text[],array['фарш','язык','печен']::text[],10,187,18.9,12.4,0,null,null),
('lamb_rib',array['баран','ребр']::text[],'{}'::text[],25,290,15.0,25.5,0,null,null),
('lamb',array['баран']::text[],array['фарш']::text[],10,209,15.6,16.3,0,null,null),
('ch_fillet',array['(кур.*филе|филе.*кур|грудк)']::text[],array['бедр','утк','инде','копч']::text[],20,113,23.6,1.9,0.4,null,null),
('ch_thigh',array['бедр']::text[],array['утк','инде']::text[],18,185,16.8,13.1,0,null,null),
('ch_wing',array['крыл']::text[],array['утк']::text[],18,186,19.2,12.2,0,null,null),
('ch_leg',array['окороч']::text[],'{}'::text[],18,158,16.8,10.2,0,null,null),
('chicken',array['(кур|цыпл|бройлер)']::text[],array['копч','куркум','курдюк']::text[],8,190,16.0,14.0,0,null,null),
('duck',array['утк']::text[],array['соус']::text[],15,308,16.5,26.6,0,null,null),
('salmon',array['(семг|лосос)']::text[],array['икр']::text[],15,208,20.4,13.4,0,'рыба',null),
('trout',array['форел']::text[],array['икр']::text[],15,97,19.2,2.1,0,'рыба',null),
('pikeperch',array['судак']::text[],'{}'::text[],15,84,18.4,1.1,0,'рыба',null),
('seabass',array['(сибас|дорад)']::text[],'{}'::text[],15,97,18.4,2.0,0,'рыба',null),
('eel',array['(угор|угр[яеи]|унаги)']::text[],array['соус']::text[],15,290,23.0,21.0,3.0,'рыба',null),
('fish_any',array['(рыб|тунец|скумбр|минтай|треск|икр)']::text[],array['соус']::text[],5,150,20.0,7.0,0,'рыба',null),
('shrimp',array['кревет']::text[],array['чипс']::text[],15,87,18.0,1.1,0.8,'ракообразные',null),
('crab',array['(краб|снеж)']::text[],'{}'::text[],12,73,6.0,1.0,10.0,'рыба, ракообразные',null),
('cream',array['сливк']::text[],array['растит','кокос']::text[],20,322,2.2,33.0,2.9,'молоко',null),
('mozz',array['моцарел']::text[],'{}'::text[],20,276,22.0,20.0,2.0,'молоко',null),
('suluguni',array['сулугун']::text[],'{}'::text[],20,286,20.0,22.0,0,'молоко',null),
('parmesan',array['пармез']::text[],'{}'::text[],20,392,35.0,28.0,0,'молоко',null),
('feta',array['(фет|брынз)']::text[],'{}'::text[],20,260,17.0,20.0,1.0,'молоко',null),
('creamcheese',array['(творожн.*сыр|сыр.*творожн|сливочн.*сыр|сыр.*сливочн|крем.?чиз|креметт|филадельф)']::text[],array['масл']::text[],22,300,6.0,29.0,3.0,'молоко',null),
('cheese',array['(^|[^а-яa-z])сыр']::text[],array['соус','палоч']::text[],8,360,25.0,28.0,0,'молоко',null),
('butter',array['масл','сливоч']::text[],array['сыр']::text[],25,662,0.8,72.5,1.3,'молоко',null),
('milk',array['^\s*молок']::text[],array['кокос','сгущ']::text[],20,52,2.8,2.5,4.7,'молоко',null),
('smetana',array['сметан']::text[],'{}'::text[],20,158,2.6,15.0,3.0,'молоко',null),
('tvorog',array['творог']::text[],array['сыр']::text[],20,121,17.0,5.0,1.8,'молоко',null),
('egg',array['(яйц|яйк)']::text[],array['лапш']::text[],20,157,12.7,10.9,0.7,'яйца',55),
('mayo',array['майонез']::text[],'{}'::text[],25,627,0.3,67.0,2.6,'яйца',null),
('ketchup',array['кетчуп']::text[],'{}'::text[],25,93,1.8,0,22.0,null,null),
('fries',array['фри']::text[],array['фритюр','соус']::text[],22,150,2.5,5.0,24.0,null,null),
('potato',array['картоф']::text[],array['фри','крахмал']::text[],20,77,2.0,0.4,16.3,null,null),
('onion',array['(^|[^а-яa-z])лук']::text[],array['фри']::text[],20,41,1.4,0,10.4,null,null),
('carrot',array['морков']::text[],'{}'::text[],20,35,1.3,0.1,6.9,null,null),
('cabbage',array['капуст']::text[],'{}'::text[],20,27,1.8,0.1,4.7,null,null),
('tomato_paste',array['(томатн.*паст|паст.*томат)']::text[],'{}'::text[],25,82,4.8,0.5,16.0,null,null),
('tomato',array['(помидор|томат|черри)']::text[],array['соус','сок','кетчуп']::text[],20,20,1.1,0.2,3.7,null,null),
('cucumber',array['огур']::text[],'{}'::text[],20,14,0.8,0.1,2.5,null,null),
('pepper',array['перец','(болгар|сладк)']::text[],'{}'::text[],22,26,1.3,0,5.3,null,null),
('eggplant',array['баклаж']::text[],'{}'::text[],20,24,1.2,0.1,4.5,null,null),
('zucchini',array['кабач']::text[],'{}'::text[],20,24,0.6,0.3,4.6,null,null),
('mushroom',array['(шампин|гриб)']::text[],'{}'::text[],20,27,4.3,1.0,0.1,null,null),
('apple',array['яблок']::text[],array['сок']::text[],20,47,0.4,0.4,9.8,null,null),
('lemon',array['лимон']::text[],array['лимонад']::text[],20,34,0.9,0.1,3.0,null,null),
('greens',array['(зелен|укроп|петруш|кинз|базилик|салат|руккол|шпинат|мят)']::text[],'{}'::text[],10,30,2.0,0.4,4.0,null,null),
('garlic',array['чеснок']::text[],'{}'::text[],20,149,6.5,0.5,30.0,null,null),
('rice',array['(^|[^а-яa-z])рис']::text[],array['уксус','бумаг','мук']::text[],20,344,6.7,0.7,78.9,null,null),
('flour',array['мук']::text[],'{}'::text[],20,334,10.3,1.1,70.0,'глютен',null),
('tempura',array['(темпур|панко|панир|сухар)']::text[],'{}'::text[],25,350,9.0,1.5,76.0,'глютен',null),
('pasta',array['(макарон|спагет|феттуч|пенне|тальятел|паста)']::text[],array['томат','кунжут','зубн']::text[],15,344,10.4,1.1,69.7,'глютен',null),
('noodle',array['(лапш|рамен|удон)']::text[],array['рис']::text[],18,280,10.0,2.0,56.0,'глютен, яйца',null),
('dough',array['(тест|лаваш|хлеб|лепеш)']::text[],'{}'::text[],15,260,8.0,3.0,50.0,'глютен',null),
('bun',array['булоч']::text[],'{}'::text[],20,260,8.5,4.0,47.0,'глютен, кунжут',80),
('sugar',array['сахар']::text[],'{}'::text[],20,399,0,0,99.8,null,null),
('honey',array['мед']::text[],'{}'::text[],20,304,0.3,0,82.0,null,null),
('salt',array['(^|[^а-яa-z])(соль|специ|перец черн)']::text[],'{}'::text[],12,0,0,0,0,null,null),
('oil',array['(подсолн|растит|фритюр|оливк)']::text[],array['сливоч','кунжут']::text[],20,899,0,99.9,0,null,null),
('soy',array['(соев|тофу)']::text[],'{}'::text[],25,51,6.0,0,5.7,'глютен, соя',null),
('sesame',array['кунжут']::text[],'{}'::text[],25,573,18.0,49.0,23.0,'кунжут',null),
('nori',array['нори']::text[],'{}'::text[],25,35,6.0,0.3,5.0,null,3),
('ginger',array['имбир']::text[],'{}'::text[],20,50,0.2,0.3,12.0,null,null),
('wasabi',array['васаби']::text[],'{}'::text[],20,290,2.0,9.0,48.0,null,null),
('nuts',array['(орех|миндал|фундук|кешью|фисташ|кедр)']::text[],'{}'::text[],20,654,15.0,65.0,7.0,'орехи',null),
('peanut',array['арахис']::text[],'{}'::text[],25,552,26.0,45.0,10.0,'арахис',null),
('bbq',array['(барбекю|bbq)']::text[],'{}'::text[],20,160,1.0,0.5,38.0,null,null),
('cola1',array['(cola|кола|fanta|фанта|sprite|спрайт)','1 ?(л|l)']::text[],array['0[,.]']::text[],25,42,0,0,10.6,null,1000),
('cola033',array['(cola|кола|fanta|фанта|sprite|спрайт|schweppes|швепс)']::text[],'{}'::text[],20,42,0,0,10.6,null,330),
('redbull',array['(red ?bull|ред ?булл)']::text[],'{}'::text[],25,45,0,0,11.0,null,250),
('juice',array['(^|[^а-яa-z])сок']::text[],'{}'::text[],15,46,0.5,0,11.0,null,1000),
('water',array['(вода|боржоми|borjomi)']::text[],'{}'::text[],15,0,0,0,0,null,500),
('tea',array['(^|[^а-яa-z])чай']::text[],'{}'::text[],15,0,0,0,0,null,null);

-- Типовые порции блюд меню
create table if not exists dish_nut_ref(name text primary key, weight int, kcal int, prot numeric, fat numeric, carb numeric, allerg text);
alter table dish_nut_ref enable row level security;
drop policy if exists dish_nut_ref_boss on dish_nut_ref;
create policy dish_nut_ref_boss on dish_nut_ref for select using (my_role()='boss');
delete from dish_nut_ref;
insert into dish_nut_ref values
('свежие салаты',250,110,3,7,9,null),
('цезарь с курицей',250,420,25,28,16,'глютен, молоко, яйца, рыба'),
('греческий салат',250,290,8,24,10,'молоко'),
('малибу',250,380,18,28,12,'яйца'),
('пекинский салат с фирменным соусом',250,330,14,24,14,'яйца'),
('тёплый салат с телятиной от шефа',250,360,24,24,10,'соя'),
('салат с уткой в апельсиновом соусе',250,390,20,26,18,null),
('фирменный салат',250,380,18,27,14,'молоко, яйца'),
('хрустящий баклажан',250,420,6,28,34,'глютен, соя, кунжут'),
('фирменные крылышки',300,690,48,50,12,'соя'),
('крылышки барбекю',300,680,46,48,16,null),
('хрустящие нагетсы',250,620,34,36,38,'глютен, яйца'),
('тигровые креветки',200,320,34,18,4,'молоко, ракообразные'),
('сырные палочки',200,640,26,42,38,'глютен, молоко, яйца'),
('мини-чебуреки',250,720,22,44,58,'глютен'),
('солянка от шефа',350,260,16,18,8,'молоко'),
('пельмени',350,480,20,22,48,'глютен, молоко, яйца'),
('суп-лапша с курицей',350,220,16,7,22,'глютен, яйца'),
('уха по-царски',350,210,22,8,12,'рыба'),
('рамен с курицей',450,520,30,18,58,'глютен, яйца, соя, кунжут'),
('рамен с говядиной',450,560,32,22,58,'глютен, яйца, соя, кунжут'),
('том ям с креветкой',400,340,22,22,12,'рыба, ракообразные'),
('харчо по-грузински',350,300,18,14,24,'орехи'),
('бозбаш по-кавказски',400,420,26,22,28,null),
('альфредо (курица и грибы)',350,680,32,34,60,'глютен, молоко'),
('паста с креветками',350,640,28,30,62,'глютен, молоко, ракообразные'),
('паста болоньезе',350,620,30,24,68,'глютен, молоко'),
('фрикасе из курицы в сливочном соусе',350,520,36,32,18,'глютен, молоко'),
('куриная грудка в сливочном соусе',350,560,48,36,10,'молоко'),
('бефстроганов из говядины',350,520,36,34,14,'глютен, молоко'),
('говядина по-тайски',350,480,34,26,24,'соя, кунжут'),
('казан-кебаб по-восточному',400,780,38,52,40,null),
('говядина с картофелем в сливочном соусе',400,680,36,40,42,'молоко'),
('куырдак из баранины',350,720,34,56,20,null),
('оджахури',400,690,34,46,36,null),
('мимино (говядина под сыром)',350,640,44,48,6,'молоко'),
('гуйру лагман',450,640,30,26,72,'глютен, соя'),
('гуйру цомян',450,660,30,26,76,'глютен, соя'),
('домашний лагман',450,600,28,22,70,'глютен'),
('форель на мангале',350,420,50,24,0,'рыба'),
('сёмга под икорным соусом',300,560,42,40,6,'молоко, рыба'),
('судак с овощами в кисло-сладком соусе',350,380,32,12,34,'глютен, рыба'),
('сибас на мангале',350,380,44,22,0,'рыба'),
('тибон на мангале',400,760,64,56,0,null),
('рибай стейк на мангале',300,780,56,62,0,null),
('стейк от шефа',300,700,58,52,2,'молоко'),
('баранина на углях',200,560,32,48,0,null),
('антрекот на мангале',200,470,40,34,0,null),
('рёбрышки на мангале',250,680,36,60,0,null),
('куриное филе на мангале',220,300,48,10,2,null),
('окорочка на мангале',250,520,44,38,0,null),
('крылышки на мангале',250,560,40,44,0,null),
('утка на мангале',250,760,38,66,0,null),
('шампиньоны на мангале',200,90,8,4,4,null),
('картошка фри',150,450,5,22,56,null),
('картофель по-деревенски',200,380,5,18,48,null),
('рис',200,260,5,2,56,null),
('овощи на углях',250,160,4,10,14,null),
('кетчуп',50,50,1,0,12,null),
('соус тартар',50,300,1,32,2,'яйца'),
('шашлычный соус',50,40,1,0,9,null),
('соус демиглас',50,50,2,3,4,'глютен'),
('сырный соус',50,160,3,15,3,'молоко, яйца'),
('соус барбекю',50,80,0,0,20,null),
('хачапури по-мегрельски',450,1350,56,66,130,'глютен, молоко, яйца'),
('хачапури по-аджарски',400,1180,50,58,116,'глютен, молоко, яйца'),
('хычины с сыром',250,640,24,26,76,'глютен, молоко'),
('хычины с зеленью',250,520,12,16,80,'глютен'),
('пицца маргарита',450,1080,46,40,134,'глютен, молоко'),
('пепперони',450,1240,52,58,128,'глютен, молоко'),
('четыре сезона',500,1250,54,56,134,'глютен, молоко'),
('курица с грибами',500,1200,60,48,132,'глютен, молоко'),
('фирменная пицца',550,1380,62,64,138,'глютен, молоко'),
('филадельфия',250,480,18,22,52,'молоко, рыба'),
('калифорния',230,420,12,16,56,'яйца, рыба, ракообразные, кунжут'),
('дракон',250,520,16,24,58,'молоко, рыба, соя, кунжут'),
('роллы от шефа',260,520,18,24,56,'молоко, рыба, кунжут'),
('америка темпура',280,640,18,30,70,'глютен, молоко, яйца, рыба, ракообразные'),
('лосось темпура',280,620,18,28,70,'глютен, молоко, яйца, рыба'),
('унаги темпура',280,650,18,30,72,'глютен, молоко, яйца, рыба, соя, кунжут'),
('вулкан с лососем',260,560,16,28,58,'молоко, яйца, рыба'),
('вулкан с угрём',260,580,16,30,58,'яйца, рыба, соя, кунжут'),
('вулкан с крабом',260,520,12,26,58,'яйца, рыба, ракообразные'),
('гамбургер',300,690,34,38,48,'глютен, молоко, яйца, кунжут'),
('бургер от шефа (грибной фирменный соус)',330,780,38,44,52,'глютен, молоко, яйца, кунжут'),
('фирменный бургер (с двойной котлетой)',420,1080,60,66,54,'глютен, молоко, яйца, кунжут'),
('чёрный чай',800,5,0,0,1,null),
('зелёный чай',800,5,0,0,1,null),
('чёрный чай с молоком',800,90,5,5,7,'молоко'),
('ташкентский чай',800,160,0,0,40,null),
('марокканский чай',800,180,0,0,45,null),
('фруктовый чай',800,220,1,0,54,null),
('облепиховый чай',800,260,1,4,52,null),
('молоко',100,52,3,2.5,4.7,'молоко'),
('лимон',30,10,0,0,1,null),
('мёд',30,98,0,0,24,null),
('coca-cola (0,33 л)',330,139,0,0,35,null),
('coca-cola / fanta / sprite (1 л)',1000,420,0,0,106,null),
('домашние лимонады в ассортименте',500,200,0,0,50,null),
('schweppes',330,130,0,0,32,null),
('red bull',250,113,0,0,28,null),
('сок в ассортименте',1000,460,2,0,110,null),
('вода (с газом / без газа)',500,0,0,0,0,null),
('borjomi',500,0,0,0,0,null);

-- ===== КБЖУ продуктам (кроме заполненных вручную) =====
with p as (select id, translate(lower(name),'ё','е') n from products where not nut_manual),
m as (select distinct on (p.id) p.id, r.* from p join nut_ref r
        on not exists (select 1 from unnest(r.inc) x where p.n !~ x)
       and not exists (select 1 from unnest(r.exc) x where p.n ~ x)
      order by p.id, r.prio desc, r.key)
update products pr set kcal=m.kcal, prot=m.prot, fat=m.fat, carb=m.carb, allerg=m.allerg, g_unit=coalesce(pr.g_unit,m.g_unit)
from m where m.id=pr.id;

-- объединение аллергенов в правильном порядке
create or replace function alg_union(a text[]) returns text language sql immutable as $$
  select nullif(string_agg(x, ', ' order by array_position(array['глютен','молоко','яйца','рыба','ракообразные','соя','кунжут','орехи','арахис'], x)), '')
  from (select distinct trim(t) x from unnest(a) u, regexp_split_to_table(coalesce(u,''), ',') t where trim(t)<>'') z
$$;

-- граммы продукта в техкарте
create or replace function nut_grams(qty numeric, unit text, g_unit numeric) returns numeric language sql immutable as $$
  select case lower(trim(coalesce(unit,'')))
    when 'кг' then qty*1000 when 'kg' then qty*1000 when 'л' then qty*1000 when 'l' then qty*1000
    when 'г' then qty when 'гр' then qty when 'мл' then qty
    when 'шт' then qty*g_unit when 'шт.' then qty*g_unit else null end
$$;

-- ===== Пересчёт КБЖУ блюд =====
create or replace function dish_nutrition_refresh(p_dish int default null) returns int
language plpgsql security definer set search_path=public as $$
declare n int;
begin
  with tc as (
    select r.dish_id, count(*) cnt,
           count(*) filter (where p.kcal is not null and nut_grams(r.qty,p.unit,p.g_unit) is not null) ok,
           sum(nut_grams(r.qty,p.unit,p.g_unit)) g,
           sum(nut_grams(r.qty,p.unit,p.g_unit)*p.kcal/100) k, sum(nut_grams(r.qty,p.unit,p.g_unit)*p.prot/100) pr,
           sum(nut_grams(r.qty,p.unit,p.g_unit)*p.fat/100) f, sum(nut_grams(r.qty,p.unit,p.g_unit)*p.carb/100) c,
           array_agg(p.allerg) a
    from recipes r join products p on p.id=r.product_id
    where p_dish is null or r.dish_id=p_dish group by r.dish_id),
  v as (
    select d.id,
      (t.cnt>=1 and t.cnt=t.ok and (case when s.kcal>0 then t.k between 0.6*s.kcal and 1.6*s.kcal else s.kcal is not null or t.cnt>=2 end)) use_tc,
      (t.cnt>=1 and t.cnt=t.ok and s.kcal>0 and not t.k between 0.6*s.kcal and 1.6*s.kcal) tc_odd, t.*, s.weight sw, s.kcal sk, s.prot sp, s.fat sf, s.carb sc, s.allerg sa
    from dishes d left join tc t on t.dish_id=d.id left join dish_nut_ref s on s.name=lower(trim(d.name))
    where d.nut_auto and (p_dish is null or d.id=p_dish))
  update dishes d set
    weight = case when v.use_tc then coalesce(v.sw, round(v.g)) else v.sw end,
    kcal   = case when v.use_tc then round(v.k) else v.sk end,
    prot   = case when v.use_tc then round(v.pr,1) else v.sp end,
    fat    = case when v.use_tc then round(v.f,1) else v.sf end,
    carb   = case when v.use_tc then round(v.c,1) else v.sc end,
    allerg = alg_union(coalesce(v.a,'{}'::text[]) || array[v.sa]),
    nut_src= case when v.use_tc then 'techcard' when v.sk is not null then 'typical' else null end,
    nut_note= case when v.tc_odd then 'По техкарте выходит '||round(v.k)||' ккал, а типовая порция ≈'||v.sk||' — проверьте, все ли продукты в техкарте'
                   when v.cnt is not null and v.cnt<>v.ok then 'В техкарте есть продукты без КБЖУ — показаны типовые значения'
                   end
  from v where v.id=d.id and (v.use_tc or v.sk is not null or v.a is not null);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function dish_nutrition_refresh(int) from public, anon;
grant execute on function dish_nutrition_refresh(int) to authenticated;

-- новый или переименованный продукт получает КБЖУ из справочника (если не вписаны вручную)
create or replace function products_nut() returns trigger language plpgsql security definer set search_path=public as $$
declare m nut_ref%rowtype; n text := translate(lower(coalesce(new.name,'')),'ё','е');
begin
  if new.nut_manual or (tg_op='UPDATE' and new.name is not distinct from old.name) then return new; end if;
  select r.* into m from nut_ref r
   where not exists (select 1 from unnest(r.inc) x where n !~ x) and not exists (select 1 from unnest(r.exc) x where n ~ x)
   order by r.prio desc, r.key limit 1;
  if found then new.kcal:=m.kcal; new.prot:=m.prot; new.fat:=m.fat; new.carb:=m.carb; new.allerg:=m.allerg; new.g_unit:=coalesce(new.g_unit,m.g_unit);
  elsif tg_op='UPDATE' then new.kcal:=null; new.prot:=null; new.fat:=null; new.carb:=null; new.allerg:=null; end if;
  return new;
end $$;
drop trigger if exists products_nut_t on products;
create trigger products_nut_t before insert or update of name, nut_manual on products for each row execute function products_nut();
-- КБЖУ/аллергены продукта изменились → пересчитать блюда с этим продуктом
create or replace function products_nut_after() returns trigger language plpgsql security definer set search_path=public as $$
declare d int;
begin
  if (new.kcal,new.prot,new.fat,new.carb,new.allerg,new.unit,new.g_unit) is distinct from (old.kcal,old.prot,old.fat,old.carb,old.allerg,old.unit,old.g_unit) then
    for d in select distinct dish_id from recipes where product_id=new.id loop perform dish_nutrition_refresh(d); end loop;
  end if;
  return null;
end $$;
drop trigger if exists products_nut_a on products;
create trigger products_nut_a after update on products for each row execute function products_nut_after();
revoke execute on function products_nut() from public, anon;
revoke execute on function products_nut_after() from public, anon;

-- техкарта изменилась → КБЖУ блюда пересчитывается
create or replace function recipes_nut() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform dish_nutrition_refresh(coalesce(new.dish_id, old.dish_id));
  if tg_op='UPDATE' and new.dish_id is distinct from old.dish_id then perform dish_nutrition_refresh(old.dish_id); end if;
  return null;
end $$;
drop trigger if exists recipes_nut_t on recipes;
create trigger recipes_nut_t after insert or update or delete on recipes for each row execute function recipes_nut();
revoke execute on function recipes_nut() from public, anon;

select dish_nutrition_refresh() as "Блюд заполнено";
