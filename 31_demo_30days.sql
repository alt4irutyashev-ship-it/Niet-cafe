-- Niet Café 31: ДЕМО-ДАННЫЕ за 30 дней — чтобы проверить отчёты, анализ меню, склад и Excel до запуска.
-- Выполнить ПОСЛЕ файлов 1–30: Supabase -> SQL Editor -> New query -> вставить всё -> Run (займёт до минуты).
--
-- ПЕРЕД ЗАПУСКОМ закройте сайт на телефонах персонала (иначе кухня и официанты увидят поток заказов на экране).
-- Push-уведомления на время загрузки отключаются автоматически и включаются обратно.
--
-- Что создаётся (все заказы помечены note = 'DEMO'):
--   • ~1 300 закрытых заказов за 30 дней: зал, с собой, доставка; обед и ужин — пик, выходные — больше гостей;
--   • оплаты: наличные, карта, Kaspi, смешанная; обслуживание — ваш % из «Затрат», доставка — по вашим настройкам;
--   • приходы раз в 3 дня (цены немного меняются ±4% — видно в «Пред. цена»), списания, одна инвентаризация на 15-й день,
--     отмены блюд до и после кухни; склад списывается по вашим техкартам, как в настоящей работе.
-- Перед загрузкой сохраняются текущие цены и остатки продуктов и стоп-лист — файл 32 вернёт их как было.
-- УБРАТЬ ВСЁ перед запуском: файл 32_reset_before_launch.sql.

do $demo$
declare
  W uuid[]; pool int[]; dd int; dy date; n int; i int; j int; o int; ot timestamptz; tc timestamptz; tr timestamptz;
  kd text; tb int; cl int; did int; qn int; sub numeric; pct numeric; sv numeric; fee numeric; tot numeric; r numeric; pm text;
  v_fee numeric := coalesce((select val from settings where key='delivery_fee'),990);
  v_free numeric := coalesce((select val from settings where key='delivery_free'),5000);
  hrs int[] := '{10,11,12,12,13,13,13,14,14,15,16,17,18,18,19,19,19,20,20,20,21,21,22}';
  wor text[] := '{"Испорчено","Просрочено","Бой / брак","Питание персонала","Ошибка повара"}';
  cr1 text[] := '{"Гость передумал","Ошибка официанта","Нет продукта"}';
  cr2 text[] := '{"Не понравилось","Блюдо испорчено","Долго готовили"}';
  tk int := 0; dl int := 0; nt int; ndl int; rs text; z int; p record; x record; q numeric; np numeric; cur numeric; lid int; sh numeric; ln text[];
  today date := (now() at time zone 'UTC' + interval '5 hours')::date;     -- местная дата (Астана, UTC+5)
begin
  if exists(select 1 from orders where note='DEMO') then
    raise exception 'Демо-данные уже загружены. Чтобы загрузить заново — сначала выполните 32_reset_before_launch.sql';
  end if;
  if not exists(select 1 from recipes) then raise exception 'Нет ни одной техкарты — демо не сможет списывать склад. Сначала заполните техкарты'; end if;
  perform setseed(0.2026);

  -- 1. резервная копия: цены, остатки, стоп-лист (файл 32 вернёт)
  create table if not exists demo_backup_products(id int primary key, price numeric, s_kitchen numeric, s_bar numeric);
  insert into demo_backup_products select id, price, s_kitchen, s_bar from products on conflict (id) do nothing;
  create table if not exists demo_backup_dishes(id int primary key, stop boolean, stop_auto boolean);
  insert into demo_backup_dishes select id, coalesce(stop,false), coalesce(stop_auto,false) from dishes on conflict (id) do nothing;

  -- 2. push-уведомления выключаем на время загрузки
  perform set_config('niet.nopush','1',true);   -- никаких push-уведомлений, пока создаются демо-данные (файл 33)
  begin execute 'alter table order_items disable trigger push_ins_t'; exception when others then null; end;
  begin execute 'alter table order_items disable trigger push_upd_t'; exception when others then null; end;
  begin execute 'alter table order_items disable trigger push_del_t'; exception when others then null; end;

  W := array(select id from profiles where role='waiter');
  if coalesce(cardinality(W),0)=0 then W := array(select id from profiles where role='boss'); end if;
  if coalesce(cardinality(W),0)=0 then W := array[null::uuid]; end if;

  -- популярность блюд: у каждого блюда свой «вес» 1–7 (одни продаются часто, другие редко)
  pool := array(select d.id from dishes d, generate_series(1, 1 + abs(hashtext(d.name)) % 7) g
                 where not coalesce(d.archived,false) and coalesce(d.price,0) > 0 and not coalesce(d.stop,false));
  if coalesce(cardinality(pool),0)=0 then raise exception 'В меню нет блюд для заказов'; end if;

  -- примерный расход продуктов в день (≈190 порций/день, с запасом) — чтобы приходы были похожи на настоящие
  create temp table demo_need on commit drop as
    select r.product_id, sum(w.share * 190 * r.qty / (1 - least(coalesce(pd.loss_pct,0),99)/100)) daily
      from recipes r join products pd on pd.id = r.product_id
      join (select id, (1 + abs(hashtext(name)) % 7)::numeric / sum(1 + abs(hashtext(name)) % 7) over () share
              from dishes where not coalesce(archived,false) and coalesce(price,0) > 0 and not coalesce(stop,false)) w on w.id = r.dish_id
     group by r.product_id;

  for dd in reverse 30..0 loop
    dy := today - dd;

    -- ПРИХОДЫ: в первый день — на 6 дней, потом раз в 3 дня — до запаса на 5 дней
    if dd = 30 or dd % 3 = 0 then
      tr := (dy::timestamp + time '09:30') at time zone 'UTC' - interval '5 hours';
      if tr <= clock_timestamp() then
        for p in select pr.*, nd.daily from products pr join demo_need nd on nd.product_id = pr.id loop
          cur := case when p.station='bar' then coalesce(p.s_bar,0) else coalesce(p.s_kitchen,0) end;
          q := p.daily * case when dd = 30 then 6 else 5 end - cur;
          if q <= 0 then continue; end if;
          q := case when p.unit in ('шт','бут','уп','пач') then ceil(q) else ceil(q*2)/2 end;          -- шт — целые, кг/л — по 0,5
          np := case when dd = 30 then p.price
                     else greatest(1, case when p.price >= 1000 then round(p.price*(1+(random()-0.45)*0.08)/10)*10
                                           else round(p.price*(1+(random()-0.45)*0.08)) end) end;
          update products set price = np,
                 s_kitchen = case when p.station='bar' then s_kitchen else s_kitchen + q end,
                 s_bar     = case when p.station='bar' then s_bar + q else s_bar end
           where id = p.id;
          update price_history ph set t = tr where ph.kind='product' and ph.item_id = p.id and ph.t > tr and ph.id = (select max(id) from price_history where kind='product' and item_id = p.id);
          insert into receipts(product_id,qty,price,sum,balance_after,note,loc,t)
          values(p.id, q, np, np*q, cur+q, 'DEMO', case when p.station='bar' then 'bar' else 'kitchen' end, tr);
          insert into movements(kind,info,t) values('Приход', p.name||': +'||q||' '||p.unit||' × '||np||' → '||case when p.station='bar' then 'бар' else 'кухня' end, tr);
        end loop;
      end if;
    end if;

    -- ИНВЕНТАРИЗАЦИЯ на 15-й день: небольшая недостача по 8 продуктам
    if dd = 15 then
      tr := (dy::timestamp + time '09:00') at time zone 'UTC' - interval '5 hours'; sh := 0; ln := '{}';
      for p in select pr.* from products pr join demo_need nd on nd.product_id = pr.id
                where (case when pr.station='bar' then pr.s_bar else pr.s_kitchen end) > 0 order by random() limit 8 loop
        cur := case when p.station='bar' then p.s_bar else p.s_kitchen end;
        q := case when p.unit in ('шт','бут','уп','пач') then floor(cur * (0.95 + random()*0.04)::numeric) else round(cur * (0.95 + random()*0.04)::numeric, 3) end;
        if q >= cur then continue; end if;
        update products set s_kitchen = case when p.station='bar' then s_kitchen else q end, s_bar = case when p.station='bar' then q else s_bar end where id = p.id;
        sh := sh + (cur-q)*p.price; ln := ln || (p.name||': '||round(q-cur,3)||' '||p.unit);
        insert into movements(kind,info,product_id,qty,amount,reason,loc,t)
        values('Недостача', p.name||': '||round(q-cur,3)||' '||p.unit||' ('||case when p.station='bar' then 'бар' else 'кухня' end||')', p.id, q-cur, round((cur-q)*p.price), 'инвентаризация', case when p.station='bar' then 'bar' else 'kitchen' end, tr);
      end loop;
      insert into movements(kind,info,amount,reason,t) values('Инвентаризация', 'кухня и бар: '||array_to_string(ln,'; ')||'. Недостача '||round(sh)||' ₸, излишки 0 ₸', round(sh), 'инвентаризация', tr);
    end if;

    -- ЗАКАЗЫ ДНЯ
    n := 20 + floor(random()*10)::int + case when extract(isodow from dy) in (5,6,7) then 10 else 0 end + (30-dd)/6;
    nt := 4 + floor(random()*4)::int;  ndl := 3 + floor(random()*4)::int;     -- с собой и доставка
    for i in 1 .. n + nt + ndl loop
      kd := case when i <= n then 'dine' when i <= n + nt then 'take' else 'delivery' end;
      ot := (dy::timestamp + make_interval(hours => hrs[1 + floor(random()*cardinality(hrs))::int], mins => floor(random()*60)::int))
           at time zone 'UTC' - interval '5 hours';
      if ot > clock_timestamp() - interval '40 minutes' then continue; end if;
      if kd = 'take' then tk := tk % 98 + 1; tb := 100 + tk;
      elsif kd = 'delivery' then dl := dl % 98 + 1; tb := 200 + dl;
      else tb := 1 + floor(random()*9)::int; end if;
      cl := 1 + floor(60 * power(random(), 2.2))::int;      -- 60 демо-клиентов: несколько постоянных, много разовых
      insert into orders(tbl,kind,waiter,note,phone,address,cname)
      values(tb, kd, W[1 + floor(random()*cardinality(W))::int], 'DEMO',
             case when kd<>'dine' then '+7 700 000 '||lpad((cl/100)::text,2,'0')||' '||lpad((cl%100)::text,2,'0') end,
             case when kd='delivery' then 'Демо-адрес, д. '||cl end,
             case when kd<>'dine' then (array['Айгерим','Данияр','Асель','Нурлан','Мадина','Ерлан','Дана','Арман','Алия','Тимур','Жанар','Санжар'])[1 + cl % 12]||' (демо '||cl||')' end)
      returning id into o;
      for j in 1 .. case kd when 'dine' then 2 + floor(random()*4)::int when 'take' then 1 + floor(random()*3)::int else 2 + floor(random()*3)::int end loop
        for z in 1..8 loop                                   -- блюдо из стоп-листа официант не продаст
          did := pool[1 + floor(random()*cardinality(pool))::int];
          exit when not (select coalesce(stop,false) from dishes where id = did);
        end loop;
        if (select coalesce(stop,false) from dishes where id = did) then continue; end if;
        qn := case when random() < 0.82 then 1 else 2 end;
        insert into order_items(order_id,dish_id,qty,station) values(o, did, qn, (select station from dishes where id = did));
      end loop;
      if not exists(select 1 from order_items where order_id=o) then delete from orders where id=o; continue; end if;
      -- отмена до кухни (≈2,5%)
      if random() < 0.025 and (select count(*) from order_items where order_id=o) > 1 then
        delete from order_items where id = (select max(id) from order_items where order_id=o);
        update order_log set reason = cr1[1 + floor(random()*3)::int] where id = (select max(id) from order_log where order_id=o);
      end if;
      update order_items set status='accepted' where order_id=o;
      update order_items set status='ready' where order_id=o;          -- склад списывается по техкартам здесь
      -- отмена после кухни (≈1%): продукты уже списаны — это потеря
      if random() < 0.01 and (select count(*) from order_items where order_id=o) > 1 then
        select id, price, dish_id into x from order_items where order_id=o order by id desc limit 1;
        delete from order_items where id = x.id;
        update order_log set reason = cr2[1 + floor(random()*3)::int], price = x.price,
               cost = (select cost from item_costs where item_id = x.id)
         where id = (select max(id) from order_log where order_id=o);
      end if;
      update order_items set status='served' where order_id=o;
      -- закрытие: так же, как считает официант (цена на момент заказа, % обслуживания заказа, доставка по настройкам)
      select coalesce(sum(qty*price),0) into sub from order_items where order_id=o;
      select service_pct into pct from orders where id=o;
      sv  := case when kd='dine' then round(sub*coalesce(pct,0)/100) else 0 end;
      fee := case when kd='delivery' and sub > 0 and sub < v_free then v_fee else 0 end;
      tot := sub + sv + fee; r := random();
      pm := case when r < 0.30 then 'cash' when r < 0.62 then 'card' when r < 0.95 then 'kaspi' else 'mix' end;
      update orders set status='closed', pay=pm, service=sv, delivery_fee=fee, total=tot,
             p_cash = case pm when 'cash' then tot when 'mix' then round(tot*0.4) else 0 end,
             p_card = case pm when 'card' then tot when 'mix' then tot - round(tot*0.4) else 0 end,
             p_kaspi= case pm when 'kaspi' then tot else 0 end
       where id=o;
      -- даты «в прошлом»
      tc := ot + make_interval(mins => 25 + floor(random()*50)::int);
      update orders set created=ot, closed=tc, out_at = case when kd='delivery' then ot + interval '25 minutes' end where id=o;
      update order_items set created=ot, accepted_at=ot + interval '2 minutes', ready_at=ot + make_interval(mins => 8 + floor(random()*20)::int),
             served_at=ot + make_interval(mins => 12 + floor(random()*20)::int) where order_id=o;
      update order_log set t = ot + interval '5 minutes' where order_id=o;
    end loop;

    -- СПИСАНИЯ (примерно через день, вечером)
    tr := (dy::timestamp + time '23:00') at time zone 'UTC' - interval '5 hours';
    if random() < 0.5 and tr <= clock_timestamp() then
      for p in select pr.*, nd.daily from products pr join demo_need nd on nd.product_id = pr.id
                where (case when pr.station='bar' then pr.s_bar else pr.s_kitchen end) > 0 order by random() limit 1 + floor(random()*2)::int loop
        rs := wor[1 + floor(random()*5)::int];
        q := case when p.unit in ('шт','бут','уп','пач') then greatest(1, round(p.daily*0.2)) else greatest(0.1, round((p.daily*(0.05+random()*0.2))::numeric, 2)) end;
        update products set s_kitchen = case when p.station='bar' then s_kitchen else s_kitchen - q end, s_bar = case when p.station='bar' then s_bar - q else s_bar end where id = p.id;
        insert into movements(kind,info,product_id,qty,amount,reason,loc,t)
        values('Списание', p.name||': '||q||' '||p.unit||' ('||case when p.station='bar' then 'бар' else 'кухня' end||') — '||rs||', '||round(q*p.price)||' ₸',
               p.id, q, round(q*p.price), rs, case when p.station='bar' then 'bar' else 'kitchen' end, tr);
      end loop;
    end if;
  end loop;

  -- 3. push-уведомления обратно
  begin execute 'alter table order_items enable trigger push_ins_t'; exception when others then null; end;
  begin execute 'alter table order_items enable trigger push_upd_t'; exception when others then null; end;
  begin execute 'alter table order_items enable trigger push_del_t'; exception when others then null; end;
end $demo$;

-- итог
select (select count(*) from orders where note='DEMO') as "Заказов",
       (select count(*) from order_items i join orders o on o.id=i.order_id where o.note='DEMO') as "Позиций",
       (select round(sum(total)) from orders where note='DEMO') as "Выручка всего, ₸",
       (select count(*) from receipts where note='DEMO') as "Приходов",
       (select count(*) from movements where kind='Списание') as "Списаний",
       (select count(*) from order_log) as "Отмен",
       (select count(*) from dishes where stop and stop_auto) as "Блюд в автостопе";
