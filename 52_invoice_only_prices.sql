-- Niet Café 52: ЦЕНЫ ТОЛЬКО ИЗ НАКЛАДНЫХ. Где цены из накладной нет — цена 0.
-- Supabase -> SQL Editor -> вставить всё -> Run. Выполнять после 50_beer_cleanup_costs.sql. Можно запускать повторно.
--
--   • Продукт найден в накладной/чеке (справочник накладных) и единица совпадает → цена из накладной.
--     Кг и л для соусов, масел, сметаны и т. п. считаются одинаково.
--   • Нет в накладных, в накладной другая единица (пучок, пачка, банка, шт — а у вас кг/л) или в накладной
--     на самом деле другой товар → цена 0. Такой продукт получит цену при первом приходе с ценой.
--   • Продукты, которых нет ни в одной техкарте, без остатка и не закупавшиеся за 30 дней, — в архив.
-- ⚠ Пока у продукта цена 0, себестоимость блюд с ним в отчётах занижена. Список таких продуктов — в таблице внизу.

do $chk$ begin
  if to_regclass('public.invoice_ref') is null then raise exception 'Сначала выполните 36_invoice_prices.sql'; end if;
end $chk$;

create temp table if not exists r52(ord int, act text, name text, unit text, old_price numeric, new_price numeric, src text);
truncate r52;

do $p52$
declare
  -- в накладной под этим правилом другой товар — цену из неё не берём
  wrong text[] := array['Приправа Санта Мария','Лазы (острая приправа)','Приправа куриная (Магги)','Приправа для рамен (упаковка)',
                        'Морковь красная','Нават (кристаллический сахар)','Сироп сахарный (1:1)','Креветки очищенные'];
  -- кг ↔ л: для жидких и пастообразных продуктов считаем 1 кг = 1 л
  liq text := 'соус|масл|сметан|майонез|кетчуп|сироп|сок|паст|уксус|мед|мёд|сливк|молок|кефир|йогурт|горчиц';
  r record; np numeric; u text; ru text;
begin
  perform set_config('niet.nopush','1',true);
  begin execute 'alter table products disable trigger products_autostop_t'; exception when others then null; end;

  for r in
    with p as (
      select p.*, translate(lower(p.name),'ё','е') n,
        case lower(trim(coalesce(p.unit,''))) when 'кг.' then 'кг' when 'kg' then 'кг' when 'л.' then 'л' when 'l' then 'л'
          when 'шт.' then 'шт' when 'бут' then 'шт' when 'уп' then 'шт' when 'пач' then 'шт' when 'пучок' then 'шт'
          when 'гр' then 'г' when 'гр.' then 'г' else lower(trim(coalesce(p.unit,''))) end u
        from products p where not coalesce(p.archived,false)),
    m as (
      select distinct on (p.id) p.id, ir.key, ir.unit ru, ir.price rp, ir.kg_l, ir.doc_date, ir.src,
             invoice_unit_price(ir.unit, ir.price, p.u, ir.kg_l) np
        from p join invoice_ref ir
          on not exists (select 1 from unnest(ir.inc) x where p.n !~ x)
         and not exists (select 1 from unnest(ir.exc) x where p.n ~ x)
       order by p.id, (invoice_unit_price(ir.unit, ir.price, p.u, ir.kg_l) is not null) desc, ir.manual, ir.prio desc, ir.doc_date desc nulls last, ir.key)
    select p.id, p.name, p.unit, p.u, p.n, coalesce(p.price,0) old_price,
           s.price s_price, s.doc_date s_date, s.src s_src, s.ref_key s_key,
           m.key, m.ru, m.rp, m.np, m.doc_date, m.src
      from p left join m on m.id = p.id left join price_source s on s.product_id = p.id
  loop
    np := null;
    if r.name = any(wrong) then
      np := null;
    elsif r.s_price is not null then
      np := r.s_price;                                             -- уже взято из накладной раньше
    elsif r.np is not null then
      np := r.np;                                                  -- накладная, та же единица
    elsif r.rp is not null and r.u in ('кг','л') and r.ru in ('кг','л') and r.n ~ liq then
      np := r.rp;                                                  -- кг ↔ л для жидкого
    end if;

    if np is null then
      if r.old_price <> 0 then
        update products set price = 0 where id = r.id;
      end if;
      delete from price_source where product_id = r.id;
      insert into r52 values (2, case when r.rp is not null and not (r.name = any(wrong)) then '0 — в накладной другая единица ('||r.ru||')'
                                      when r.name = any(wrong) then '0 — в накладной другой товар'
                                      else '0 — нет в накладных' end,
                              r.name, r.unit, r.old_price, 0,
                              case when r.rp is not null then trim_scale(r.rp)||' ₸/'||r.ru||' · '||coalesce(r.src,'') end);
    else
      np := round(np, 2);
      if round(r.old_price,2) <> np then
        update products set price = np where id = r.id;
      end if;
      insert into price_source(product_id, price, doc_date, src, ref_key, set_at)
      values (r.id, np, coalesce(r.s_date, r.doc_date), coalesce(r.s_src, r.src), coalesce(r.s_key, r.key), now())
      on conflict (product_id) do update set price = excluded.price, doc_date = excluded.doc_date, src = excluded.src, ref_key = excluded.ref_key, set_at = now();
      insert into r52 values (case when round(r.old_price,2) <> np then 1 else 3 end,
                              case when r.s_key = 'satu53' then '✅ цена с satu.kz (оставлена)' when r.s_key = 'owner54' then '✅ цена владельца/счёта (оставлена)' when round(r.old_price,2) <> np then '✅ цена из накладной' else '✅ уже по накладной' end,
                              r.name, r.unit, r.old_price, np, coalesce(r.s_src, r.src));
    end if;
  end loop;

  -- уборка: нет в техкартах (и в составе сетов), нет остатка → архив
  for r in select p.* from products p where not coalesce(p.archived,false)
             and not exists (select 1 from recipes x join dishes d on d.id = x.dish_id and not coalesce(d.archived,false) where x.product_id = p.id)
             and not (to_regclass('public.set_items') is not null and exists (select 1 from set_items x join dishes d on d.id = x.set_id and not coalesce(d.archived,false) where x.product_id = p.id))
             and greatest(coalesce(p.s_kitchen,0),0) + greatest(coalesce(p.s_bar,0),0) <= 0
             and not exists (select 1 from price_source s where s.product_id = p.id and s.doc_date > current_date - 30)   -- только что закуплен (лёд, орехи…)
  loop
    update products set archived = true, archived_at = now() where id = r.id;
    insert into movements(kind,info,product_id) values('Удалён в архив', r.name||' (не используется в техкартах)', r.id);
    delete from r52 where name = r.name;
    insert into r52 values (4, '🗄 в архив: нет в техкартах', r.name, r.unit, null, null, null);
  end loop;

  begin execute 'alter table products enable trigger products_autostop_t'; exception when others then null; end;
end $p52$;

notify pgrst, 'reload schema';

-- ================= ИТОГ =================
select act as "Что сделано", name as "Продукт", unit as "Ед.", trim_scale(old_price) as "Было, ₸", trim_scale(new_price) as "Стало, ₸", src as "Накладная" from (
  select ord, act, name, unit, old_price, new_price, src from r52
  union all select 0, 'ИТОГО: цена из накладной', count(*) filter (where ord in (1,3))::text, null, null, null, null from r52
  union all select 0, 'ИТОГО: цена 0 (нужна накладная)', count(*) filter (where ord = 2)::text, null, null, null, null from r52
  union all select 0, 'ИТОГО: в архив', count(*) filter (where ord = 4)::text, null, null, null, null from r52) x
order by ord, act, name;
