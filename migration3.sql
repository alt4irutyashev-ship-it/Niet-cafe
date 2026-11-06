-- Приход и списание. Запустите один раз в Supabase: SQL Editor -> New query -> Run
create table if not exists stock_log(
  id bigint generated always as identity primary key,
  t timestamptz not null default now(),
  kind text not null check (kind in ('in','waste')),
  product_id bigint not null,
  qty numeric not null,
  sum numeric not null default 0,
  note text
);
alter table stock_log enable row level security;
drop policy if exists stock_log_all on stock_log;
create policy stock_log_all on stock_log for all to authenticated using (true) with check (true);

create or replace function stock_move(p_id bigint, p_kind text, p_qty numeric, p_sum numeric, p_note text)
returns void language plpgsql security definer as $$
declare d numeric;
begin
  perform 1 from products where id=p_id for update;
  d := case when p_kind='in' then p_qty else -p_qty end;
  update products set
    s_kitchen=case when station='kitchen' then s_kitchen+d else s_kitchen end,
    s_bar=case when station='bar' then s_bar+d else s_bar end
  where id=p_id;
  insert into stock_log(kind,product_id,qty,sum,note) values(p_kind,p_id,p_qty,p_sum,p_note);
end $$;
