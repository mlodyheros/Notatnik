-- Notatnik — migracja 008: godzina przy terminie + powtarzanie pozycji.
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.
--
-- due_time: opcjonalna godzina obok due_date (z migration_006). recurrence: daily/weekly/monthly —
-- odhaczenie takiej pozycji w appce nie oznacza jej jako zrobionej, tylko przesuwa due_date
-- o kolejny cykl (patrz advanceRecurrence() w index.html).

alter table public.items add column if not exists due_time time;

alter table public.items add column if not exists recurrence text;
alter table public.items drop constraint if exists items_recurrence_check;
alter table public.items add constraint items_recurrence_check check (recurrence is null or recurrence in ('daily','weekly','monthly'));
