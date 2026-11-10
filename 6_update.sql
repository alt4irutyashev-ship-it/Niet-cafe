-- Niet Café: вызов официанта, заказ с телефона гостя, КБЖУ, аллергены, метки.
-- Выполнить в Supabase -> SQL Editor после 5_guest.sql. Можно запускать повторно.

-- КБЖУ, аллергены и метки блюда
alter table dishes add column if not exists weight int;        -- вес, г
alter table dishes add column if not exists kcal int;          -- ккал
alter table dishes add column if not exists prot numeric;      -- белки, г
alter table dishes add column if not exists fat numeric;       -- жиры, г
alter table dishes add column if not exists carb numeric;      -- углеводы, г
alter table dishes add column if not exists allerg text;       -- аллергены
alter table dishes add column if not exists tags text;         -- метки: new,hit,spicy

-- вызовы со стола: «позвать официанта» и «счёт»
create table if not exists calls(id serial primary key, tbl int not null, kind text not null, created timestamptz default now(), done boolean default false);
alter table calls enable row level security;
drop policy if exists calls_staff on calls;
create policy calls_staff on calls for all using (my_role() in ('waiter','boss')) with check (my_role() in ('waiter','boss'));

-- заказы гостей с телефона (официант принимает или отклоняет)
create table if not exists guest_orders(id serial primary key, tbl int not null, items jsonb not null, note text, status text default 'new', created timestamptz default now());
alter table guest_orders enable row level security;
drop policy if exists go_staff on guest_orders;
create policy go_staff on guest_orders for all using (my_role() in ('waiter','boss')) with check (my_role() in ('waiter','boss'));

-- гость пишет только через эти функции (с проверками), напрямую таблицы ему закрыты
create or replace function guest_call(t int, k text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if t is null or t < 1 or t > 30 or k not in ('waiter','bill') then raise exception 'Неверный запрос'; end if;
  if exists(select 1 from calls where tbl=t and kind=k and not done and created > now() - interval '2 minutes') then return; end if;
  insert into calls(tbl,kind) values(t,k);
end$$;

create or replace function guest_order(t int, its jsonb, n text) returns int
language plpgsql security definer set search_path=public as $$
declare oid int; clean jsonb;
begin
  if t is null or t < 1 or t > 30 then raise exception 'Неверный стол'; end if;
  select jsonb_agg(jsonb_build_object('dish_id',d.id,'qty',least(greatest((x->>'qty')::int,1),20)))
    into clean
    from jsonb_array_elements(its) x join dishes d on d.id=(x->>'dish_id')::int and not coalesce(d.stop,false);
  if clean is null or jsonb_array_length(clean) > 40 then raise exception 'Пустой заказ'; end if;
  if (select count(*) from guest_orders where tbl=t and created > now() - interval '1 minute') >= 3 then raise exception 'Слишком часто'; end if;
  insert into guest_orders(tbl,items,note) values(t,clean,left(n,300)) returning id into oid;
  return oid;
end$$;

create or replace function guest_order_status(i int) returns text
language sql stable security definer set search_path=public as $$ select status from guest_orders where id=i $$;

grant execute on function guest_call(int,text) to anon, authenticated;
grant execute on function guest_order(int,jsonb,text) to anon, authenticated;
grant execute on function guest_order_status(int) to anon, authenticated;

-- уведомления официанту в реальном времени
do $$ begin alter publication supabase_realtime add table calls; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table guest_orders; exception when duplicate_object then null; end $$;
