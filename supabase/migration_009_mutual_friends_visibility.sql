-- Notatnik — migracja 009: napraw liczenie wspólnych znajomych.
-- Uruchom w Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Dodatkowa, nieniszcząca danych migracja — bezpieczna do wielokrotnego uruchomienia.

-- Wcześniejsza reguła RLS pozwalała odczytać wiersz friend_requests tylko nadawcy/odbiorcy —
-- loadSuggestedFriends() musi jednak zobaczyć CAŁY graf zaakceptowanych znajomości (kto jest
-- znajomym kogo), żeby policzyć wspólnych znajomych z kandydatem, który nie jest ani nadawcą,
-- ani odbiorcą żadnego z tych wierszy z punktu widzenia zalogowanego użytkownika. Bez tego
-- liczba wspólnych znajomych zawsze wychodziła 0. Zaakceptowane znajomości traktujemy jak
-- profile (już w pełni publiczne dla zalogowanych, patrz "profiles: select all") — oczekujące
-- (pending) zaproszenia zostają prywatne, widoczne tylko dla nadawcy/odbiorcy.
drop policy if exists "friend_requests: select own" on public.friend_requests;
create policy "friend_requests: select own or accepted" on public.friend_requests
  for select using (status = 'accepted' or sender_id = auth.uid() or receiver_id = auth.uid());
