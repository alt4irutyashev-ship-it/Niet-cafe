-- Niet Café: рыночные цены на продукты (Астана, ноябрь 2026).
-- Источники: мониторинг супермаркетов Астаны (Inbusiness.kz, 06.11.2026), Бюро нацстатистики,
-- оптовые поставщики HoReCa на Satu.kz (Good Food Group, Berry Company, EURO FOOD KZ и др.).
--
-- ШАГ 1 из 2. Этот файл НИЧЕГО не меняет в продуктах — только показывает, что изменится.
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Внизу появится таблица:
--   «обновится»        — цена будет заменена файлом 18_apply_prices.sql;
--   «без изменений»    — цена уже совпадает;
--   «проверьте вручную» — разница больше 50% (возможно, другой сорт/фасовка) — НЕ меняется;
--   «единица не та»    — у вас другая единица (например, «шт» вместо «кг») — НЕ меняется;
--   «нет рыночной цены» — продукт не нашёлся в справочнике — НЕ меняется.
-- Можно запускать повторно.

create table if not exists price_ref(
  key text primary key, title text, unit text, price numeric, lo numeric, hi numeric,
  inc text[], exc text[], prio int, source text, url text, note text, checked date default current_date);
alter table price_ref add column if not exists manual boolean not null default false;
alter table price_ref enable row level security;
drop policy if exists price_ref_boss on price_ref;
create policy price_ref_boss on price_ref for all using (my_role()='boss') with check (my_role()='boss');
revoke all on price_ref from anon;

delete from price_ref;
insert into price_ref(key,title,unit,price,lo,hi,inc,exc,prio,source,url,note,checked,manual) values
('beef_bone','Говядина на кости','кг',3990,3990,3990,array['говяд','кост']::text[],'{}'::text[],30,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('beef_mince','Фарш говяжий','кг',4300,3900,4300,array['фарш']::text[],array['кур','бара','свин','рыб','инде']::text[],30,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','в октябре 3900–4300','2026-11-10',false),
('beef','Говядина (мякоть)','кг',5900,5887,5900,array['говяд']::text[],array['кост','фарш','рибай','тибон','стейк','вырез','мрамор','язык','печен','ребр','грудин','тушен','антрекот']::text[],10,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','стат. средняя по Астане 5887 (07.10)','2026-11-10',false),
('lamb','Баранина','кг',5450,5441,6890,array['баран']::text[],array['ребр','кост','курдюк','печен','фарш','тушен']::text[],10,'Бюро нацстатистики через DigitalBusiness.kz, средние цены Астаны на 07.10.2026','https://digitalbusiness.kz/2026-10-13/kak-izmenilis-tseni-na-myaso-v-kazahstane-za-31-god-sravnili-govyadinu-i-baraninu/','в супермаркете 6890 (04.09); на рынке дешевле','2026-11-10',false),
('ch_thigh_fil','Филе бедра куриное','кг',2200,2000,2350,array['филе','бедр']::text[],array['утк','инде']::text[],26,'Satu.kz, поставщики Астаны (Good Food Group), филе куриное','https://satu.kz/astana/File-kurinoe.html','без кости, коробка 10 кг','2026-11-10',false),
('ch_fillet','Куриное филе','кг',2300,1850,2350,array['кур','филе']::text[],array['бедр','окороч','копч','варен']::text[],20,'Satu.kz, поставщики Астаны (Good Food Group), филе куриное','https://satu.kz/astana/File-kurinoe.html','охл. на подложке 2300–2350, замор. 1850','2026-11-10',false),
('ch_breast','Куриная грудка','кг',2300,1850,2350,array['грудк']::text[],array['утк','инде','копч']::text[],18,'Satu.kz, поставщики Астаны (Good Food Group), филе куриное','https://satu.kz/astana/File-kurinoe.html','','2026-11-10',false),
('ch_wings','Куриные крылья','кг',1700,1550,1850,array['крыл']::text[],array['утк','инде','соус']::text[],20,'Satu.kz, поставщики Астаны (Good Food Group), крылья','https://satu.kz/astana/Krylya-kurinye-1.html','','2026-11-10',false),
('ch_legs','Окорочка куриные','кг',1800,1351,1800,array['окороч']::text[],array['филе','копч']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','охлаждённые; замороженные 1351','2026-11-10',false),
('ch_thigh','Бедро куриное','кг',2100,2099,2124,array['бедр']::text[],array['филе','утк','инде','копч']::text[],19,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('ch_whole','Курица (тушка)','кг',1800,1799,2099,array['кур','(туш|целая|бройлер)']::text[],array['филе','копч']::text[],15,'Inbusiness.kz, супермаркеты Астаны, 18.10.2026','https://inbusiness.kz/index.php/ru/news/chto-tvoritsya-s-cenami-na-edu-v-stolice-kazahstana','охлаждённая; замороженная 2099','2026-11-10',false),
('ch_plain','Курица','кг',1800,1799,2099,array['^\s*курица\s*$']::text[],'{}'::text[],14,'Inbusiness.kz, супермаркеты Астаны, 18.10.2026','https://inbusiness.kz/index.php/ru/news/chto-tvoritsya-s-cenami-na-edu-v-stolice-kazahstana','','2026-11-10',false),
('duck','Утка (тушка)','кг',2450,1610,3350,array['утк']::text[],array['филе','грудк','копч','соус']::text[],20,'Satu.kz, тушка утки, оптовые поставщики','https://satu.kz/Tushku-utki.html','медиана 5 предложений; крупная утка 3300–3350','2026-11-10',false),
('salmon','Сёмга / лосось (целая)','кг',5600,5600,5600,array['(семг|лосос)']::text[],array['филе','копч','солен','слабосол','икр','стейк']::text[],20,'Satu.kz, сёмга в Астане','https://satu.kz/astana/Semga.html','1 предложение; филе выйдет ≈9300/кг','2026-11-10',true),
('trout','Форель','кг',5750,5500,6000,array['форел']::text[],array['филе','копч','солен','икр']::text[],20,'Satu.kz, форель радужная HoReCa','https://satu.kz/Forel-raduzhnaya.html','замороженная порционная','2026-11-10',false),
('shrimp_tiger','Креветки тигровые','кг',6950,5030,8889,array['кревет','(тигр|королев)']::text[],array['чипс','соус']::text[],22,'Satu.kz, тигровые креветки в Астане','https://satu.kz/astana/Tigrovye-krevetki.html','16/20 — 5030, 21/25 блок — 8889','2026-11-10',false),
('shrimp','Креветки','кг',6590,6590,6590,array['кревет']::text[],array['тигр','королев','чипс','соус']::text[],12,'Satu.kz, рыба и морепродукты (EURO FOOD KZ, Berry Company)','https://satu.kz/p105632401-file-sudaka-krupnyj.html','90/120 Polar','2026-11-10',false),
('eel','Угорь жареный (унаги)','кг',11100,8625,11100,array['(угор|угр|унаги)']::text[],array['соус']::text[],20,'Satu.kz, рыба и морепродукты (EURO FOOD KZ, Berry Company)','https://satu.kz/p105632401-file-sudaka-krupnyj.html','Китай, в наличии','2026-11-10',false),
('cream33','Сливки 33%','л',2650,2300,3340,array['сливк']::text[],array['растит','кокос','сух','масл','сыр']::text[],20,'Satu.kz, сливки 33% в Астане','https://satu.kz/astana/Slivki-33.html','5 предложений 2300–3340, медиана','2026-11-10',false),
('mozz','Моцарелла','кг',4400,3154,5150,array['моцарел']::text[],array['шарик','рассол','буррат','мини']::text[],20,'Satu.kz, моцарелла в Астане','https://satu.kz/astana/Syr-motsarella.html','для пиццы, медиана 5 предложений','2026-11-10',false),
('cremchees','Сыр сливочный (крем-чиз)','кг',2620,2533,2945,array['(творожн|сливочн|крем.?чиз|креметт|филадельф|cream)']::text[],array['масл','соус']::text[],18,'Satu.kz, сливочный сыр для суши (опт)','https://satu.kz/Syr-dlya-sushi;wholesale.html','69%, фасовка 1,5–6 кг, медиана 6 предложений','2026-11-10',false),
('cheese','Сыр твёрдый (весовой)','кг',6129,6129,6745,array['(^|[^а-яa-z])сыр']::text[],array['моцарел','сулугун','пармез','фет','брынз','творож','сливоч','крем','чеддер','плавл','дор','маскарп','рикот','адыг','тофу','соус','палоч','косичк','копч','cream']::text[],5,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','российский/голландский','2026-11-10',false),
('butter','Масло сливочное 72,5%','кг',4945,3609,4945,array['масл','сливоч']::text[],array['сыр']::text[],25,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','18.10 было 3609 — цена скачет','2026-11-10',false),
('milk','Молоко 2,5%','л',430,428,428,array['^\s*молоко']::text[],array['сгущ','кокос','сух','топлен']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','385 ₸ за пакет 0,9 л','2026-11-10',false),
('smetana','Сметана 15%','кг',1445,1445,1576,array['сметан']::text[],array['соус']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','549 ₸ за 380 г','2026-11-10',false),
('tvorog','Творог 5%','кг',2075,2075,2075,array['творог']::text[],array['сыр']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','415 ₸ за 200 г','2026-11-10',false),
('eggs','Яйца куриные','шт',61,52,61,array['(яйц|яйк)']::text[],array['перепел','лапш']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','1825 ₸ за лоток 30 шт','2026-11-10',false),
('potato','Картофель','кг',206,187,206,array['картоф']::text[],array['фри','дольк','пюре','сладк','батат','деревен','крахмал']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('fries','Картофель фри (заморож.)','кг',1515,920,1820,array['фри']::text[],array['соус','фритюр']::text[],22,'Satu.kz, картофель фри 2,5 кг в Астане','https://satu.kz/astana/Fri-kartofel-zamorozhennyj-25-kg.html','медиана 4 предложений, фасовка 2–2,5 кг','2026-11-10',false),
('onion','Лук репчатый','кг',122,116,138,array['(^|[^а-яa-z])лук']::text[],array['зелен','порей','красн','шалот','фри','сушен','жарен']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('carrot','Морковь','кг',188,185,195,array['морков']::text[],array['корейск','по-корейск']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('cabbage','Капуста белокочанная','кг',176,153,176,array['капуст']::text[],array['пекин','брокк','цветн','красн','квашен','морск','кольраб','брюссел']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('tomato','Помидоры','кг',995,599,1099,array['(помидор|томат)']::text[],array['паст','соус','черри','сок','сушен','консерв','пюре','вялен','кетчуп']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','в октябре 599–1099 — сезонный рост','2026-11-10',false),
('cucumber','Огурцы','кг',895,399,895,array['огур']::text[],array['марин','солен','консерв','корнишон']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','с сентября выросли с 449 до 895','2026-11-10',false),
('apple','Яблоки','кг',499,499,549,array['яблок']::text[],array['сок','уксус','сушен']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('champ','Шампиньоны','кг',1790,1230,1890,array['шампин']::text[],array['консерв','марин']::text[],20,'Satu.kz, шампиньоны в Астане','https://satu.kz/astana/Shampinony.html','замороженные целые; свежие не нашлись — проверьте','2026-11-10',false),
('rice','Рис','кг',345,310,425,array['(^|[^а-яa-z])рис']::text[],array['суш','уксус','бумаг','лапш','басмат','мук','японск','круглозерн']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','весовой; опт Камолино 310–370','2026-11-10',false),
('flour','Мука пшеничная','кг',320,288,320,array['мук']::text[],array['темпур','рис','кукуруз','миндал','панко']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','639 ₸ за 2 кг','2026-11-10',false),
('tempura','Мука темпура','кг',1350,1350,1350,array['темпур']::text[],array['соус']::text[],25,'Satu.kz, продукты для суши в Астане','https://satu.kz/astana/Sushi-produktsiya-dlya-prigotovleniya-sushi','','2026-11-10',false),
('sugar','Сахар','кг',465,465,465,array['сахар']::text[],array['пудр','тростн','сироп','ванил']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('salt','Соль','кг',154,125,154,array['(^|[^а-яa-z])соль']::text[],array['морск','гималай','нитрит']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','пачка 1 кг','2026-11-10',false),
('pasta','Макароны / спагетти','кг',315,299,315,array['(макарон|спагет|феттуч|пенне|тальятел)']::text[],'{}'::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','весовые; итальянские дороже','2026-11-10',false),
('oil','Масло подсолнечное','л',841,841,846,array['(подсолн|растит|фритюр)']::text[],array['сливоч','оливк','кунжут','сливк','сыр']::text[],20,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','','2026-11-10',false),
('tea_black','Чай чёрный','кг',4460,3916,4540,array['(^|[^а-яa-z])чай']::text[],array['зелен','фрукт','облеп','марокк','ташкент','травян','каркаде','молок']::text[],10,'Inbusiness.kz, супермаркеты Астаны, 06.11.2026','https://inbusiness.kz/ru/news/v-astane-izmenilis-ceny-na-socialnye-produkty-chto-stalo-dorozhe-a-chto-deshevle','1115 ₸ за 250 г','2026-11-10',false),
('mayo','Майонез','кг',1070,818,1230,array['майонез']::text[],'{}'::text[],20,'Satu.kz, майонез вёдра 5–10 кг','https://satu.kz/Majonez-vedro.html','вёдра 5–10 кг, медиана','2026-11-10',false),
('ginger','Имбирь маринованный','кг',1400,1400,1400,array['имбир','марин']::text[],'{}'::text[],25,'Satu.kz, продукты для суши в Астане','https://satu.kz/astana/Sushi-produktsiya-dlya-prigotovleniya-sushi','','2026-11-10',false),
('bun','Булочка для бургера','шт',265,260,270,array['булоч','(бургер|гамбург)']::text[],'{}'::text[],25,'Satu.kz, булочки для бургеров в Астане','https://satu.kz/astana/Bulochka-dlya-gamburgera-s-kunzhutom-125-mm.html','Lantmannen 75–82 г','2026-11-10',false),
('cola1l','Coca-Cola 1 л','шт',780,550,800,array['(cola|кола)','(^|[^0-9,.])1 ?(л|l)']::text[],array['0[,.]']::text[],25,'Satu.kz, Coca-Cola','https://satu.kz/Napitok-coca-cola.html','опт 800 ₸/бут. в упаковке 12','2026-11-10',false),
('redbull','Red Bull 0,25 л','шт',735,650,735,array['(red ?bull|ред ?булл)']::text[],'{}'::text[],25,'Satu.kz, Red Bull 0,25 л','https://satu.kz/p108138141-energeticheskij-napitok-red.html','650 ₸ от 720 шт','2026-11-10',false);

-- Предпросмотр
with p as (
  select p.id, p.name, p.unit, coalesce(p.price,0) as old_price,
         translate(lower(p.name),'ё','е') as n, case lower(trim(coalesce(p.unit,'')))
      when 'кг' then 'кг' when 'kg' then 'кг' when 'кг.' then 'кг' when 'килограмм' then 'кг'
      when 'л' then 'л' when 'l' then 'л' when 'л.' then 'л' when 'литр' then 'л'
      when 'шт' then 'шт' when 'шт.' then 'шт' when 'pcs' then 'шт' when 'штука' then 'шт'
      else lower(trim(coalesce(p.unit,''))) end as u
  from products p),
m as (
  select distinct on (p.id) p.*, r.key, r.title, r.unit as ref_unit, r.price as new_price, r.lo, r.hi, r.source, r.url, r.note, r.manual
  from p join price_ref r
    on not exists (select 1 from unnest(r.inc) x where p.n !~ x)
   and not exists (select 1 from unnest(r.exc) x where p.n ~ x)
  order by p.id, r.prio desc, r.key),
s as (
  select m.*, case
    when m.u <> m.ref_unit then 'unit'
    when m.manual then 'manual'
    when m.old_price > 0 and abs(m.new_price - m.old_price) / m.old_price > 0.5 then 'big'
    when m.old_price = m.new_price then 'same'
    else 'ok' end as st
  from m)
select name as "Продукт", unit as "Ед.", old_price as "Сейчас, ₸", new_price as "Рынок, ₸",
  case when old_price>0 then round((new_price-old_price)/old_price*100) end as "Разница, %",
  case st when 'ok' then 'обновится' when 'same' then 'без изменений'
          when 'big' then 'проверьте вручную: разница больше 50%'
          when 'manual' then 'проверьте вручную: мало данных' else 'единица не та (в справочнике: '||ref_unit||')' end as "Что будет",
  lo||'–'||hi as "Разброс, ₸", source as "Источник", note as "Примечание",
  case st when 'ok' then 1 when 'same' then 2 when 'big' then 3 when 'manual' then 3 else 4 end as ord
from s
union all
select p.name, p.unit, p.old_price, null, null, 'нет рыночной цены — не меняется', null, null, null, 5
from p where not exists (select 1 from s where s.id=p.id)
order by ord, 1;
