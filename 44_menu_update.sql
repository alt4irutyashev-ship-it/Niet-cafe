-- Niet Café 44: ОБНОВЛЕНИЕ МЕНЮ по новому плакату «Кафе • Гриль» (21.11.2026).
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять ПОСЛЕ 43_sets_promos.sql. Можно запускать повторно.
--
--   1) Новые категории: «Пивные закуски», «Пивные сеты», «Блюда на компанию».
--   2) Новые блюда — ⛔ В СТОПЕ и с ценой 0: гости их не видят, официант не может добавить в заказ.
--      Руководитель: Меню → фильтр «⛔ В стопе» → открыть блюдо → цена, техкарта, снять стоп → Сохранить.
--   3) Сеты (пивные и «на компанию») — тоже в стопе; состав заполнен по плакату там, где блюда уже есть в меню.
--   4) Блюда, которых нет на плакате, — в АРХИВ (вернуть: Меню → «🗄 Архив» → «↩ Вернуть в меню»).
--      Соусы, чай и напитки не трогаются: их на плакате и не должно быть.
--      Блюда, которые входят в пивные сеты (Мини-чебуреки, Хрустящие нагетсы, Сырные палочки), остаются в меню.
-- Внизу — таблица: что добавлено, что ушло в архив.

create temp table if not exists menu_upd_log(act text, name text, cat text);
truncate menu_upd_log;

-- категория по названию (создаётся, если нет); ref — блюдо, по которому узнать категорию, если её переименовали
create or replace function pg_temp.mcat(p_name text, p_ref text default null) returns int language plpgsql as $$
declare c int;
begin
  if p_ref is not null then select cat_id into c from dishes where lower(name) = lower(p_ref) order by archived, id limit 1; end if;
  if c is null then select id into c from cats where lower(name) = lower(p_name) order by id limit 1; end if;
  if c is null then
    select coalesce(max(id), 0) + 1 into c from cats;
    insert into cats(id, name) values (c, p_name);
    insert into menu_upd_log values ('Новая категория', p_name, '');
  end if;
  return c;
end $$;

-- новое блюдо: в стопе, цена 0 (если такое уже есть — не трогаем)
create or replace function pg_temp.mdish(p_name text, p_cat int, p_set boolean default false) returns int language plpgsql as $$
declare d int;
begin
  select id into d from dishes where lower(name) = lower(p_name) order by archived, id limit 1;
  if d is not null then return d; end if;
  select coalesce(max(id), 0) + 1 into d from dishes;
  insert into dishes(id, cat_id, name, price, station, stop) values (d, p_cat, p_name, 0, 'kitchen', true);
  if p_set then update dishes set is_set = true where id = d; end if;
  insert into menu_upd_log values (case when p_set then 'Новый сет (в стопе)' else 'Новое блюдо (в стопе)' end, p_name, (select name from cats where id = p_cat));
  return d;
end $$;

-- строка состава сета (только если такое блюдо есть и строки ещё нет)
create or replace function pg_temp.mset(p_set int, p_dish text, p_qty numeric default 1) returns void language plpgsql as $$
declare d int;
begin
  select id into d from dishes where lower(name) = lower(p_dish) and not is_set order by archived, id limit 1;
  if d is null or exists (select 1 from set_items where set_id = p_set and dish_id = d) then return; end if;
  insert into set_items(set_id, dish_id, qty, pos) values (p_set, d, p_qty, (select count(*) from set_items where set_id = p_set));
end $$;

do $menu$
declare
  c_beer int; c_bset int; c_comp int; c_sal int; c_soup int; c_pasta int; c_hot int; c_grill int; c_side int; c_bake int; c_sushi int;
  s int;
begin
  perform set_config('niet.nopush', '1', true);

  c_beer  := pg_temp.mcat('Пивные закуски');
  c_bset  := pg_temp.mcat('Пивные сеты');
  c_comp  := pg_temp.mcat('Блюда на компанию');
  c_sal   := pg_temp.mcat('Салаты', 'Цезарь с курицей');
  c_soup  := pg_temp.mcat('Супы', 'Солянка от шефа');
  c_pasta := pg_temp.mcat('Паста', 'Паста болоньезе');
  c_hot   := pg_temp.mcat('Горячие блюда', 'Куырдак из баранины');
  c_grill := pg_temp.mcat('Мангал', 'Баранина на углях');
  c_side  := pg_temp.mcat('Гарниры', 'Картошка фри');
  c_bake  := pg_temp.mcat('Выпечка', 'Пицца маргарита');
  c_sushi := pg_temp.mcat('Суши и роллы', 'Филадельфия');

  -- ===== новые блюда =====
  perform pg_temp.mdish('Пивные креветки', c_beer);
  perform pg_temp.mdish('Карась жареный', c_beer);
  perform pg_temp.mdish('Сазан жареный', c_beer);
  perform pg_temp.mdish('Гренки чесночные', c_beer);
  perform pg_temp.mdish('Ачучук', c_sal);
  perform pg_temp.mdish('Салат с авокадо и креветками', c_sal);
  perform pg_temp.mdish('Шурпа из баранины', c_soup);
  perform pg_temp.mdish('Крем-суп чечевичный', c_soup);
  perform pg_temp.mdish('Спагетти «Карбонара»', c_pasta);
  perform pg_temp.mdish('Плов ташкентский', c_hot);
  perform pg_temp.mdish('Суйру лагман', c_hot);
  perform pg_temp.mdish('Куриное филе с брокколи', c_hot);
  perform pg_temp.mdish('Колбасный микс', c_grill);
  perform pg_temp.mdish('Картофельное пюре', c_side);
  perform pg_temp.mdish('Брокколи на пару', c_side);
  perform pg_temp.mdish('Овощи на пару', c_side);
  perform pg_temp.mdish('Хачапури с сыром', c_bake);
  perform pg_temp.mdish('Аляска темпура', c_sushi);
  perform pg_temp.mdish('Запечённый суши', c_sushi);
  perform pg_temp.mdish('Запечённый ролл с лососем', c_sushi);

  -- ===== пивные сеты (луковые кольца и жареные пельмени добавьте в состав сами — продуктом или блюдом) =====
  s := pg_temp.mdish('Пивной сет №1', c_bset, true);
  perform pg_temp.mset(s, 'Мини-чебуреки'); perform pg_temp.mset(s, 'Гренки чесночные');
  perform pg_temp.mset(s, 'Сырные палочки'); perform pg_temp.mset(s, 'Картошка фри');
  s := pg_temp.mdish('Пивной сет №2', c_bset, true);
  perform pg_temp.mset(s, 'Крылышки барбекю'); perform pg_temp.mset(s, 'Картофель по-деревенски');
  perform pg_temp.mset(s, 'Хрустящие нагетсы'); perform pg_temp.mset(s, 'Сырные палочки');
  s := pg_temp.mdish('Пивной сет №3', c_bset, true);
  perform pg_temp.mset(s, 'Карась жареный'); perform pg_temp.mset(s, 'Пивные креветки');
  perform pg_temp.mset(s, 'Хрустящие нагетсы'); perform pg_temp.mset(s, 'Гренки чесночные');

  -- ===== блюда на компанию (4–6 персон) =====
  s := pg_temp.mdish('Ташкентский плов на компанию (4–6 персон)', c_comp, true);
  perform pg_temp.mset(s, 'Плов ташкентский', 5);
  s := pg_temp.mdish('Мясной сет (4–6 персон)', c_comp, true);
  perform pg_temp.mset(s, 'Антрекот на мангале'); perform pg_temp.mset(s, 'Баранина на углях');
  perform pg_temp.mset(s, 'Колбасный микс'); perform pg_temp.mset(s, 'Овощи на углях');
  s := pg_temp.mdish('Рыбный микс (4–6 персон)', c_comp, true);
  perform pg_temp.mset(s, 'Форель на мангале'); perform pg_temp.mset(s, 'Сибас на мангале');
  perform pg_temp.mset(s, 'Карась жареный'); perform pg_temp.mset(s, 'Сазан жареный');
  s := pg_temp.mdish('Ассорти из шашлыков (4–6 персон)', c_comp, true);
  perform pg_temp.mset(s, 'Баранина на углях'); perform pg_temp.mset(s, 'Антрекот на мангале');
  perform pg_temp.mset(s, 'Куриное филе на мангале'); perform pg_temp.mset(s, 'Крылышки на мангале');
  perform pg_temp.mset(s, 'Окорочка на мангале');

  -- ===== в архив: блюда, которых нет на плакате =====
  with a as (
    update dishes d set archived = true, archived_at = now()
     where not d.archived and not coalesce(d.is_set, false)
       and lower(d.name) in (
         'малибу','пекинский салат с фирменным соусом','салат с уткой в апельсиновом соусе','фирменный салат',
         'фирменные крылышки','тигровые креветки',
         'уха по-царски','харчо по-грузински','бозбаш по-кавказски',
         'паста с креветками',
         'фрикасе из курицы в сливочном соусе','куриная грудка в сливочном соусе',
         'бефстроганов из говядины','говядина по-тайски','казан-кебаб по-восточному','оджахури',
         'мимино (говядина под сыром)','гуйру цомян',
         'сёмга под икорным соусом','судак с овощами в кисло-сладком соусе',
         'рёбрышки на мангале',
         'хычины с сыром','хычины с зеленью','фирменная пицца',
         'дракон','роллы от шефа','америка темпура','унаги темпура','вулкан с лососем','вулкан с угрём','вулкан с крабом')
       and not exists (select 1 from set_items si where si.dish_id = d.id)
    returning d.name, d.cat_id)
  insert into menu_upd_log select 'В архив', a.name, c.name from a left join cats c on c.id = a.cat_id;
end $menu$;

select act as "Что сделано", name as "Блюдо", cat as "Категория" from menu_upd_log
union all
select 'Сет: состав', d.name, string_agg(coalesce(x.name, p.name) || ' × ' || rtrim(rtrim(round(s.qty,4)::text,'0'),'.'), ', ' order by s.pos)
  from dishes d join set_items s on s.set_id = d.id left join dishes x on x.id = s.dish_id left join products p on p.id = s.product_id
 where d.is_set group by d.name
order by 1, 2;
