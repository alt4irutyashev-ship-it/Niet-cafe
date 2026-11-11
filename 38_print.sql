-- Niet Café 38: реквизиты для печати пречека на термопринтере (название, юр. лицо, БИН, адрес, телефон, текст внизу).
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Можно запускать повторно.
-- Менять реквизиты: руководитель → «Команда и затраты» → «Печать чеков».

create table if not exists print_cfg(key text primary key, val text);
alter table print_cfg enable row level security;
drop policy if exists print_cfg_read on print_cfg;
drop policy if exists print_cfg_boss on print_cfg;
create policy print_cfg_read on print_cfg for select using (my_role() <> 'none');           -- все сотрудники (официанту нужно для печати)
create policy print_cfg_boss on print_cfg for all using (my_role() = 'boss') with check (my_role() = 'boss');

insert into print_cfg(key,val) values
  ('name','Niet Café'),
  ('legal',''),                 -- например: ИП «Ваше имя» или ТОО «...»
  ('bin',''),                   -- БИН / ИИН
  ('address','г. Астана'),
  ('phone',''),
  ('extra','Instagram: @niet.cafe'),
  ('footer','Спасибо, ждём вас снова!'),
  ('logo','1'),
  ('waiter','1'),
  ('note','1')                  -- строка «Не является фискальным чеком»
on conflict (key) do nothing;

notify pgrst, 'reload schema';
