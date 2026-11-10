-- Niet Café: рыночные цены на продукты (Астана, ноябрь 2026).
-- Источники: мониторинг супермаркетов Астаны (Inbusiness.kz, 06.11.2026), Бюро нацстатистики,
-- оптовые поставщики HoReCa на Satu.kz (Good Food Group, Berry Company, EURO FOOD KZ и др.).
--
-- ШАГ 2 из 2. Сначала выполните 17_market_prices.sql и посмотрите таблицу.
-- Этот файл меняет цены ТОЛЬКО у строк со статусом «обновится».
-- Старые цены не теряются: их сохраняет история цен (видна в карточке продукта у руководителя).

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
  from m),
upd as (
  update products pr set price = s.new_price
  from s where s.id = pr.id and s.st = 'ok'
  returning pr.id)
select s.name as "Продукт", s.unit as "Ед.", s.old_price as "Было, ₸", s.new_price as "Стало, ₸",
  case when s.old_price>0 then round((s.new_price-s.old_price)/s.old_price*100) end as "Разница, %"
from s join upd on upd.id = s.id
order by 1;
