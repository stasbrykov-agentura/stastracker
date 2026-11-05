-- Стастрекер: схема базы данных.
-- Выполнить один раз: Supabase → SQL Editor → New query → вставить всё → Run.

-- 1. Таблица записей: категории, проекты, задачи и контексты в одной таблице.
create table if not exists public.records (
  id                uuid primary key,
  owner_id          uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind              text not null check (kind in ('folders','projects','tasks','contexts')),
  data              jsonb not null default '{}'::jsonb,
  field_ts          jsonb not null default '{}'::jsonb,   -- время правки каждого поля (мс), для «последняя правка побеждает»
  updated_at        bigint not null default 0,            -- время последней правки на устройстве (мс)
  deleted           boolean not null default false,
  server_updated_at timestamptz not null default now()    -- курсор синхронизации
);

create index if not exists records_owner_sync_idx on public.records (owner_id, server_updated_at);

-- 2. Курсор синхронизации обновляется сервером при каждой записи.
create or replace function public.records_touch() returns trigger
language plpgsql as $$
begin
  new.server_updated_at := clock_timestamp();
  return new;
end $$;

drop trigger if exists records_touch on public.records;
create trigger records_touch before insert or update on public.records
for each row execute function public.records_touch();

-- 3. Доступ: каждый пользователь видит и меняет только свои записи.
alter table public.records enable row level security;

drop policy if exists "records_select_own" on public.records;
drop policy if exists "records_insert_own" on public.records;
drop policy if exists "records_update_own" on public.records;
drop policy if exists "records_delete_own" on public.records;

create policy "records_select_own" on public.records for select to authenticated using (owner_id = auth.uid());
create policy "records_insert_own" on public.records for insert to authenticated with check (owner_id = auth.uid());
create policy "records_update_own" on public.records for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "records_delete_own" on public.records for delete to authenticated using (owner_id = auth.uid());

-- 4. Отправка изменений с устройства. Сливает по каждому полю:
--    побеждает значение с более поздним временем правки этого поля.
create or replace function public.push_records(items jsonb) returns setof public.records
language plpgsql security invoker set search_path = public as $$
declare
  it  jsonb;
  cur public.records;
  k   text;
  nd  jsonb;
  nts jsonb;
begin
  for it in select value from jsonb_array_elements(items) loop
    select * into cur from public.records where id = (it->>'id')::uuid for update;
    if not found then
      insert into public.records (id, owner_id, kind, data, field_ts, updated_at, deleted)
      values (
        (it->>'id')::uuid, auth.uid(), it->>'kind',
        coalesce(it->'data','{}'::jsonb), coalesce(it->'field_ts','{}'::jsonb),
        coalesce((it->>'updated_at')::bigint,0), coalesce((it->'data'->>'deleted')::boolean,false)
      )
      returning * into cur;
    else
      nd  := cur.data;
      nts := cur.field_ts;
      for k in select jsonb_object_keys(coalesce(it->'field_ts','{}'::jsonb)) loop
        if coalesce((nts->>k)::bigint,0) < coalesce((it->'field_ts'->>k)::bigint,0) then
          nd  := jsonb_set(nd,  array[k], coalesce(it->'data'->k, 'null'::jsonb), true);
          nts := jsonb_set(nts, array[k], it->'field_ts'->k, true);
        end if;
      end loop;
      -- поля без отметки времени (id, createdAt) заполняются, только если их ещё нет
      nd := coalesce(it->'data','{}'::jsonb) - (select coalesce(array_agg(x), '{}') from jsonb_object_keys(nd) x) || nd;
      update public.records
        set data = nd,
            field_ts = nts,
            deleted = coalesce((nd->>'deleted')::boolean,false),
            updated_at = greatest(cur.updated_at, coalesce((it->>'updated_at')::bigint,0))
        where id = cur.id
        returning * into cur;
    end if;
    return next cur;
  end loop;
end $$;

revoke all on function public.push_records(jsonb) from public, anon;
grant execute on function public.push_records(jsonb) to authenticated;

-- 5. Мгновенные обновления между устройствами.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'records'
  ) then
    alter publication supabase_realtime add table public.records;
  end if;
end $$;
