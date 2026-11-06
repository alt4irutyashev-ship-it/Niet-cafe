-- Запустите один раз в Supabase: SQL Editor -> New query -> Run
alter table products add column if not exists station text not null default 'kitchen';
update products set station='bar' where s_bar>0 and s_kitchen=0;
update products set s_kitchen=s_kitchen+s_main where station='kitchen';
update products set s_bar=s_bar+s_main where station='bar';
update products set s_main=0;

create or replace function stock_apply() returns trigger language plpgsql security definer as $$
declare d bigint; k numeric;
begin
  if tg_op='INSERT' then d:=new.dish_id; k:=new.qty;
  elsif tg_op='DELETE' then d:=old.dish_id; k:=-old.qty;
  else d:=new.dish_id; k:=new.qty-old.qty; end if;
  if k<>0 then
    update products p set
      s_kitchen=case when p.station='kitchen' then p.s_kitchen-r.qty*k else p.s_kitchen end,
      s_bar=case when p.station='bar' then p.s_bar-r.qty*k else p.s_bar end
    from recipes r where r.product_id=p.id and r.dish_id=d;
  end if;
  return coalesce(new,old);
end $$;

drop trigger if exists order_items_stock on order_items;
create trigger order_items_stock after insert or delete or update of qty on order_items
for each row execute function stock_apply();
