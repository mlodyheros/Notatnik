-- Notatnik — migracja 007: kosz (miękkie usuwanie notatników).
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.

-- usunięty notatnik trafia do kosza (deleted_at ustawione) zamiast znikać od razu —
-- dopiero "Usuń na zawsze" w koszu robi prawdziwy delete z bazy
alter table public.notebooks add column if not exists deleted_at timestamptz;
