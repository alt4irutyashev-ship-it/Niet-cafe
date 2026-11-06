-- Niet Café: поток заказов (отделы, статусы, вынос, KPI).
-- Выполнить ОДИН раз в Supabase -> SQL Editor -> New query -> Run. Можно запускать повторно.

-- 1. Заказы: тип (стол / вынос), номер выноса, имя клиента
alter table orders add column if not exists kind text not null default 'dine';
alter table orders add column if not exists tk_no int;
alter table orders add column if not exists note text;

-- 2. Позиции: билет (одна отправка официанта), подпись, кто взял, времена статусов
alter table order_items add column if not exists batch uuid;
alter table order_items add column if not exists label text;
alter table order_items add column if not exists waiter uuid default auth.uid();
alter table order_items add column if not exists accepted_at timestamptz;
alter table order_items add column if not exists accepted_by uuid;
alter table order_items add column if not exists ready_at timestamptz;
alter table order_items add column if not exists ready_by uuid;
alter table order_items add column if not exists served_at timestamptz;
-- статусы: new -> accepted -> ready -> served
create index if not exists oi_station_status on order_items(station,status);
create index if not exists oi_batch on order_items(batch);

-- 3. Номер выноса: Вынос-1, Вынос-2 ... заново каждый день (часовой пояс Актобе)
create or replace function orders_tk() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.kind='take' then
    perform pg_advisory_xact_lock(7001);
    select coalesce(max(tk_no),0)+1 into new.tk_no from orders
     where kind='take' and (created at time zone 'Asia/Aqtobe')::date=(now() at time zone 'Asia/Aqtobe')::date;
  end if;
  return new;
end $$;
drop trigger if exists orders_tk_t on orders;
create trigger orders_tk_t before insert on orders for each row execute function orders_tk();

-- 4. Позиции: подпись билета ("Стол 5" / "Вынос-3"), билет, автор, отметки времени статусов
create or replace function items_before() returns trigger language plpgsql security definer set search_path=public as $$
declare o orders%rowtype;
begin
  if tg_op='INSERT' then
    select * into o from orders where id=new.order_id;
    new.label := case when o.kind='take' then 'Вынос-'||coalesce(o.tk_no::text,'?') else 'Стол '||o.tbl end;
    new.tbl := o.tbl;
    new.batch := coalesce(new.batch, gen_random_uuid());
    new.waiter := coalesce(new.waiter, auth.uid());
  elsif new.status is distinct from old.status and auth.uid() is not null then
    if new.status='accepted' then new.accepted_at:=now(); new.accepted_by:=auth.uid();
    elsif new.status='ready' then
      new.ready_at:=now(); new.ready_by:=auth.uid();
      if new.accepted_at is null then new.accepted_at:=now(); new.accepted_by:=auth.uid(); end if;
    elsif new.status='served' then new.served_at:=now();
    end if;
  end if;
  return new;
end $$;
drop trigger if exists items_before_t on order_items;
create trigger items_before_t before insert or update on order_items for each row execute function items_before();

-- 5. Имена сотрудников для всех ролей (логины и пароли не отдаются)
create or replace function staff_names() returns table(id uuid, name text, role text)
language sql stable security definer set search_path=public as
$$ select p.id, p.name, p.role from profiles p where my_role()<>'none' $$;

-- 6. Realtime: полные данные при удалении, заказы тоже в потоке
alter table order_items replica identity full;
do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='orders') then
    alter publication supabase_realtime add table orders;
  end if;
end $$;

-- 7. Старые данные: подпись и билеты у существующих позиций, закрытые заказы -> "выдано"
update order_items i set label='Стол '||i.tbl where i.label is null and i.tbl is not null;
update order_items i set batch=b.g from (select order_id, gen_random_uuid() g from order_items where batch is null group by order_id) b where i.order_id=b.order_id and i.batch is null;
update order_items set status='accepted' where status='cooking';
update order_items set status='served' where status<>'served' and order_id in (select id from orders where status='closed');
