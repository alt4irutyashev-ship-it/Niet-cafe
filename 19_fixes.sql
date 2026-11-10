-- Niet Café: исправления по проверке сайта (ноябрь 2026).
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
--
-- 1. ПОТЕРИ ПРИ ЧИСТКЕ. Экран техкарт считает брутто = нетто ÷ (1 − потеря%),
--    а база при заказе считала нетто × (1 + потеря%). При потере 30% это 1,43 против 1,30:
--    себестоимость в отчётах занижалась, а со склада списывалось меньше, чем уходит на самом деле.
--    Ниже формула в базе меняется на ту же, что на экране. Остальная логика функций не трогается.
-- 2. БЕЗОПАСНОСТЬ. Если старый migration3.sql когда-нибудь запустят повторно, он снова откроет
--    журнал склада всем сотрудникам и снимет проверку «только руководитель». Здесь это закрывается
--    ещё раз, а функции push-подписки и списка сотрудников закрываются от незалогиненных.

-- ===== 1. Формула потерь =====
do $$
declare f record; def text; n int := 0;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.prosrc like '%*(1+coalesce(p.loss_pct,0)/100)%'
  loop
    def := replace(pg_get_functiondef(f.oid), '*(1+coalesce(p.loss_pct,0)/100)', '/(1-coalesce(p.loss_pct,0)/100)');
    execute def;
    n := n + 1;
  end loop;
  raise notice 'Формула потерь исправлена в функциях: %', n;
end $$;

-- 1б. Себестоимость в заказе. Триггер oi_snap (файл 14) срабатывает последним и записывал
--     себестоимость вообще без потерь — поэтому отчёты занижали расход продуктов.
do $$
declare f record; def text; n int := 0;
begin
  for f in
    select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
    where s.nspname = 'public' and p.prosrc like '%new.cost%' and p.prosrc like '%sum(r.qty*p.price),0)%'
  loop
    def := replace(pg_get_functiondef(f.oid), 'sum(r.qty*p.price),0)', 'sum(r.qty*p.price/(1-coalesce(p.loss_pct,0)/100)),0)');
    execute def;
    n := n + 1;
  end loop;
  raise notice 'Себестоимость с потерями теперь в функциях: %', n;
end $$;

-- ===== 2. Журнал склада и движение остатков — только руководителю =====
drop policy if exists stock_log_all on stock_log;
drop policy if exists stock_log_boss on stock_log;
create policy stock_log_boss on stock_log for all using (my_role()='boss') with check (my_role()='boss');

create or replace function stock_move(p_id bigint, p_kind text, p_qty numeric, p_sum numeric, p_note text)
returns void language plpgsql security definer set search_path=public as $$
declare d numeric;
begin
  if my_role() is distinct from 'boss' then raise exception 'Нет доступа'; end if;
  if p_kind not in ('in','waste') or coalesce(p_qty,0)<=0 then raise exception 'Неверные данные'; end if;
  perform 1 from products where id=p_id for update;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set
    s_kitchen=case when station='kitchen' then s_kitchen+d else s_kitchen end,
    s_bar=case when station='bar' then s_bar+d else s_bar end
  where id=p_id;
  insert into stock_log(kind,product_id,qty,sum,note) values(p_kind,p_id,p_qty,coalesce(p_sum,0),p_note);
end $$;

-- ===== 3. Функции только для вошедших сотрудников =====
-- «revoke ... from anon» без «from public» не работает: anon получает право через public.
revoke execute on function stock_move(bigint,text,numeric,numeric,text) from public, anon;
grant  execute on function stock_move(bigint,text,numeric,numeric,text) to authenticated;
revoke execute on function push_register(text,text,text,text) from public, anon;
grant  execute on function push_register(text,text,text,text) to authenticated;
revoke execute on function push_unregister(text) from public, anon;
grant  execute on function push_unregister(text) to authenticated;
revoke execute on function staff_names() from public, anon;
grant  execute on function staff_names() to authenticated;

-- Проверка (необязательно): должно вернуть 0 строк
-- select proname from pg_proc where pronamespace='public'::regnamespace and prosrc like '%(1+coalesce(p.loss_pct%';
