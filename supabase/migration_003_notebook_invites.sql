-- Notatnik — migracja 003: zaproszenia do notatników (zamiast automatycznego dodawania)
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.

create table if not exists public.notebook_invites (
  id uuid primary key default gen_random_uuid(),
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  notebook_name text not null,
  from_user_id uuid not null references auth.users(id) on delete cascade,
  to_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending')),
  created_at timestamptz not null default now(),
  unique (notebook_id, to_user_id)
);

alter table public.notebook_invites enable row level security;

drop policy if exists "notebook_invites: select own" on public.notebook_invites;
create policy "notebook_invites: select own" on public.notebook_invites
  for select using (from_user_id = auth.uid() or to_user_id = auth.uid());

drop policy if exists "notebook_invites: delete own" on public.notebook_invites;
create policy "notebook_invites: delete own" on public.notebook_invites
  for delete using (from_user_id = auth.uid() or to_user_id = auth.uid());

-- notebook_name jest zapisany "na sztywno" w chwili zaproszenia, żeby zaproszony
-- (który jeszcze nie ma dostępu do notatnika) mógł zobaczyć jego nazwę bez
-- omijania RLS na tabeli notebooks

-- wyślij zaproszenie do notatnika (zamiast dodawać od razu) — tylko właściciel, tylko zaakceptowani znajomi
create or replace function public.invite_friend_to_notebook(nb_id uuid, friend_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  nb_name text;
begin
  select name into nb_name from public.notebooks where id = nb_id and owner_id = auth.uid();
  if nb_name is null then
    raise exception 'Tylko właściciel może zapraszać do notatnika';
  end if;
  if not exists(
    select 1 from public.friend_requests
    where status = 'accepted'
      and ((sender_id = auth.uid() and receiver_id = friend_id) or (sender_id = friend_id and receiver_id = auth.uid()))
  ) then
    raise exception 'Możesz zapraszać tylko znajomych';
  end if;
  if exists(select 1 from public.notebook_members where notebook_id = nb_id and user_id = friend_id) then
    raise exception 'Ta osoba już jest w notatniku';
  end if;
  insert into public.notebook_invites (notebook_id, notebook_name, from_user_id, to_user_id)
    values (nb_id, nb_name, auth.uid(), friend_id)
    on conflict (notebook_id, to_user_id) do update set notebook_name = excluded.notebook_name;
end;
$$;

-- zaakceptuj zaproszenie: dodaje do notebook_members i usuwa wpis zaproszenia
create or replace function public.accept_notebook_invite(invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  inv record;
begin
  select * into inv from public.notebook_invites where id = invite_id and to_user_id = auth.uid();
  if inv is null then
    raise exception 'Zaproszenie nie istnieje albo już zostało obsłużone';
  end if;
  insert into public.notebook_members (notebook_id, user_id) values (inv.notebook_id, auth.uid())
    on conflict do nothing;
  delete from public.notebook_invites where id = invite_id;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notebook_invites'
  ) then
    alter publication supabase_realtime add table public.notebook_invites;
  end if;
end $$;
