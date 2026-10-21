# OpenCode V2 — pozostałe workflow mobilne

21 lokalnych ticketów opublikowanych 2026-10-19 na polecenie użytkownika „zapisz lokalnie”. **Ponowna ocena 2026-10-21:** 14 ticketów aktywnych (`ready-for-agent`), 2 scalone z innymi, 5 wycofanych. Żaden ticket nie jest jeszcze wdrożony: kod w `aa9932f` jest identyczny z baseline `2d5a6b0`.

Źródło: [specyfikacja](../../OpenLens/Playbook/OPENCODE_V2_NEXT_WORKFLOWS_SPEC.md). [Draft ticketów z uzasadnieniem oceny](../../OpenLens/Playbook/OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md). Numery user stories w aktywnych ticketach odnoszą się do specyfikacji z 2026-10-21; w ticketach wycofanych i scalonych zostały numery z wersji 2026-10-19.

## Wybór pracy

Pracuj nad dowolnym aktywnym ticketem, którego wszystkie blockery są ukończone. Etapy to kolejność produktowa, nie blokery.

**Ukończone (2026-10-21, etap 1):** 01, 04 (z 05), 12, 14 — commit `4c78f85`.

**Frontier (8 zadań):** 02, 06, 08, 09, 10, 13, 16, 20.

Po 02 odblokowuje się 03; po 06 — 07.

## Indeks aktywnych ticketów

| Etap | Numer | Ticket | Blocked by | Powiązanie ze starym backlogiem |
|---|---|---|---|---|
| 1 | 12 | [Powód odrzucenia prośby o zgodę](issues/12-explain-permission-rejection.md) | Brak | 25 (część) |
| 1 | 01 | [Otwieranie sesji subagenta](issues/01-open-child-session.md) | Brak | 23 |
| 1 | 04 | [Wyszukiwanie plików do załączenia (z 05: błąd i retry skills)](issues/04-search-repository-attachments.md) | Brak | 35, 05 (tylko aktualna luka) |
| 1 | 14 | [Podsumowanie bez zmiany rozmowy](issues/14-generate-session-summary.md) | Brak | nowy zakres |
| 2 | 02 | [Fork całej rozmowy](issues/02-fork-full-conversation.md) | Brak | 21 (część) |
| 2 | 03 | [Fork przed wybraną wiadomością](issues/03-fork-before-message.md) | 02 | 21 (część) |
| 2 | 13 | [Czytelne potwierdzenie undo (zakres zawężony)](issues/13-stage-clear-and-commit-undo.md) | Brak | 26 (tylko potwierdzenie) |
| 2 | 10 | [Przeglądanie i cofanie zapisanych zgód](issues/10-inspect-and-revoke-saved-permissions.md) | Brak | 25 (część) |
| 2 | 09 | [Review gałęzi i commitów z wyborem base](issues/09-review-branch-and-committed-changes.md) | Brak | 29 |
| 3 | 06 | [Paginacja głównej listy sesji](issues/06-page-main-session-list.md) | Brak | 31 |
| 3 | 07 | [Wyszukiwanie sesji na serwerze](issues/07-search-server-sessions.md) | 06 | rozszerzenie 31 |
| 3 | 08 | [Najnowszy transcript i starsze strony](issues/08-page-conversation-history.md) | Brak | 32 |
| 3 | 16 | [Statystyki i kalendarz aktywności z serwera (z 17)](issues/16-server-usage-statistics.md) | Brak | 33 (użycie i kalendarz) |
| 4 | 20 | [Nowe zadanie w osobnym worktree](issues/20-create-isolated-worktree-task.md) | Brak | 20 |

Ticket 07 wymaga przed implementacją potwierdzenia semantyki parametru `search` w `session.list` (OpenAPI jej nie opisuje).

## Scalone i wycofane — nie podejmować

| Numer | Ticket | Status | Powód |
|---|---|---|---|
| 05 | [Błąd i ponowienie ładowania skills](issues/05-retry-skill-catalog.md) | scalony z 04 | Ta sama powierzchnia composera; kryteria przeniesione do 04 |
| 17 | [Kalendarz aktywności ze statystyk](issues/17-server-activity-calendar.md) | scalony z 16 | Ten sam endpoint i odpowiedź; kryteria przeniesione do 16 |
| 11 | [Edycja zapisanej reguły](issues/11-edit-saved-permission.md) | wycofany | Cofnięcie (10) i ponowne „Always” daje ten sam efekt |
| 15 | [Przeniesienie sesji z telefonu](issues/15-move-session-from-phone.md) | wycofany | Rzadki scenariusz mobilny; rebind po move z desktopu już działa |
| 18 | [Niezawodność narzędzi w Insights](issues/18-tool-reliability-insights.md) | wycofany | Diagnostyka deweloperska, eksperymentalne `tools=detail` |
| 19 | [Eksport transcriptu sesji](issues/19-export-session-transcript.md) | wycofany | Eksperymentalny endpoint, ryzyko ujawnienia danych, handoff i tak odbywa się na desktopie |
| 21 | [Alternatywna rozmowa w izolowanym worktree](issues/21-fork-into-isolated-worktree.md) | wycofany | Nieatomowa kompozycja zależna od 15; 20 + 03 pokrywa potrzebę |

## Zasady weryfikacji

Testy zachowania przez publiczne akcje ChatClient i istniejących usług z podstawionym HTTP/SSE. Bez manualnych i automatycznych kontroli UI, screenshot acceptance i testów na żywym serwerze/tunelu. Każdy ticket nadal obejmuje implementację właściwego interfejsu produktu.

Po zmianach app/widget/test używać `./scripts/test-ios.sh`; iteracje można zawężać, końcowy przebieg obejmuje pełną suite. Symulator hostuje testy aplikacji.

## Relacja do wcześniejszego backlogu

[Poprzedni backlog](../opencode-v2-completion/README.md) pozostaje niezmieniony. Numery tego pakietu są niezależne od poprzednich numerów. Podczas pracy używać nazwy `next-workflows/NN`.

Dla zakresów wskazanych w tabeli ten pakiet jest aktualnym podziałem wykonawczym. Nie planować równolegle tej samej implementacji z pokrywającego się starego ticketu. Starsze wymagania gatewaya/UI/live testów nie obowiązują. Nie oznaczać starego ticketu done, dopóki jego rzeczywisty zakres nie zostanie rozstrzygnięty i wykonany.

Po ukończeniu ticketu wpis do [projektowego ENABLED](../opencode-v2-completion/ENABLED.md) powinien jednoznacznie wskazywać `next-workflows/NN`, efekt dla użytkownika i commity.

## Zakres i zależności

Nie jest wymagany szeroki refaktor przygotowawczy. Małe niezbędne uporządkowanie wykonać na początku właściwego ticketu; każdy ticket dostarcza pełny przebieg od kontraktu do interfejsu i testów.

Paginacja transcriptu nie zależy od stats: zachowuje osobny pełny odczyt analityczny lub jawnie oznacza częściowe pokrycie. Fork nie zależy od nawigacji subagentów. Odrzucenie permission z wiadomością nie zależy od panelu saved permissions.
