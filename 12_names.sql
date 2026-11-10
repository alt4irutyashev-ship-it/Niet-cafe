-- Niet Café: логин и имя сотрудника раздельно.
-- Выполнить один раз в Supabase -> SQL Editor. Можно запускать повторно.
alter table profiles add column if not exists login text;
update profiles p set login=split_part(u.email,'@',1) from auth.users u where u.id=p.id and p.login is null;

create or replace function new_user() returns trigger language plpgsql security definer set search_path=public as
$$begin insert into profiles(id,name,login,role) values(new.id,split_part(new.email,'@',1),split_part(new.email,'@',1),case when exists(select 1 from profiles) then 'none' else 'boss' end);return new;end$$;
