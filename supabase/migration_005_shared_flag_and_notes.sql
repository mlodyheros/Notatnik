-- Notatnik — migracja 005: flaga "wspólny", potwierdzenie dołączania przez kod,
-- oraz notatniki typu "zwykła notatka" (bez kategorii/checklisty).
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.

-- ======================= FLAGA "WSPÓLNY" =======================
-- notatnik jest "wspólny" (widoczny w zakładce Wspólne właścicielowi), jeśli został
-- świadomie utworzony jako wspólny, albo ktoś już do niego dołączył/został zaproszony
alter table public.notebooks add column if not exists is_shared boolean not null default false;

-- ======================= TYP NOTATNIKA: checklista / zwykła notatka =======================
alter table public.notebooks add column if not exists type text not null default 'checklist';
alter table public.notebooks drop constraint if exists notebooks_type_check;
alter table public.notebooks add constraint notebooks_type_check check (type in ('checklist','note'));
alter table public.notebooks add column if not exists note_content text not null default '';

-- ======================= PODGLĄD NAZWY PRZED DOŁĄCZENIEM =======================
-- pozwala pokazać nazwę notatnika w oknie potwierdzenia PRZED faktycznym dołączeniem,
-- mimo że osoba dołączająca nie ma jeszcze dostępu (RLS) do odczytu tabeli notebooks
create or replace function public.get_notebook_name_by_code(code text)
returns text
language sql
security definer
set search_path = public
stable
as $$
  select name from public.notebooks where share_code = code;
$$;

-- dołączenie do notatnika po kodzie zaproszenia — teraz też oznacza notatnik jako wspólny
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
  update public.notebooks set is_shared = true where id = nb_id;
  return nb_id;
end;
$$;

-- wysłanie zaproszenia do notatnika — też oznacza notatnik jako wspólny (nawet zanim
-- zaproszony zaakceptuje), żeby właściciel od razu widział go w zakładce Wspólne
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
  update public.notebooks set is_shared = true where id = nb_id;
end;
$$;
