-- Niet Café: подробный статус заказа для гостя (зал, самовывоз, доставка).
-- Выполнить ПОСЛЕ 21_delivery.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
--
-- Гость теперь видит не только «отправлен / принят / отклонён», а весь путь заказа:
--   доставка:   отправлен → принят → готовится → в пути → доставлен
--   самовывоз:  отправлен → принят → готовится → готов к выдаче → выдан
--   в зале:     отправлен → принят → готовится → готово → подано
-- «Готовится» — кухня или бар приняли хотя бы одно блюдо; «готово» — все блюда заказа отмечены готовыми.
-- «В пути» — официант нажал «Передан курьеру» в заказе доставки; «доставлен / выдан» — заказ закрыт (оплачен).

-- 1. Отметка «передан курьеру»
alter table orders add column if not exists out_at timestamptz;

-- 2. Статус заявки гостя (та же функция, что и раньше, — сайт гостя менять не обязательно, но новый показывает больше)
create or replace function guest_order_status(i int) returns text
language plpgsql stable security definer set search_path=public as $$
declare g guest_orders%rowtype; cids text[]; v_oid int; v_st text; v_kind text; v_out timestamptz;
        n int; n_ready int; n_served int; n_work int;
begin
  select * into g from guest_orders where id=i;
  if not found then return null; end if;
  if g.status is distinct from 'accepted' then return g.status; end if;   -- new / rejected
  -- блюда, созданные из этой заявки, имеют метку g<номер>_<позиция> (см. guest_accept)
  cids := array(select 'g'||i||'_'||k from generate_series(1, greatest(jsonb_array_length(g.items),1)) k);
  select count(*),
         count(*) filter (where it.status in ('ready','served')),
         count(*) filter (where it.status = 'served'),
         count(*) filter (where it.status <> 'new'),
         max(it.order_id)
    into n, n_ready, n_served, n_work, v_oid
    from order_items it where it.cid = any(cids);
  if n = 0 then return 'accepted'; end if;
  select status, kind, out_at into v_st, v_kind, v_out from orders where id = v_oid;
  if v_kind = 'delivery' then
    if v_st = 'closed' then return 'done'; end if;
    if v_out is not null then return 'way'; end if;
  elsif v_kind = 'take' then
    if v_st = 'closed' then return 'done'; end if;
  else
    if v_st = 'closed' or n_served = n then return 'served'; end if;
  end if;
  if n_ready = n then return 'ready'; end if;
  if n_work > 0 then return 'cooking'; end if;
  return 'accepted';
end $$;
revoke execute on function guest_order_status(int) from public;
grant execute on function guest_order_status(int) to anon, authenticated;

notify pgrst, 'reload schema';
