-- Niet Café 54: ЦЕНЫ ОТ ВЛАДЕЛЬЦА И ПО НАКЛАДНОЙ ИП Рустам (28.11.2026).
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять после 53_satu_prices.sql. Можно запускать повторно.
--   • Ставит цены этим продуктам поверх любых прежних (в т. ч. с satu.kz). Повторный запуск 52 и 53 их не сбросит.
--   • Первый приход с ценой заменит цену на фактическую (средневзвешенно).

create temp table if not exists satu53(name text primary key, unit text, price numeric, src text);
truncate satu53;

insert into satu53 values
('Сазан (целый)','кг',1800,'Цена владельца, 28.11.2026'),
('Карась (целый)','кг',1000,'Цена владельца, 28.11.2026'),
('Баранина','кг',4500,'Цена владельца, 28.11.2026'),
('Пельмени (полуфабрикат)','кг',4400,'Цена владельца, 28.11.2026 (в счёте ИП Рустам от 11.09 — 3 930 ₸/кг)'),
('Тесто для лагмана','кг',1500,'Цена владельца, 28.11.2026'),
('Стейк рибай','кг',10764,'Счёт ИП Рустам от 11.09.2026: ГОВ РИБАЙ СТЕЙК — 10 764 ₸/кг'),
('Стейк стриплойн','кг',8487,'Счёт ИП Рустам от 11.09.2026: ГОВ АНТРИКОТ (тонкий край) — 8 487 ₸/кг'),
('Стейк Т-бон','кг',7245,'Счёт ИП Рустам от 11.09.2026: ГОВ ТИБОН — 7 245 ₸/кг'),
('Чебуреки мини (полуфабрикат)','кг',4139,'Счёт ИП Рустам от 11.09.2026: ЧЕБУРЕЧКИ Men''s 0,9 кг — 3 725 ₸ (4 139 ₸/кг)');

do $p53$
begin
  perform set_config('niet.nopush','1',true);
  drop table if exists r53;
  create temp table r53(id int, st text, name text, unit text, old_price numeric, new_price numeric, src text);

  insert into r53
  select p.id, case when lower(trim(p.unit)) <> lower(v.unit) then 'skip_unit'
              when round(coalesce(p.price,0),2) = v.price then 'same'
              else 'ok' end,
         p.name, p.unit, p.price, v.price, v.src
    from satu53 v
    join products p on lower(p.name) = lower(v.name) and not coalesce(p.archived,false)
    left join price_source ps on ps.product_id = p.id;

  update products p set price = r.new_price from r53 r where p.id = r.id and r.st = 'ok';

  insert into price_source(product_id, price, doc_date, src, ref_key, set_at)
  select r.id, r.new_price, current_date, r.src, 'owner54', now()
    from r53 r
   where r.st in ('ok','same')
  on conflict (product_id) do update set price = excluded.price, doc_date = excluded.doc_date, src = excluded.src, ref_key = excluded.ref_key, set_at = now();
end $p53$;

notify pgrst, 'reload schema';

-- ================= ИТОГ =================
select "Результат", "Продукт", "Ед.", "Было, ₸", "Стало, ₸", "Источник" from (
  select case st when 'ok' then 1 when 'same' then 2 else 3 end ord,
         case st when 'ok' then '✅ цена обновлена' when 'same' then '✅ уже такая'
                 when 'skip_inv' then '⏭ не тронуто: есть цена из накладной' else '⚠ не тронуто: другая единица у вас' end "Результат",
         name "Продукт", unit "Ед.", trim_scale(old_price) "Было, ₸", trim_scale(new_price) "Стало, ₸", src "Источник"
    from r53
) t
order by ord, "Продукт";
