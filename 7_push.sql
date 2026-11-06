-- Niet Café: Web Push (уведомления при закрытом приложении и на заблокированном телефоне).
-- Выполнить ОДИН раз в Supabase -> SQL Editor -> New query -> Run. Можно запускать повторно.
-- После запуска выполните ещё одну команду (см. внизу файла): впишите секрет.

create extension if not exists pg_net;

-- 1. Подписки устройств
create table if not exists push_subs(
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  endpoint text unique not null,
  p256dh text not null,
  auth_key text not null,
  ua text,
  created timestamptz not null default now()
);
create index if not exists push_subs_user on push_subs(user_id);
alter table push_subs enable row level security;   -- без политик: напрямую недоступна, только через функции ниже

create or replace function push_register(p_endpoint text,p_p256dh text,p_auth text,p_ua text) returns void
language sql security definer set search_path=public as $$
  insert into push_subs(user_id,endpoint,p256dh,auth_key,ua) values(auth.uid(),p_endpoint,p_p256dh,p_auth,p_ua)
  on conflict(endpoint) do update set user_id=excluded.user_id,p256dh=excluded.p256dh,auth_key=excluded.auth_key,ua=excluded.ua,created=now();
$$;
create or replace function push_unregister(p_endpoint text) returns void
language sql security definer set search_path=public as $$
  delete from push_subs where endpoint=p_endpoint and user_id=auth.uid();
$$;
revoke execute on function push_register(text,text,text,text) from anon;
revoke execute on function push_unregister(text) from anon;

-- 2. Настройки отправки (читает только сервер)
create table if not exists push_cfg(key text primary key, val text);
alter table push_cfg enable row level security;
insert into push_cfg values('url','https://iamomamsltqfpeljahuy.supabase.co/functions/v1/push'),('secret','CHANGE_ME') on conflict do nothing;

-- 3. Отправка пачки уведомлений в Edge Function. Любая ошибка здесь НЕ ломает работу с заказами.
create or replace function push_send(p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare u text; s text;
begin
  if p is null or jsonb_typeof(p)<>'array' or jsonb_array_length(p)=0 then return; end if;
  select val into u from push_cfg where key='url';
  select val into s from push_cfg where key='secret';
  if coalesce(u,'')='' or coalesce(s,'') in ('','CHANGE_ME') then return; end if;
  perform net.http_post(url:=u, body:=p, headers:=jsonb_build_object('Content-Type','application/json','x-push-secret',s), timeout_milliseconds:=5000);
exception when others then null;
end $$;
revoke execute on function push_send(jsonb) from public, anon, authenticated;

-- 4. Новые позиции -> кухня / бар
create or replace function push_on_ins() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send((
    select coalesce(jsonb_agg(jsonb_build_object('kind','new','to_role',x.station,'tag','n_'||x.batch::text||'_'||x.station,
             'title','🔔 Новый заказ · '||coalesce(x.label,'Заказ'),'body',x.b||E'\n👤 '||coalesce(x.wn,'—'))),'[]'::jsonb)
    from (select i.station,i.batch,i.label,
                 string_agg(i.qty||'× '||coalesce(d.name,'блюдо'),', ' order by i.id) b, max(p.name) wn
          from nt i left join dishes d on d.id=i.dish_id left join profiles p on p.id=i.waiter
          where i.station is not null group by i.station,i.batch,i.label) x));
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_ins_t on order_items;
create trigger push_ins_t after insert on order_items referencing new table as nt for each statement execute function push_on_ins();

-- 5. Статус «принято» / «готово» -> официант, который отправил позицию
create or replace function push_on_upd() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send((
    select coalesce(jsonb_agg(jsonb_build_object('kind',x.st,'to_user',x.waiter,'tag','w_'||x.batch::text||'_'||x.station||'_'||x.st,
             'title',case when x.st='ready' then '✅ ГОТОВО · ' else '👍 Принято: '||x.sn||' · ' end||coalesce(x.label,'Заказ'),
             'body',case when x.st='ready' then x.sn||': ' else '' end||x.b)),'[]'::jsonb)
    from (select n.waiter,n.batch,n.station,n.status st,n.label,
                 case n.station when 'kitchen' then 'Кухня' when 'bar' then 'Бар' else n.station end sn,
                 string_agg(n.qty||'× '||coalesce(d.name,'блюдо'),', ' order by n.id) b
          from nt n join ot o on o.id=n.id left join dishes d on d.id=n.dish_id
          where n.status is distinct from o.status and n.status in ('accepted','ready') and n.waiter is not null
          group by n.waiter,n.batch,n.station,n.status,n.label) x));
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_upd_t on order_items;
create trigger push_upd_t after update on order_items referencing old table as ot new table as nt for each statement execute function push_on_upd();

-- 6. Официант убрал позицию -> кухня / бар
create or replace function push_on_del() returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform push_send((
    select coalesce(jsonb_agg(jsonb_build_object('kind','cancel','to_role',x.station,'tag','c_'||x.label||'_'||x.station,
             'title','❌ ОТМЕНА · '||coalesce(x.label,'Заказ'),'body',x.b||' — официант убрал позицию')),'[]'::jsonb)
    from (select o.station,o.label,string_agg(o.qty||'× '||coalesce(d.name,'блюдо'),', ' order by o.id) b
          from ot o left join dishes d on d.id=o.dish_id
          where o.station is not null and o.status in ('new','accepted','cooking') and exists(select 1 from orders r where r.id=o.order_id)
          group by o.station,o.label) x));
  return null;
exception when others then return null;
end $$;
drop trigger if exists push_del_t on order_items;
create trigger push_del_t after delete on order_items referencing old table as ot for each statement execute function push_on_del();

-- ===== ПОСЛЕ ЗАПУСКА ВСЕГО ВЫШЕ выполните отдельно (подставьте ТОТ ЖЕ секрет, что в Edge Function PUSH_SECRET): =====
-- update push_cfg set val='ВАШ_ДЛИННЫЙ_СЕКРЕТ' where key='secret';
-- Проверка (придёт всем официантам с включёнными уведомлениями):
-- select push_send('[{"kind":"test","to_role":"waiter","tag":"test","title":"Тест","body":"Push работает"}]'::jsonb);
