-- Niet Café: ВЫХОД ПОРЦИИ и ВАРКА ПАРТИЕЙ (супы, гарниры, соусы).
-- Выполнить в Supabase -> SQL Editor ПОСЛЕ 28_nutrition_auto.sql. Можно запускать повторно.
--
-- Что добавляется:
--   • dishes.out_g   — выход 1 порции, г (сколько граммов готового блюда кладут на тарелку);
--   • dishes.batch_n — сколько порций выходит из одной партии (кастрюли). Только для удобного ввода:
--                      в базе техкарта по-прежнему хранится НА 1 ПОРЦИЮ, списание склада не меняется.
--   • если выход порции указан — он же показывается гостю как вес блюда (вместо суммы сырых продуктов).

alter table dishes add column if not exists out_g int;
alter table dishes add column if not exists batch_n numeric;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='dishes_out_g_chk') then
    alter table dishes add constraint dishes_out_g_chk check (out_g is null or out_g > 0);
  end if;
  if not exists(select 1 from pg_constraint where conname='dishes_batch_n_chk') then
    alter table dishes add constraint dishes_batch_n_chk check (batch_n is null or batch_n > 0);
  end if;
end $$;

-- выход порции сразу становится весом блюда (и при ручном КБЖУ тоже)
create or replace function dishes_out_g() returns trigger language plpgsql as $$
begin
  if new.out_g > 0 and (tg_op = 'INSERT' or new.out_g is distinct from old.out_g) then
    new.weight := new.out_g;
  end if;
  return new;
end $$;
drop trigger if exists dishes_out_g_t on dishes;
create trigger dishes_out_g_t before insert or update of out_g on dishes for each row execute function dishes_out_g();

-- автоматический КБЖУ: вес блюда = выход порции, если он указан
create or replace function dish_nutrition_refresh(p_dish int default null) returns int
language plpgsql security definer set search_path=public as $$
declare n int;
begin
  with tc as (
    select r.dish_id, count(*) cnt,
           count(*) filter (where p.kcal is not null and nut_grams(r.qty,p.unit,p.g_unit) is not null) ok,
           string_agg(p.name || case when p.kcal is null then ' (нет КБЖУ)' else ' (нет веса 1 '||p.unit||')' end, ', ' order by p.name)
             filter (where p.kcal is null or nut_grams(r.qty,p.unit,p.g_unit) is null) bad,
           sum(nut_grams(r.qty,p.unit,p.g_unit)) g,
           sum(nut_grams(r.qty,p.unit,p.g_unit)*p.kcal/100) k, sum(nut_grams(r.qty,p.unit,p.g_unit)*p.prot/100) pr,
           sum(nut_grams(r.qty,p.unit,p.g_unit)*p.fat/100) f, sum(nut_grams(r.qty,p.unit,p.g_unit)*p.carb/100) c,
           array_agg(p.allerg) a
    from recipes r join products p on p.id=r.product_id
    where p_dish is null or r.dish_id=p_dish group by r.dish_id),
  v as (
    select d.id, (t.cnt>=1 and t.cnt=t.ok) use_tc, t.*, s.weight sw, s.kcal sk, s.prot sp, s.fat sf, s.carb sc, s.allerg sa
    from dishes d left join tc t on t.dish_id=d.id left join dish_nut_ref s on s.name=lower(trim(d.name))
    where d.nut_auto and (p_dish is null or d.id=p_dish))
  update dishes d set
    weight = case when d.out_g > 0 then d.out_g when v.use_tc then round(v.g) else v.sw end,
    kcal   = case when v.use_tc then round(v.k) else v.sk end,
    prot   = case when v.use_tc then round(v.pr,1) else v.sp end,
    fat    = case when v.use_tc then round(v.f,1) else v.sf end,
    carb   = case when v.use_tc then round(v.c,1) else v.sc end,
    allerg = alg_union(coalesce(v.a,'{}'::text[]) || array[v.sa]),
    nut_src= case when v.use_tc then 'techcard' when v.sk is not null then 'typical' else null end,
    nut_note= case
      when v.use_tc and v.sk > 0 and v.k > 2*v.sk then
        'ℹ По техкарте '||round(v.k)||' ккал — для такого блюда обычно около '||v.sk||'. Если количества верны (заправка, масло, сыр) — всё в порядке; если нет — проверьте единицы (0.15 кг = 150 г)'
      when v.use_tc and v.sk > 0 and v.k < 0.5*v.sk then
        'ℹ По техкарте '||round(v.k)||' ккал — для такого блюда обычно около '||v.sk||'. Возможно, в техкарте внесены не все продукты'
      when v.cnt is not null and v.cnt<>v.ok then
        'Не хватает данных: '||v.bad||'. Пока показаны ориентировочные значения'
      end
  from v where v.id=d.id and (v.use_tc or v.sk is not null or v.a is not null or v.cnt is not null);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function dish_nutrition_refresh(int) from public, anon;
grant execute on function dish_nutrition_refresh(int) to authenticated;

select count(*) filter (where out_g > 0) as "Блюд с выходом порции",
       count(*) filter (where batch_n > 0) as "Блюд, которые варятся партией"
from dishes;
