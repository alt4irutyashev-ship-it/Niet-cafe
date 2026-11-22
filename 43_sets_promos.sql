-- Niet Café 43: СЕТЫ / КОМБО и АКЦИИ «N+1 в подарок».
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять ПОСЛЕ 42_portion_yield.sql. Можно запускать повторно.
--
-- СЕТЫ И КОМБО
--   • Сет — обычное блюдо с галочкой is_set. Его состав — другие блюда (Сырные палочки × 1, Картошка фри × 1 …)
--     и/или отдельные продукты (Луковые кольца 0,15 кг).
--   • Техкарта сета собирается АВТОМАТИЧЕСКИ из техкарт входящих блюд и пересчитывается сама,
--     когда меняется техкарта любого входящего блюда. Поэтому себестоимость, фудкост, КБЖУ и списание
--     со склада работают для сетов так же, как для обычных блюд (продукты бара списываются с бара).
--   • Сет внутри сета не допускается.
--
-- АКЦИИ «N+1»
--   • «Купи N — получи M в подарок»: на конкретные блюда и/или целые категории, по дням недели, часам и датам.
--   • Срабатывает сама, когда позиция попадает в заказ (официант, гость через QR, вынос, доставка):
--     каждая (N+M)-я порция становится бесплатной. В заказе и на пречеке она отмечена 🎁.
--   • Убрали из заказа оплаченную порцию — лишний подарок снимается автоматически.
--   • Цену подарка нельзя «подделать» с телефона: всё считает база.

-- ======================= СЕТЫ =======================
alter table dishes add column if not exists is_set boolean not null default false;

create table if not exists set_items(
  id bigint generated always as identity primary key,
  set_id int not null references dishes(id) on delete cascade,
  dish_id int references dishes(id) on delete cascade,
  product_id int references products(id) on delete cascade,
  qty numeric not null check (qty > 0),
  pos int not null default 0,
  constraint set_items_one check ((dish_id is null) <> (product_id is null)),
  constraint set_items_self check (dish_id is distinct from set_id)
);
create index if not exists set_items_set_i on set_items(set_id);
create index if not exists set_items_dish_i on set_items(dish_id);
alter table set_items enable row level security;
drop policy if exists set_items_r on set_items;
create policy set_items_r on set_items for select using (my_role() <> 'none');
drop policy if exists set_items_boss on set_items;
create policy set_items_boss on set_items for all using (my_role() = 'boss') with check (my_role() = 'boss');

-- собрать техкарту сета из состава
create or replace function set_rebuild(p_set int) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from dishes where id = p_set and is_set) then return; end if;
  perform set_config('niet.setrb', '1', true);
  delete from recipes where dish_id = p_set;
  insert into recipes(dish_id, product_id, qty)
  select p_set, x.product_id, round(sum(x.q), 6)
    from (select r.product_id, r.qty * s.qty q
            from set_items s join recipes r on r.dish_id = s.dish_id
           where s.set_id = p_set and s.dish_id is not null
          union all
          select s.product_id, s.qty from set_items s where s.set_id = p_set and s.product_id is not null) x
   group by x.product_id
  having sum(x.q) > 0;
  perform set_config('niet.setrb', '', true);
end $$;
revoke execute on function set_rebuild(int) from public, anon;
grant execute on function set_rebuild(int) to authenticated;

-- проверка состава: только в сет, без вложенных сетов
create or replace function set_items_check() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from dishes where id = new.set_id and is_set) then
    raise exception 'Блюдо № % не отмечено как сет', new.set_id;
  end if;
  if new.dish_id is not null and exists (select 1 from dishes where id = new.dish_id and is_set) then
    raise exception 'Сет нельзя положить внутрь другого сета';
  end if;
  return new;
end $$;
drop trigger if exists set_items_check_t on set_items;
create trigger set_items_check_t before insert or update on set_items for each row execute function set_items_check();

create or replace function set_items_sync() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if tg_op in ('UPDATE','DELETE') then perform set_rebuild(old.set_id); end if;
  if tg_op in ('INSERT','UPDATE') and (tg_op = 'INSERT' or new.set_id <> old.set_id) then perform set_rebuild(new.set_id); end if;
  return null;
end $$;
drop trigger if exists set_items_sync_t on set_items;
create trigger set_items_sync_t after insert or update or delete on set_items for each row execute function set_items_sync();

-- поменяли техкарту блюда — пересчитать все сеты, где оно есть
create or replace function recipes_set_sync() returns trigger
language plpgsql security definer set search_path=public as $$
declare s int; d1 int; d2 int;
begin
  if coalesce(current_setting('niet.setrb', true), '') = '1' then return null; end if;
  if tg_op in ('INSERT','UPDATE') then d1 := new.dish_id; end if;
  if tg_op in ('UPDATE','DELETE') then d2 := old.dish_id; end if;
  for s in select distinct set_id from set_items where dish_id in (d1, d2) loop
    perform set_rebuild(s);
  end loop;
  return null;
end $$;
drop trigger if exists recipes_set_sync_t on recipes;
create trigger recipes_set_sync_t after insert or update or delete on recipes for each row execute function recipes_set_sync();

-- галочку «сет» поставили — собрать техкарту; блюдо стало сетом — его нельзя оставить в составе других сетов
create or replace function dishes_set_flag() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.is_set and not coalesce(old.is_set, false) then
    if exists (select 1 from set_items where dish_id = new.id) then
      raise exception '«%» входит в состав другого сета — сначала уберите его оттуда', new.name;
    end if;
    perform set_rebuild(new.id);
  elsif not new.is_set and coalesce(old.is_set, false) then
    delete from set_items where set_id = new.id;   -- техкарта остаётся как была, её можно править вручную
  end if;
  return null;
end $$;
drop trigger if exists dishes_set_flag_t on dishes;
create trigger dishes_set_flag_t after update of is_set on dishes for each row execute function dishes_set_flag();

-- ======================= АКЦИИ =======================
create table if not exists promos(
  id serial primary key,
  name text not null,
  kind text not null default 'nplus' check (kind in ('nplus')),
  buy_n int not null default 2 check (buy_n >= 1),      -- сколько купить
  free_m int not null default 1 check (free_m >= 1),    -- сколько в подарок
  dish_ids int[] not null default '{}',                  -- на какие блюда
  cat_ids int[] not null default '{}',                   -- или на целые категории
  days int[] not null default '{}',                      -- 1 = пн … 7 = вс; пусто = каждый день
  t_from time, t_to time,                                -- часы (можно через полночь: 22:00–02:00)
  d_from date, d_to date,                                -- период
  active boolean not null default true,
  created timestamptz not null default now()
);
alter table promos enable row level security;
drop policy if exists promos_r on promos;
create policy promos_r on promos for select using (my_role() <> 'none');
drop policy if exists promos_boss on promos;
create policy promos_boss on promos for all using (my_role() = 'boss') with check (my_role() = 'boss');

alter table order_items add column if not exists promo_id int;
alter table order_items add column if not exists promo_free int not null default 0;   -- сколько порций в строке бесплатно
alter table order_items add column if not exists price_full numeric;                  -- цена из меню (до подарка)

-- действует ли акция сейчас (время кафе = UTC+5)
create or replace function promo_live(p promos) returns boolean
language plpgsql stable set search_path=public as $$
declare l timestamp := (now() at time zone 'UTC') + interval '5 hours';
begin
  if not p.active then return false; end if;
  if p.d_from is not null and l::date < p.d_from then return false; end if;
  if p.d_to is not null and l::date > p.d_to then return false; end if;
  if cardinality(p.days) > 0 and not (extract(isodow from l)::int = any(p.days)) then return false; end if;
  if p.t_from is not null and p.t_to is not null then
    if p.t_from <= p.t_to then
      if not (l::time >= p.t_from and l::time < p.t_to) then return false; end if;
    else
      if not (l::time >= p.t_from or l::time < p.t_to) then return false; end if;
    end if;
  end if;
  return true;
end $$;

-- позиция попадает в заказ: решить, есть ли в ней подарок.
-- Имя триггера начинается на «zp», чтобы он срабатывал ПОСЛЕ триггеров, ставящих цену из меню.
create or replace function promo_on_ins() returns trigger
language plpgsql security definer set search_path=public as $$
declare pr promos; c int; u numeric; g numeric; allowed numeric; need int;
begin
  new.promo_id := null; new.promo_free := 0; new.price_full := new.price;
  if coalesce(new.price, 0) <= 0 or coalesce(new.qty, 0) < 1 then return new; end if;
  select cat_id into c from dishes where id = new.dish_id;
  for pr in select * from promos where active order by id loop
    continue when not promo_live(pr);
    continue when not (new.dish_id = any(pr.dish_ids) or c = any(pr.cat_ids));
    select coalesce(sum(i.qty), 0), coalesce(sum(i.promo_free) filter (where i.promo_id = pr.id), 0) into u, g
      from order_items i join dishes d on d.id = i.dish_id
     where i.order_id = new.order_id and (i.dish_id = any(pr.dish_ids) or d.cat_id = any(pr.cat_ids));
    allowed := floor((u + new.qty) / (pr.buy_n + pr.free_m)) * pr.free_m;
    need := least(new.qty, (allowed - g)::int);
    if need > 0 then
      new.promo_id := pr.id;
      new.promo_free := need;
      new.price := round(new.price_full * (new.qty - need) / new.qty, 4);
      exit;
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists zp_promo_t on order_items;
create trigger zp_promo_t before insert on order_items for each row execute function promo_on_ins();

-- позицию убрали из заказа: снять лишние подарки
create or replace function promo_on_del() returns trigger
language plpgsql security definer set search_path=public as $$
declare pr promos; u numeric; g numeric; ex numeric; k numeric; r record;
begin
  if not exists (select 1 from orders where id = old.order_id and status = 'open') then return null; end if;
  for pr in select * from promos where id in (select distinct promo_id from order_items where order_id = old.order_id and promo_id is not null) loop
    select coalesce(sum(i.qty), 0), coalesce(sum(i.promo_free) filter (where i.promo_id = pr.id), 0) into u, g
      from order_items i join dishes d on d.id = i.dish_id
     where i.order_id = old.order_id and (i.dish_id = any(pr.dish_ids) or d.cat_id = any(pr.cat_ids));
    ex := g - floor(u / (pr.buy_n + pr.free_m)) * pr.free_m;
    continue when ex <= 0;
    perform set_config('niet.nopush', '1', true);
    for r in select * from order_items where order_id = old.order_id and promo_id = pr.id order by id desc loop
      exit when ex <= 0;
      k := least(ex, r.promo_free);
      update order_items
         set promo_free = r.promo_free - k,
             promo_id = case when r.promo_free - k > 0 then pr.id end,
             price = round(coalesce(r.price_full, r.price) * (r.qty - (r.promo_free - k)) / r.qty, 4)
       where id = r.id;
      ex := ex - k;
    end loop;
    perform set_config('niet.nopush', '', true);
  end loop;
  return null;
end $$;
drop trigger if exists zp_promo_del_t on order_items;
create trigger zp_promo_del_t after delete on order_items for each row execute function promo_on_del();

revoke execute on function promo_on_ins() from public, anon;
revoke execute on function promo_on_del() from public, anon;
revoke execute on function set_items_check() from public, anon;
revoke execute on function set_items_sync() from public, anon;
revoke execute on function recipes_set_sync() from public, anon;
revoke execute on function dishes_set_flag() from public, anon;

notify pgrst, 'reload schema';

select (select count(*) from dishes where is_set) as "Сетов", (select count(*) from set_items) as "Строк состава сетов",
       (select count(*) from promos where active) as "Активных акций";
