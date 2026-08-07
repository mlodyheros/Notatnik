-- Notatnik — migracja 006: tagi notatników, terminy pozycji, załączniki zdjęciowe.
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.

-- ======================= TAGI NOTATNIKA =======================
alter table public.notebooks add column if not exists tags text[] not null default '{}';

-- ======================= TERMIN POZYCJI =======================
alter table public.items add column if not exists due_date date;

-- ======================= ZAŁĄCZNIKI (zdjęcia) =======================
-- item_id = null oznacza załącznik przypisany do całej notatki (nie do konkretnej pozycji)
create table if not exists public.attachments (
  id uuid primary key default gen_random_uuid(),
  notebook_id uuid not null references public.notebooks(id) on delete cascade,
  item_id uuid references public.items(id) on delete cascade,
  url text not null,
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id) on delete cascade
);

create index if not exists attachments_notebook_id_idx on public.attachments (notebook_id);
create index if not exists attachments_item_id_idx on public.attachments (item_id);

alter table public.attachments enable row level security;

drop policy if exists "attachments: select" on public.attachments;
create policy "attachments: select" on public.attachments
  for select using (has_notebook_access(notebook_id));

drop policy if exists "attachments: insert" on public.attachments;
create policy "attachments: insert" on public.attachments
  for insert with check (has_notebook_edit_access(notebook_id) and created_by = auth.uid());

drop policy if exists "attachments: delete" on public.attachments;
create policy "attachments: delete" on public.attachments
  for delete using (has_notebook_edit_access(notebook_id));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'attachments'
  ) then
    alter publication supabase_realtime add table public.attachments;
  end if;
end $$;

-- ======================= STORAGE: ZAŁĄCZNIKI =======================
-- pliki trzymane pod ścieżką "<notebook_id>/<uuid>.<ext>" — pierwszy segment ścieżki
-- to notebook_id, sprawdzany w politykach poniżej, tak samo jak przy avatarach
insert into storage.buckets (id, name, public)
  values ('attachments', 'attachments', true)
  on conflict (id) do nothing;

drop policy if exists "attachments: publiczny odczyt" on storage.objects;
create policy "attachments: publiczny odczyt" on storage.objects
  for select using (bucket_id = 'attachments');

drop policy if exists "attachments: edytor wgrywa" on storage.objects;
create policy "attachments: edytor wgrywa" on storage.objects
  for insert with check (
    bucket_id = 'attachments'
    and has_notebook_edit_access(((storage.foldername(name))[1])::uuid)
  );

drop policy if exists "attachments: edytor usuwa" on storage.objects;
create policy "attachments: edytor usuwa" on storage.objects
  for delete using (
    bucket_id = 'attachments'
    and has_notebook_edit_access(((storage.foldername(name))[1])::uuid)
  );
