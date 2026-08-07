-- Notatnik — migracja 002: profile użytkowników, znajomi, awatary
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
--
-- W przeciwieństwie do schema.sql, ten plik NIE kasuje żadnych danych —
-- tylko dodaje nowe tabele/kolumny/zasady. Bezpieczny do wielokrotnego
-- uruchomienia (wszystkie operacje są idempotentne).

-- ======================= PROFILE =======================

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  avatar_url text,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles: zalogowani widzą wszystkie" on public.profiles;
create policy "profiles: zalogowani widzą wszystkie" on public.profiles
  for select to authenticated using (true);

drop policy if exists "profiles: user edytuje swój" on public.profiles;
create policy "profiles: user edytuje swój" on public.profiles
  for update using (id = auth.uid());

drop policy if exists "profiles: user tworzy swój" on public.profiles;
create policy "profiles: user tworzy swój" on public.profiles
  for insert with check (id = auth.uid());

-- automatyczne tworzenie profilu z domyślnym nickiem (część e-maila przed @) przy rejestracji
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base_username text;
  final_username text;
  suffix int := 0;
begin
  base_username := lower(regexp_replace(split_part(new.email, '@', 1), '[^a-zA-Z0-9_]', '', 'g'));
  if base_username = '' then base_username := 'user'; end if;
  final_username := base_username;
  while exists(select 1 from public.profiles where username = final_username) loop
    suffix := suffix + 1;
    final_username := base_username || suffix::text;
  end loop;
  insert into public.profiles (id, username) values (new.id, final_username)
    on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- uzupełnij profile dla kont, które już istniały przed tą migracją
insert into public.profiles (id, username)
select u.id, lower(regexp_replace(split_part(u.email, '@', 1), '[^a-zA-Z0-9_]', '', 'g'))
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;

-- ======================= ZNAJOMI =======================

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  constraint no_self_friend check (sender_id <> receiver_id),
  unique (sender_id, receiver_id)
);

alter table public.friend_requests enable row level security;

drop policy if exists "friend_requests: select own" on public.friend_requests;
create policy "friend_requests: select own" on public.friend_requests
  for select using (sender_id = auth.uid() or receiver_id = auth.uid());

drop policy if exists "friend_requests: insert own" on public.friend_requests;
create policy "friend_requests: insert own" on public.friend_requests
  for insert with check (sender_id = auth.uid());

drop policy if exists "friend_requests: update as receiver" on public.friend_requests;
create policy "friend_requests: update as receiver" on public.friend_requests
  for update using (receiver_id = auth.uid());

drop policy if exists "friend_requests: delete own" on public.friend_requests;
create policy "friend_requests: delete own" on public.friend_requests
  for delete using (sender_id = auth.uid() or receiver_id = auth.uid());

-- zaproszenie znajomego bezpośrednio do notatnika (zamiast linku) — tylko właściciel, tylko zaakceptowani znajomi
create or replace function public.invite_friend_to_notebook(nb_id uuid, friend_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists(select 1 from public.notebooks where id = nb_id and owner_id = auth.uid()) then
    raise exception 'Tylko właściciel może zapraszać do notatnika';
  end if;
  if not exists(
    select 1 from public.friend_requests
    where status = 'accepted'
      and ((sender_id = auth.uid() and receiver_id = friend_id) or (sender_id = friend_id and receiver_id = auth.uid()))
  ) then
    raise exception 'Możesz zapraszać tylko znajomych';
  end if;
  insert into public.notebook_members (notebook_id, user_id) values (nb_id, friend_id)
    on conflict do nothing;
end;
$$;

-- ======================= AWATARY (Storage) =======================

insert into storage.buckets (id, name, public)
  values ('avatars', 'avatars', true)
  on conflict (id) do nothing;

drop policy if exists "avatars: publiczny odczyt" on storage.objects;
create policy "avatars: publiczny odczyt" on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists "avatars: user wgrywa swój" on storage.objects;
create policy "avatars: user wgrywa swój" on storage.objects
  for insert with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars: user aktualizuje swój" on storage.objects;
create policy "avatars: user aktualizuje swój" on storage.objects
  for update using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "avatars: user usuwa swój" on storage.objects;
create policy "avatars: user usuwa swój" on storage.objects
  for delete using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ======================= REALTIME =======================

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'friend_requests'
  ) then
    alter publication supabase_realtime add table public.friend_requests;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profiles'
  ) then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;
