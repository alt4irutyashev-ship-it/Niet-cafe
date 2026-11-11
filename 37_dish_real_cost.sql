-- Niet Café 37: БЛЮДА С ФАКТИЧЕСКОЙ СЕБЕСТОИМОСТЬЮ (после 36_invoice_prices.sql).
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Ничего не меняет — только показывает.
--
-- «✅ Полностью по накладным» — ВСЕ продукты техкарты имеют цену из накладной/чека: себестоимость фактическая.
-- «◐ Частично» — часть продуктов по накладным, остальные по старой (рыночной/ручной) цене; видно, каких не хватает.
-- «— Без техкарты» — себестоимость не посчитать, пока не заполнена техкарта.
-- Себестоимость = Σ (количество в техкарте ÷ (1 − потеря %) × цена продукта). Фудкост = себестоимость ÷ цена в меню.

with r as (
  select r.dish_id, p.id pid, p.name pname, p.unit, r.qty,
         r.qty / (1 - least(coalesce(p.loss_pct,0),99)/100) * coalesce(p.price,0) cost,
         ps.product_id is not null ok
    from recipes r join products p on p.id = r.product_id
    left join price_source ps on ps.product_id = p.id
), d as (
  select d.id, d.name, d.price, c.name cat,
         count(r.pid) n, count(r.pid) filter (where r.ok) n_ok,
         round(coalesce(sum(r.cost),0)) cost,
         round(coalesce(sum(r.cost) filter (where r.ok),0)) cost_ok,
         string_agg(r.pname, ', ' order by r.cost desc) filter (where not r.ok) missing
    from dishes d left join r on r.dish_id = d.id left join cats c on c.id = d.cat_id
   where not coalesce(d.archived,false)
   group by d.id, d.name, d.price, c.name
)
select case when n = 0 then '— Без техкарты' when n_ok = n then '✅ Полностью по накладным' else '◐ Частично ('||n_ok||' из '||n||')' end as "Статус",
       name as "Блюдо", cat as "Категория", price as "Цена в меню, ₸",
       case when n > 0 then cost end as "Себестоимость, ₸",
       case when n > 0 and price > 0 then round(cost / price * 100) end as "Фудкост, %",
       case when n > 0 and price > 0 then price - cost end as "Наценка, ₸",
       case when n > 0 and cost > 0 then round(cost_ok / cost * 100) end as "Подтверждено, % себест.",
       missing as "Нет в накладных (цена прежняя)"
  from d
 order by case when n = 0 then 3 when n_ok = n then 1 else 2 end,
          case when n_ok = n then -(case when price > 0 then cost/price else 0 end) else -(case when cost>0 then cost_ok/cost else 0 end) end,
          name;
