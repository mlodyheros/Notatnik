-- Notatnik — migracja 004: role członków notatnika (może edytować / tylko odczyt)
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.

alter table public.notebook_members add column if not exists role text not null default 'editor';
alter table public.notebook_members drop constraint if exists notebook_members_role_check;
alter table public.notebook_members add constraint notebook_members_role_check check (role in ('editor','viewer'));

-- czy zalogowany jest właścicielem notatnika (właściciel = pełne uprawnienia, w tym usuwanie i zarządzanie rolami)
create or replace function public.is_notebook_owner(nb_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists(select 1 from public.notebooks where id = nb_id and owner_id = auth.uid());
$$;

-- czy zalogowany może edytować zawartość notatnika (właściciel lub członek z rolą 'editor')
create or replace function public.has_notebook_edit_access(nb_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select is_notebook_owner(nb_id) or exists(
    select 1 from public.notebook_members
    where notebook_id = nb_id and user_id = auth.uid() and role = 'editor'
  );
$$;

-- notatnik (nazwa/kolor/archiwizacja): zmieniać może właściciel lub edytor, nie sam odczytujący
drop policy if exists "notebooks: update own or member" on public.notebooks;
create policy "notebooks: update own or member" on public.notebooks
  for update using (has_notebook_edit_access(id));

-- kategorie: czytać może każdy z dostępem, zmieniać tylko właściciel/edytor
drop policy if exists "categories: insert" on public.categories;
create policy "categories: insert" on public.categories
  for insert with check (has_notebook_edit_access(notebook_id));
drop policy if exists "categories: update" on public.categories;
create policy "categories: update" on public.categories
  for update using (has_notebook_edit_access(notebook_id));
drop policy if exists "categories: delete" on public.categories;
create policy "categories: delete" on public.categories
  for delete using (has_notebook_edit_access(notebook_id));

-- pozycje: czytać może każdy z dostępem, zmieniać tylko właściciel/edytor
drop policy if exists "items: insert" on public.items;
create policy "items: insert" on public.items
  for insert with check (has_notebook_edit_access((select notebook_id from public.categories where id = category_id)));
drop policy if exists "items: update" on public.items;
create policy "items: update" on public.items
  for update using (has_notebook_edit_access((select notebook_id from public.categories where id = category_id)));
drop policy if exists "items: delete" on public.items;
create policy "items: delete" on public.items
  for delete using (has_notebook_edit_access((select notebook_id from public.categories where id = category_id)));

-- role zmienia tylko właściciel notatnika
drop policy if exists "members: owner updates role" on public.notebook_members;
create policy "members: owner updates role" on public.notebook_members
  for update using (is_notebook_owner(notebook_id));

-- właściciel może też usuwać (wyrzucać) członków, nie tylko oni sami mogą opuścić notatnik
drop policy if exists "members: leave own membership" on public.notebook_members;
create policy "members: leave own membership" on public.notebook_members
  for delete using (user_id = auth.uid() or is_notebook_owner(notebook_id));
