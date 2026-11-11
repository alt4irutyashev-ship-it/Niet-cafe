-- Niet Café: КБЖУ блюд считается АВТОМАТИЧЕСКИ по техкарте.
-- Выполнить ПОСЛЕ 22_nutrition.sql (и остальных). Можно запускать повторно.
--
-- Как теперь:
--   • если у всех продуктов техкарты известны КБЖУ и вес — калории, белки, жиры, углеводы и вес блюда
--     ВСЕГДА берутся из техкарты (нетто, сырые продукты). Пересчёт сам — при любой правке техкарты или продукта;
--   • ориентировочная «типовая порция» используется только для блюд БЕЗ техкарты или с неполной техкартой;
--   • если по техкарте цифры сильно отличаются от обычных для такого блюда — гостю всё равно показывается техкарта,
--     а руководитель видит спокойную подсказку «ℹ» (проверить количества), без замены цифр;
--   • если в техкарте есть продукт без КБЖУ или без веса 1 шт — подсказка называет этот продукт.
--   • вписали КБЖУ вручную — автопересчёт для блюда выключается; кнопка «Считать по техкарте» включает обратно.

-- граммы: добавлены единицы «бут», «уп», «пач» (вес 1 штуки берётся из g_unit продукта)
create or replace function nut_grams(qty numeric, unit text, g_unit numeric) returns numeric language sql immutable as $$
  select case lower(trim(coalesce(unit,'')))
    when 'кг' then qty*1000 when 'kg' then qty*1000 when 'л' then qty*1000 when 'l' then qty*1000
    when 'г' then qty when 'гр' then qty when 'g' then qty when 'мл' then qty when 'ml' then qty
    when 'шт' then qty*g_unit when 'шт.' then qty*g_unit when 'бут' then qty*g_unit when 'уп' then qty*g_unit when 'пач' then qty*g_unit
    else null end
$$;

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
    weight = case when v.use_tc then round(v.g) else v.sw end,
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

-- пересчитать всё меню сразу
select dish_nutrition_refresh() as "Блюд пересчитано",
       (select count(*) from dishes where nut_src='techcard') as "По техкарте",
       (select count(*) from dishes where nut_src='typical')  as "Ориентировочно",
       (select count(*) from dishes where nut_src='manual')   as "Вписано вручную";
