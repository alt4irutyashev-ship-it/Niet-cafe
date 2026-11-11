-- Niet Café 33: push-уведомления на заблокированный экран — для всех ролей и всех важных событий.
-- Выполнить ПОСЛЕ 7_push.sql и 29: Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
-- ВАЖНО: после этого файла обновите Edge Function «push» кодом из supabase/functions/push/index.ts (см. PUSH_SETUP.md, шаг 2).
--
-- Кто что получает (даже при закрытом сайте и заблокированном телефоне):
--   Кухня / Бар:   🍳 новый заказ · ❌ отмена · ⛔ блюдо в автостопе / ✅ снова в меню
--   Официант:      👍 принято · ✅ готово · 🙋 вызов · 🧾 счёт · 📱 заказ со стола · 🛵 доставка · 🥡 самовывоз · ⛔ стоп
--   Руководитель:  🛵 доставка · 🥡 самовывоз · ⛔ автостоп · ⚠ продукт заканчивается
--   Склад:         ⚠ продукт заканчивается (остаток стал ниже минимума)
--   Гость:         статус своего заказа (принят → готовится → готов/в пути → доставлен), если нажал «🔔 Сообщить»

-- 0. Выключатель на время служебных операций (демо-данные, сброс): set_config('niet.nopush','1',true)
create or replace function push_send(p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare u text; s text;
begin
  if p is null or jsonb_typeof(p)<>'array' or jsonb_array_length(p)=0 then return; end if;
  if coalesce(current_setting('niet.nopush', true),'') = '1' then return; end if;
  select val into u from push_cfg where key='url';
  select val into s from push_cfg where key='secret';
  if coalesce(u,'')='' or coalesce(s,'') in ('','CHANGE_ME') then return; end if;
  perform net.http_post(url:=u, body:=p, headers:=jsonb_build_object('Content-Type','application/json','x-push-secret',s), timeout_milliseconds:=5000);
exception when others then null;
end $$;
revoke execute on function push_send(jsonb) from public, anon, authenticated;

-- 1. Диагностика доставки: функция отправки отмечает последнюю удачную доставку и ошибки
alter table push_subs add column if not exists last_ok timestamptz;
alter table push_subs add column if not exists fails int not null default 0;
alter table push_subs add column if not exists last_err text;

-- 2. ПРОВЕРКА НА ЭТОМ ТЕЛЕФОНЕ: уведомление придёт через p_delay секунд — успейте заблокировать экран
--    Ответ: -1 — сервер push не настроен (секрет), 0 — у сотрудника нет подключённых устройств, N — отправлено на N устройств
create or replace function push_test_me(p_delay int default 15) returns int
language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'Войдите в систему'; end if;
  if coalesce((select val from push_cfg where key='secret'),'') in ('','CHANGE_ME') then return -1; end if;   -- сервер push ещё не настроен
  select count(*) into n from push_subs where user_id = auth.uid();
  perform push_send(jsonb_build_array(jsonb_build_object('kind','test','to_user',auth.uid(),'tag','test_'||extract(epoch from now())::bigint,
    'delay', least(greatest(coalesce(p_delay,15),0),25),
    'title','🔔 Проверка уведомлений', 'body','Если вы видите это на заблокированном экране — уведомления работают ✅')));
  return n;   -- сколько устройств этого сотрудника подписано
end $$;
revoke execute on function push_test_me(int) from public, anon;
grant execute on function push_test_me(int) to authenticated;

-- 3. СПИСОК УСТРОЙСТВ для руководителя (кто подключён и когда push последний раз дошёл)
drop function if exists push_devices();
create or replace function push_devices() returns table(user_id uuid, name text, role text, device text, created timestamptz, last_ok timestamptz, fails int, last_err text)
language sql stable security definer set search_path=public as $$
  select s.user_id, p.name, p.role,
         case when s.ua ~* 'iphone|ipad' then 'iPhone/iPad' when s.ua ~* 'android' then 'Android' when s.ua ~* 'windows' then 'Windows' when s.ua ~* 'mac os' then 'Mac' else 'Другое' end
         || case when s.ua ~* 'edg/' then ' · Edge' when s.ua ~* 'firefox' then ' · Firefox' when s.ua ~* 'chrome' then ' · Chrome' when s.ua ~* 'safari' then ' · Safari' else '' end,
         s.created, s.last_ok, s.fails, s.last_err
    from push_subs s left join profiles p on p.id = s.user_id
   where my_role() = 'boss'
   order by p.role, p.name, s.created desc
$$;
revoke execute on function push_devices() from public, anon;
grant execute on function push_devices() to authenticated;

-- 4. АВТОСТОП → кухня/бар этого блюда, официанты, руководитель
create or replace function push_dish_stop() returns trigger language plpgsql security definer set search_path=public as $$
declare ttl text; bd text; k text;
begin
  if coalesce(new.archived,false) then return null; end if;
  if new.stop and new.stop_auto and not coalesce(old.stop,false) then
    k := 'stop'; ttl := '⛔ Стоп: '||new.name; bd := 'Закончился продукт по техкарте — блюдо снято с продажи';
  elsif not new.stop and coalesce(old.stop,false) and old.stop_auto then
    k := 'unstop'; ttl := '✅ Снова в меню: '||new.name; bd := 'Блюдо снова можно заказывать';
  else return null; end if;
  perform push_send(jsonb_build_array(
    jsonb_build_object('kind',k,'to_role','waiter','tag','stop_'||new.id,'title',ttl,'body',bd),
    jsonb_build_object('kind',k,'to_role',coalesce(new.station,'kitchen'),'tag','stop_'||new.id,'title',ttl,'body',bd),
    jsonb_build_object('kind',k,'to_role','boss','tag','stop_'||new.id,'title',ttl,'body',bd)));
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_dish_stop_t on dishes;
create trigger push_dish_stop_t after update of stop on dishes for each row execute function push_dish_stop();

-- 5. ПРОДУКТ ЗАКАНЧИВАЕТСЯ (остаток стал ниже минимума) → склад и руководитель
create or replace function push_low_stock() returns trigger language plpgsql security definer set search_path=public as $$
declare o numeric; n numeric;
begin
  if coalesce(new.min,0) <= 0 then return null; end if;
  o := coalesce(old.s_kitchen,0) + coalesce(old.s_bar,0);
  n := coalesce(new.s_kitchen,0) + coalesce(new.s_bar,0);
  if o >= new.min and n < new.min then
    perform push_send((select jsonb_agg(jsonb_build_object('kind','low','to_role',r,'tag','low_'||new.id,
      'title','⚠ Заканчивается: '||new.name,
      'body','Осталось '||trim_scale(round(n,2))||' '||new.unit||' (минимум '||trim_scale(new.min)||' '||new.unit||'). Пора заказать.'))
      from unnest(array['store','boss']) r));
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_low_stock_t on products;
create trigger push_low_stock_t after update of s_kitchen, s_bar on products for each row execute function push_low_stock();

-- 6. ДОСТАВКА И САМОВЫВОЗ С САЙТА → официанты и руководитель
create or replace function push_guest_order() returns trigger language plpgsql security definer set search_path=public as $$
declare k text; ttl text; bd text;
begin
  k := case new.kind when 'delivery' then 'delivery' when 'take' then 'take' else 'gorder' end;
  ttl := case k when 'delivery' then '🛵 Доставка' when 'take' then '🥡 Самовывоз' else '📱 Заказ со стола '||new.tbl end;
  bd := (select string_agg((x->>'qty')||'× '||coalesce(d.name,'блюдо'),', ') from jsonb_array_elements(new.items) x left join dishes d on d.id=(x->>'dish_id')::int)
        || case when new.sum is not null then E'\n💰 '||round(new.sum+coalesce(new.fee,0))||' ₸' else '' end
        || case when new.address is not null and k='delivery' then E'\n📍 '||new.address else '' end;
  perform push_send(jsonb_build_array(jsonb_build_object('kind',k,'to_role','waiter','tag','g_'||new.id,'title',ttl,'body',bd))
    || case when k in ('delivery','take') then jsonb_build_array(jsonb_build_object('kind',k,'to_role','boss','tag','g_'||new.id,'title',ttl,'body',bd)) else '[]'::jsonb end);
  return null;
exception when others then return null;
end $$;

-- 7. PUSH ГОСТЮ о статусе его заказа -------------------------------------------------------------
create table if not exists guest_push_subs(
  id bigint generated always as identity primary key,
  gorder_id int not null,
  endpoint text not null,
  p256dh text not null,
  auth_key text not null,
  created timestamptz not null default now(),
  unique(gorder_id, endpoint)
);
alter table guest_push_subs enable row level security;   -- доступ только через функции ниже
alter table guest_orders add column if not exists push_st text;

create or replace function guest_push_register(p_order int, p_endpoint text, p_p256dh text, p_auth text) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from guest_orders where id = p_order and created > now() - interval '6 hours') then return false; end if;
  if length(coalesce(p_endpoint,'')) < 20 or p_endpoint !~ '^https://' then return false; end if;
  insert into guest_push_subs(gorder_id,endpoint,p256dh,auth_key) values(p_order,p_endpoint,p_p256dh,p_auth)
  on conflict (gorder_id,endpoint) do update set p256dh=excluded.p256dh, auth_key=excluded.auth_key;
  update guest_orders set push_st = coalesce(push_st, status) where id = p_order;
  delete from guest_push_subs where created < now() - interval '2 days';
  return true;
end $$;
revoke execute on function guest_push_register(int,text,text,text) from public;
grant execute on function guest_push_register(int,text,text,text) to anon, authenticated;

create or replace function guest_push_check(p_id int) returns void
language plpgsql security definer set search_path=public as $$
declare g guest_orders%rowtype; st text; ttl text; bd text; k text;
begin
  if not exists(select 1 from guest_push_subs where gorder_id = p_id) then return; end if;
  select * into g from guest_orders where id = p_id;
  if not found then return; end if;
  st := guest_order_status(p_id);
  if st is null or st is not distinct from g.push_st then return; end if;
  k := coalesce(g.kind, case when g.tbl >= 200 then 'delivery' when g.tbl >= 100 then 'take' else 'dine' end);
  ttl := case st
    when 'accepted' then '👍 Заказ принят'
    when 'cooking'  then '👨‍🍳 Готовим ваш заказ'
    when 'ready'    then case k when 'delivery' then '📦 Заказ собран' when 'take' then '✅ Заказ готов — можно забирать' else '✅ Всё готово' end
    when 'way'      then '🛵 Курьер уже едет'
    when 'done'     then case k when 'delivery' then '🎉 Заказ доставлен' else '🎉 Заказ выдан' end
    when 'served'   then '🍽 Приятного аппетита!'
    when 'rejected' then '😔 Заказ не принят'
    else null end;
  if ttl is null then update guest_orders set push_st = st where id = p_id; return; end if;
  bd := case st
    when 'accepted' then 'Niet Café приняло заказ №'||p_id||'. Скоро начнём готовить'
    when 'cooking'  then 'Повар уже готовит заказ №'||p_id
    when 'ready'    then case k when 'delivery' then 'Передаём курьеру' when 'take' then 'Назовите номер заказа: '||p_id else 'Официант уже несёт' end
    when 'way'      then 'Заказ №'||p_id||' в пути'
    when 'done'     then 'Спасибо, что выбрали Niet Café!'
    when 'served'   then 'Спасибо, что вы с нами'
    when 'rejected' then 'Пожалуйста, позвоните нам — поможем'
    end;
  update guest_orders set push_st = st where id = p_id;
  perform push_send(jsonb_build_array(jsonb_build_object('kind','guest','to_guest',p_id,'tag','go_'||p_id,'title',ttl,'body',bd,
    'url', case when k in ('delivery','take') then 'guest.html?take=1#cart' else 'guest.html#cart' end)));
exception when others then null;
end $$;
revoke execute on function guest_push_check(int) from public, anon, authenticated;

-- триггеры: смена статуса заявки, блюд, «передан курьеру», закрытие заказа
create or replace function gp_on_gorder() returns trigger language plpgsql security definer set search_path=public as $$
begin perform guest_push_check(new.id); return null; exception when others then return null; end $$;
drop trigger if exists gp_gorder_t on guest_orders;
create trigger gp_gorder_t after update of status on guest_orders for each row execute function gp_on_gorder();

create or replace function gp_on_items() returns trigger language plpgsql security definer set search_path=public as $$
declare gid int;
begin
  for gid in select distinct substring(n.cid from '^g(\d+)_')::int from nt n join ot o on o.id = n.id
              where n.cid ~ '^g\d+_' and n.status is distinct from o.status loop
    perform guest_push_check(gid);
  end loop;
  return null;
exception when others then return null;
end $$;
drop trigger if exists gp_items_t on order_items;
create trigger gp_items_t after update on order_items referencing old table as ot new table as nt for each statement execute function gp_on_items();

create or replace function gp_on_order() returns trigger language plpgsql security definer set search_path=public as $$
declare gid int;
begin
  if new.out_at is not distinct from old.out_at and new.status is not distinct from old.status then return null; end if;
  for gid in select distinct substring(cid from '^g(\d+)_')::int from order_items where order_id = new.id and cid ~ '^g\d+_' loop
    perform guest_push_check(gid);
  end loop;
  return null;
exception when others then return null;
end $$;
drop trigger if exists gp_order_t on orders;
create trigger gp_order_t after update on orders for each row execute function gp_on_order();

notify pgrst, 'reload schema';
