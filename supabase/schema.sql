-- Notatnik — schemat bazy danych dla Supabase (Postgres)
-- Uruchom całość w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Skrypt jest bezpieczny do ponownego uruchomienia (najpierw czyści poprzednią wersję).

create extension if not exists pgcrypto;

-- ======================= CZYSZCZENIE POPRZEDNIEJ WERSJI =======================

drop table if exists public.items cascade;
drop table if exists public.categories cascade;
drop table if exists public.notebook_members cascade;
drop table if exists public.notebooks cascade;
drop function if exists public.has_notebook_access(uuid) cascade;
drop function if exists public.join_notebook(text) cascade;

-- ======================= TABELE =======================

create table public.notebooks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  color text,
  archived boolean not null default false,
  share_code text unique not null default substr(md5(random()::text || clock_timestamp()::text), 1, 8),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- dodatkowi współedytorzy notatnika (właściciel jest już w notebooks.owner_id)
create table public.notebook_members (
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (notebook_id, user_id)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  name text not null,
  position integer not null default 0,
  collapsed boolean not null default false
);

create table public.items (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.categories(id) on delete cascade,
  text text not null,
  note text not null default '',
  qty text not null default '',
  priority boolean not null default false,
  checked boolean not null default false,
  position integer not null default 0
);

create index on public.notebook_members (user_id);
create index on public.categories (notebook_id);
create index on public.items (category_id);

-- ======================= DOSTĘP (RLS) =======================

-- czy zalogowany użytkownik ma dostęp do notatnika (jako właściciel lub zaproszony współedytor)
-- SECURITY DEFINER, żeby uniknąć rekurencji polityk RLS przy sprawdzaniu członkostwa
create or replace function public.has_notebook_access(nb_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists(
    select 1 from public.notebooks n where n.id = nb_id and n.owner_id = auth.uid()
  ) or exists(
    select 1 from public.notebook_members m where m.notebook_id = nb_id and m.user_id = auth.uid()
  );
$$;

-- dołączenie do notatnika po kodzie zaproszenia (link/kod) — SECURITY DEFINER,
-- bo osoba dołączająca z definicji jeszcze nie ma dostępu do odczytu notatnika
create or replace function public.join_notebook(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  nb_id uuid;
begin
  select id into nb_id from public.notebooks where share_code = code;
  if nb_id is null then
    raise exception 'Nieprawidłowy kod zaproszenia';
  end if;
  insert into public.notebook_members (notebook_id, user_id)
    values (nb_id, auth.uid())
    on conflict do nothing;
  return nb_id;
end;
$$;

alter table public.notebooks enable row level security;
alter table public.notebook_members enable row level security;
alter table public.categories enable row level security;
alter table public.items enable row level security;

create policy "notebooks: select own or shared" on public.notebooks
  for select using (owner_id = auth.uid() or has_notebook_access(id));
create policy "notebooks: insert own" on public.notebooks
  for insert with check (owner_id = auth.uid());
create policy "notebooks: update own or member" on public.notebooks
  for update using (owner_id = auth.uid() or has_notebook_access(id));
create policy "notebooks: delete own" on public.notebooks
  for delete using (owner_id = auth.uid());

create policy "members: select for accessible notebooks" on public.notebook_members
  for select using (has_notebook_access(notebook_id));
create policy "members: leave own membership" on public.notebook_members
  for delete using (user_id = auth.uid());

create policy "categories: select" on public.categories
  for select using (has_notebook_access(notebook_id));
create policy "categories: insert" on public.categories
  for insert with check (has_notebook_access(notebook_id));
create policy "categories: update" on public.categories
  for update using (has_notebook_access(notebook_id));
create policy "categories: delete" on public.categories
  for delete using (has_notebook_access(notebook_id));

create policy "items: select" on public.items
  for select using (has_notebook_access((select notebook_id from public.categories where id = category_id)));
create policy "items: insert" on public.items
  for insert with check (has_notebook_access((select notebook_id from public.categories where id = category_id)));
create policy "items: update" on public.items
  for update using (has_notebook_access((select notebook_id from public.categories where id = category_id)));
create policy "items: delete" on public.items
  for delete using (has_notebook_access((select notebook_id from public.categories where id = category_id)));

-- ======================= REALTIME =======================
-- włącza żywe aktualizacje (np. gdy znajomy edytuje wspólną listę)
alter publication supabase_realtime add table public.notebooks, public.categories, public.items, public.notebook_members;
