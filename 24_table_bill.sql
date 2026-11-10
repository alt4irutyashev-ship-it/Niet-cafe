-- Niet Café: гость видит текущий счёт своего стола (по NFC-ссылке guest.html?t=N).
-- Выполнить ПОСЛЕ 23_guest_status.sql: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
--
-- Что видит гость: блюда открытого заказа стола, статус каждого (принят / готовится / готово / подано),
-- сумму блюд, обслуживание и итог. Только столы зала (1–99): заказы с собой и доставки не отдаются.
-- Никаких личных данных (телефонов, адресов, имён официантов) функция не возвращает.

create or replace function guest_table_bill(t int)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_oid int; v_open timestamptz; v_sv numeric; v_items jsonb; v_sub numeric;
begin
  if t is null or t < 1 or t > 99 then return null; end if;
  select id, created into v_oid, v_open from orders where tbl = t and status = 'open' order by id limit 1;
  if v_oid is null then return jsonb_build_object('items','[]'::jsonb,'sub',0,'svc',0,'total',0,'sv',0); end if;
  v_sv := coalesce((select val from settings where key = 'service'), 10);
  select coalesce(jsonb_agg(jsonb_build_object('dish_id',x.dish_id,'qty',x.qty,'status',x.status,'price',x.price) order by x.first_id), '[]'::jsonb),
         coalesce(sum(x.qty * x.price), 0)
    into v_items, v_sub
    from (select it.dish_id, it.status, coalesce(it.price, d.price, 0) as price, sum(it.qty) as qty, min(it.id) as first_id
            from order_items it left join dishes d on d.id = it.dish_id
           where it.order_id = v_oid
           group by it.dish_id, it.status, coalesce(it.price, d.price, 0)) x;
  return jsonb_build_object('items', v_items, 'sub', v_sub, 'sv', v_sv,
                            'svc', round(v_sub * v_sv / 100), 'total', v_sub + round(v_sub * v_sv / 100), 'opened', v_open);
end $$;
revoke execute on function guest_table_bill(int) from public;
grant execute on function guest_table_bill(int) to anon, authenticated;

notify pgrst, 'reload schema';
