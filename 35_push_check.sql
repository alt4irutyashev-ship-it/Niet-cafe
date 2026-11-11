-- Niet Café 35: ПРОВЕРКА PUSH — находит, на каком шаге ломается доставка уведомлений при закрытом приложении.
-- Supabase -> SQL Editor -> New query -> вставить всё -> Run. Ничего не ломает, можно запускать сколько угодно.
--
-- Как пользоваться:
--   1) Run — создастся функция проверки и отправится тестовое уведомление всем подключённым телефонам.
--   2) Подождите 10 секунд и выполните отдельным запросом:   select * from push_check();
--   3) Смотрите колонку «Статус»: ❌ — тут и проблема, в «Что делать» написано, как исправить.

create extension if not exists pg_net;

-- колонки диагностики (на случай, если 33_push_all.sql ещё не выполняли)
do $$ begin
  if to_regclass('public.push_subs') is not null then
    alter table push_subs add column if not exists last_ok timestamptz;
    alter table push_subs add column if not exists fails int not null default 0;
    alter table push_subs add column if not exists last_err text;
  end if;
end $$;

create or replace function push_check(p_send_test boolean default false)
returns table("Шаг" text, "Статус" text, "Подробно" text, "Что делать" text)
language plpgsql security definer set search_path=public, extensions as $$
declare u text; s text; n int; r record; nresp int := 0; has_net boolean;
begin
  if auth.uid() is not null and my_role() <> 'boss' then raise exception 'Только руководитель'; end if;

  -- 1. расширение pg_net (база отправляет запрос в функцию push)
  has_net := exists(select 1 from pg_extension where extname = 'pg_net') or to_regnamespace('net') is not null;
  return query select '1. Расширение pg_net'::text, case when has_net then '✅' else '❌' end,
    case when has_net then 'установлено' else 'нет' end,
    case when has_net then '' else 'Database → Extensions → включите pg_net, затем запустите этот файл ещё раз' end;

  -- 2. адрес функции и секрет
  if to_regclass('public.push_cfg') is null then
    return query select '2. Настройки push_cfg'::text, '❌'::text, 'таблицы нет'::text, 'Выполните файл 7_push.sql, потом 33_push_all.sql'::text;
    return;
  end if;
  select val into u from push_cfg where key = 'url';
  select val into s from push_cfg where key = 'secret';
  return query select '2. Адрес функции push'::text, case when u ~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/push$' then '✅' else '❌' end, coalesce(u,'—'),
    case when u ~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/push$' then 'Адрес должен совпадать с проектом: Edge Functions → push → URL' else 'update push_cfg set val=''https://ВАШ_ПРОЕКТ.supabase.co/functions/v1/push'' where key=''url'';' end;
  return query select '3. Секрет PUSH_SECRET'::text, case when coalesce(s,'') in ('','CHANGE_ME') then '❌' else '✅' end,
    case when coalesce(s,'') in ('','CHANGE_ME') then 'не вписан — база НИЧЕГО не отправляет' else 'вписан ('||length(s)||' символов, начинается на «'||left(s,3)||'…»)' end,
    case when coalesce(s,'') in ('','CHANGE_ME') then 'update push_cfg set val=''ТОТ_ЖЕ_СЕКРЕТ_ЧТО_В_EDGE_FUNCTIONS_SECRETS'' where key=''secret'';' else 'Должен совпадать с PUSH_SECRET в Edge Functions → Secrets (буква в букву)' end;

  -- 3б. файлы 33 и 34 (новые уведомления, проверка на телефоне)
  return query select '3б. Файл 33_push_all.sql'::text, case when to_regproc('public.push_test_me') is not null then '✅' else '❌' end,
    case when to_regproc('public.push_test_me') is not null then 'выполнен' else 'не выполнен' end,
    case when to_regproc('public.push_test_me') is not null then '' else 'Выполните 33_push_all.sql, затем 34_stock_reviews_clients.sql и обновите код функции push (PUSH_SETUP.md, шаг 2)' end;
  return query select '3в. Файл 34_stock_reviews_clients.sql'::text, case when to_regproc('public.product_archive') is not null then '✅' else '❌' end,
    case when to_regproc('public.product_archive') is not null then 'выполнен' else 'не выполнен' end,
    case when to_regproc('public.product_archive') is not null then '' else 'Выполните после 33_push_all.sql' end;

  -- 4. подключённые телефоны
  if to_regclass('public.push_subs') is null then
    return query select '4. Телефоны'::text, '❌'::text, 'таблицы push_subs нет'::text, 'Выполните 7_push.sql и 33_push_all.sql'::text; return;
  end if;
  select count(*) into n from push_subs;
  return query select '4. Подключённые телефоны'::text, case when n > 0 then '✅' else '❌' end, n||' устройств',
    case when n > 0 then 'Список ниже' else 'На телефоне: войти → кнопка 🔊 → «Включить уведомления» → Разрешить. iPhone — только с иконки на экране «Домой»' end;
  for r in select coalesce(p.name,'?') nm, coalesce(p.role,'?') rl, ps.ua, ps.created, ps.last_ok, ps.fails, ps.last_err
             from push_subs ps left join profiles p on p.id = ps.user_id order by p.role, p.name loop
    return query select '   · '||r.nm||' ('||r.rl||')',
      case when r.fails > 0 then '❌' when r.last_ok is not null then '✅' else '…' end,
      case when r.ua ~* 'iphone|ipad' then 'iPhone' when r.ua ~* 'android' then 'Android' else 'компьютер' end
        || ' · подключён '||to_char(r.created at time zone 'Asia/Almaty','DD.MM HH24:MI')
        || case when r.last_ok is not null then ' · последний push дошёл '||to_char(r.last_ok at time zone 'Asia/Almaty','DD.MM HH24:MI') else ' · доставок ещё не было' end
        || case when r.last_err is not null then ' · ошибка '||r.last_err else '' end,
      case when r.last_err ~* 'BadJwtToken|VapidPkHash|subject' or r.last_err ~ '^400' then 'iPhone отклонил подпись: VAPID_SUBJECT в Secrets должен быть ровно mailto:адрес@почта (латиницей, без пробелов), и ключи VAPID должны быть парой. Потом на iPhone: 🔊 → Выключить → Включить'
           when r.last_err ~ '^40[13]' then 'Ключи VAPID не совпадают: публичный ключ в index.html (const VAPID) должен быть парой к VAPID_PRIVATE в Secrets. После исправления на телефоне: 🔊 → Выключить → Включить'
           when r.last_err is not null then 'Проверьте Edge Functions → push → Logs'
           when r.last_ok is null then 'Нажмите на телефоне 🔊 → «Проверить» или дождитесь теста ниже' else '' end;
  end loop;

  -- 5. тестовая отправка всем подключённым
  if p_send_test and has_net and coalesce(s,'') not in ('','CHANGE_ME') then
    perform net.http_post(url := u, headers := jsonb_build_object('Content-Type','application/json','x-push-secret',s), timeout_milliseconds := 8000,
      body := jsonb_build_array(jsonb_build_object('kind','test','to_roles',jsonb_build_array('boss','waiter','kitchen','bar','store'),'tag','check',
              'title','🔔 Проверка Niet Café','body','Если вы видите это при закрытом приложении — push работает ✅')));
    return query select '5. Тест отправлен'::text, '…'::text, 'всем подключённым телефонам'::text, 'Подождите 10 секунд и выполните:  select * from push_check();'::text;
  end if;

  -- 6. ответы функции push (pg_net хранит их несколько часов)
  if has_net and to_regclass('net._http_response') is not null then
    for r in execute 'select status_code, left(coalesce(content,error_msg,''''),160) c, timed_out, created from net._http_response order by created desc limit 5' loop
      nresp := nresp + 1;
      return query select '6. Ответ функции push · '||to_char(r.created at time zone 'Asia/Almaty','DD.MM HH24:MI:SS'),
        case when r.status_code = 200 and r.c !~ '"sent":0' then '✅' when r.status_code = 200 then '⚠' else '❌' end,
        coalesce(r.status_code::text,'нет ответа')||' · '||coalesce(r.c,''),
        case
          when r.timed_out or r.status_code is null then 'Функция не ответила. Проверьте, что она задеплоена (Edge Functions → push)'
          when r.status_code = 404 then 'Функция push не найдена: Edge Functions → Deploy new function → имя push → код из supabase/functions/push/index.ts'
          when r.status_code = 401 then 'Включена проверка JWT: Edge Functions → push → Details → выключите «Enforce JWT verification» (Verify JWT) → Save'
          when r.status_code = 403 then 'Секрет не совпадает: PUSH_SECRET в Edge Functions → Secrets и строка в push_cfg должны быть одинаковыми'
          when r.status_code >= 500 then 'Ошибка внутри функции: проверьте Secrets VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT и Logs функции'
          when r.c ~ '"sent":0' and r.c ~ '"dead":[1-9]' then 'Подписки устарели и удалены — на телефонах заново: 🔊 → «Включить уведомления»'
          when r.c ~ '"sent":0' then 'Функция работает, но получателей нет: у этой роли нет подключённых телефонов'
          else 'Сервер отправил. Если на телефоне не появилось — настройки телефона (см. PUSH_SETUP.md, шаг 5)' end;
    end loop;
    if nresp = 0 then
      return query select '6. Ответы функции push'::text, '…'::text, 'отправок ещё не было'::text,
        'Запустите тест:  select * from push_check(true);  через 10 секунд:  select * from push_check();'::text;
    end if;
  end if;
end $$;
revoke execute on function push_check(boolean) from public, anon;
grant execute on function push_check(boolean) to authenticated;

select * from push_check(true);
