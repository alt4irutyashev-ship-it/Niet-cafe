-- Niet Café: гостевая страница (NFC / QR). Выполнить в Supabase -> SQL Editor после 4_update.sql.
-- Можно запускать повторно.

-- описание (состав) и фото блюда
alter table dishes add column if not exists descr text;
alter table dishes add column if not exists photo text;

-- ссылки для гостей: TikTok, Instagram, WhatsApp, 2ГИС
create table if not exists links(key text primary key, url text default '', pos int);
insert into links values('tiktok','',1),('instagram','',2),('whatsapp','',3),('2gis','',4) on conflict (key) do nothing;
alter table links enable row level security;
drop policy if exists links_r on links;  create policy links_r on links for select using (true);
drop policy if exists links_b on links;  create policy links_b on links for all using (my_role()='boss') with check (my_role()='boss');

-- гости (без входа) видят меню и процент обслуживания
drop policy if exists cats_pub on cats;      create policy cats_pub on cats for select to anon using (true);
drop policy if exists dishes_pub on dishes;  create policy dishes_pub on dishes for select to anon using (true);
drop policy if exists set_pub on settings;   create policy set_pub on settings for select to anon using (key='service');

-- хранилище фото блюд (публичное чтение, загружает только руководитель)
insert into storage.buckets(id,name,public) values('menu','menu',true) on conflict (id) do nothing;
drop policy if exists menu_ins on storage.objects;
create policy menu_ins on storage.objects for insert to authenticated with check (bucket_id='menu' and public.my_role()='boss');
drop policy if exists menu_upd on storage.objects;
create policy menu_upd on storage.objects for update to authenticated using (bucket_id='menu' and public.my_role()='boss');
drop policy if exists menu_del on storage.objects;
create policy menu_del on storage.objects for delete to authenticated using (bucket_id='menu' and public.my_role()='boss');
