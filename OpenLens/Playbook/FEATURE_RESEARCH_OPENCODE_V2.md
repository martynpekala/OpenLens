# OpenLens — ponowne porównanie funkcji z OpenCode v2

Data: 2026-10-19. Branch: `feature/super-cool-new-features`.
Badany HEAD: `2d5a6b0072da0770bbb8bc96a37fe1b96b0c6bd5`.
Poprzedni punkt odniesienia: `e02672a6e6b6271a31ffdbbe57dd99bda821db89`.
Stan: ponowne porównanie ukończone; ustalenia zapisano etapami.

## Najważniejsza korekta

Poprzedni ranking obejmował już wdrożone na tym branchu funkcje. Trwała kolejka, obrazy i pliki w promptach, wyniki i nieprzeczytane sesje, zdarzenia kontekstu oraz podgląd kontekstu/kompaktacja nie powinny być planowane od zera. Skills również istnieją w composerze.

Usunięto własny gateway OpenLens Remote, `OpenLensRemoteCore` i narzędzia `Tools/`. Obecny README i pairing obsługują połączenie zdalne przez tunel OpenCode (`opencode pair --remote`). Stara allowlista i limit body gatewaya nie są zależnościami tego brancha. Lokalne limity załączników nadal wymagają sprawdzenia niezależnie od tego usunięcia.

## Metoda i zachowane źródła

Porównanie statyczne kodu, połączenia UI → usługa → klient HTTP oraz istniejących testów. `done` w ticketach jest informacją pomocniczą, nie samodzielnym dowodem działania na żywym serwerze. Nie uruchomiono w tej aktualizacji aplikacji ani testów. API porównano do wcześniej utrwalonej oficjalnej specyfikacji z 2026-10-19; nie wykonywano ponownego researchu upstream.

- [Poprzedni raport — archiwum](FEATURE_RESEARCH_OPENCODE_V2_BASELINE_e02672a.md).
- [Katalog API](OPENCODE_V2_API_RESEARCH.md).
- [Snapshot OpenAPI](ResearchSources/opencode-v2-openapi-2026-10-19.json).
- [Rejestr wykonanych ticketów](../../.scratch/opencode-v2-completion/ENABLED.md).
- [Backlog projektu](../../.scratch/opencode-v2-completion/README.md).

Snapshot nie był obecny w nowym checkout; odtworzono go z zachowanej kopii lokalnej po sprawdzeniu zgodności SHA-256 `27de5afb635ac3f3be48f930d50716e11a6c46a5ac36fc24ad8eea1e6e3281a9`. Nie jest to nowy download ani nowa wersja kontraktu.

## Co z poprzednich 25 propozycji jest nadal aktualne

Numery w pierwszej kolumnie odnoszą się do **poprzedniego raportu**, nie numerów ticketów. „Wdrożone” oznacza odnaleziony przepływ w kodzie, nie nową weryfikację live. „Częściowo” oznacza konkretną istniejącą część — reszta jest wskazana osobno.

| # | Propozycja | Stan tego brancha | Co pozostaje |
|---|---|---|---|
| 1 | Trwała kolejka: restore, cancel, queue → steer | **Wdrożone** | Weryfikacja na żywym serwerze z desktopem i telefonem; nie implementować ponownie |
| 2 | Obrazy i pliki w promptach | **Wdrożone** | Realny odbiór obrazów przez model; ewentualnie Share Extension. Limity istnieją już po stronie klienta |
| 3 | Fork rozmowy | **Brak** | Endpoint, wybór granicy historii, wejście do nowej sesji i relacja rodzic/dziecko; ticket 21 |
| 4 | Wyniki od ostatniej wizyty i nieprzeczytane | **Rdzeń wdrożony** | Oddzielny zbiorczy ekran „od ostatniej wizyty” pozostaje pomysłem UX; outcome/viewed/badge już są |
| 5 | Podsumowanie bez mutowania historii | **Brak** | `session.generate` + arkusz wyniku/cache; poza obecnym backlogiem |
| 6 | Pliki, fragmenty, skills i referencje w composerze | **Częściowo, większość podstaw jest** | Są obrazy, tekst, repo file + line range i skills; brak `fs.find`, katalogu `reference` i czytelnego błędu ładowania skills |
| 7 | Oś zdarzeń kontekstu | **Wdrożone** | Nie planować od zera; jest oddzielna projekcja context entries i wyniki subagentów |
| 8 | Podgląd aktywnego kontekstu i kompaktacja | **Wdrożone** | Jest arkusz, przybliżenie użycia oraz statusy kompaktacji; pozostaje live verification |
| 9 | Saved permissions | **Brak panelu** | List/update/remove zapisanych reguł; obecnie obsługiwane są pending requests; ticket 25 |
| 10 | Globalne stats | **Brak endpointu** | Insights nadal liczy wiadomości sesji lokalnie; ticket 33 |
| 11 | Review branch/committed/base | **Częściowo** | Review rozbudowano, ale API VCS wciąż pyta o working; tryby branch/committed i base nadal ticket 29 |
| 12 | Tworzenie worktree | **Brak** | Wybór istniejącego folderu/projektu nie tworzy worktree; ticket 20 |
| 13 | Drzewo subagentów i forków | **Częściowo** | Są karty i wyniki dzieci w rodzicu; brak otwierania child session/drzewa; ticket 23 |
| 14 | Server search i duże katalogi sesji | **Częściowo** | Paginacja działa w pickerze Review; główna lista ładuje wszystkie sesje, chat całą historię. Search brak; tickets 31/32 |
| 15 | Eksport/import sesji | **Brak** | Eksport v2 ticket 30; import osobny zakres. Eksport diagnostycznego replay to inna funkcja |
| 16 | Status integracji i logowanie providera | **Brak zarządzania integracjami** | Model picker już jest; integration status/login nadal tickets 27/28 |
| 17 | Panel MCP i zasoby | **Częściowo tylko formularze** | Globalne formularze MCP już działają; katalog/status/add/remove MCP nie; ticket 27 częściowo pokrywa diagnostykę |
| 18 | Log shell / terminal read-only | **Częściowo tylko timeline** | Shell wpisy i output w historii istnieją; brak shell output API oraz terminal/read |
| 19 | Terminal interaktywny | **Brak** | PTY transport/emulator/UX nadal osobny projekt; własny gateway nie jest już blockerem |
| 20 | Przenoszenie sesji | **Częściowo** | Rebind po move z desktopu jest; rozpoczęcia move na telefonie brak; ticket 22 |
| 21 | Tagi/notatki w metadata i trwałe instrukcje | **Brak authoringu** | Wyświetlanie zmian kontekstu nie jest edycją metadata/instructions |
| 22 | Realtime voice | **Brak** | Broker voice + audio/sterowanie sesją; osobny spike |
| 23 | Edytor plików | **Brak zapisu** | Odczyt, załączanie i preview już są; `fs.write` i rozwiązywanie konfliktów nie |
| 24 | Diagnostyka pluginów/konfiguracji | **Częściowo tylko informacja o serwerze** | Ekran support pokazuje wersję/protokół, ale nie plugin/integration health/update |
| 25 | Push/harmonogramy/twardy budżet | **Brak infrastruktury** | Live Activity/intenty nie gwarantują aktualizacji przy zamkniętej aplikacji; osobny projekt |

## Dowody dla największych zmian od poprzedniej analizy

| Funkcja | UI / logika | Klient / testy istniejące w repo |
|---|---|---|
| Shared inbox i akcje | `ChatView.swift:2613,2998`, `ChatClient.swift:3832,3851,3928` | `OpenCodeClient.swift:548,559,571`; `V2SessionInboxTests.swift` |
| Potwierdzenie admission i retry | `ChatClient.swift:3592,3600,3629` | `OpenCodeClient.swift:587`; `V2PromptAdmissionTests.swift` |
| Zdjęcia i tekst z Files | `ChatView.swift:790,797`, `PromptAttachment.swift:7,52`, `PromptImagePreparer.swift` | `OpenCodeClient.swift:456`; `V2PromptImageAttachmentTests.swift`, `V2PromptFileAttachmentTests.swift` |
| Pliki repo + zakres linii | `Views/Workspace/RepositoryFilePicker.swift`, `PromptAttachment.swift:100` | `V2PromptFileAttachmentTests.swift` |
| Skills | `ChatView.swift:927,1363`, `WorkspaceService.swift:418`, `SkillMention.swift` | `OpenCodeClient.swift:777`; `SkillMentionTests.swift` |
| Outcome i unread | `SessionsListView.swift:354,364`, `ChatClient.swift:2077,2126`, `ExecutionStatusView.swift` | `OpenCodeClient.swift:266`; `V2ExecutionOutcomeTests.swift`, `V2SessionViewedTests.swift`, `SessionOutcomeRefreshTests.swift` |
| Oś kontekstu | `SessionTranscript.swift:4,45`, `ChatView.swift:2736`, `SessionContextTimelineRow.swift` | `OpenCodeClient.swift:336`; `V2ContextTimelineTests.swift` |
| Aktywny kontekst | `SessionActiveContextView.swift`, `ChatClient.swift:1066` | `OpenCodeClient.swift:311`; `V2ActiveContextTests.swift` |
| Kompaktacja | `SessionCompactionControls.swift`, `ChatClient.swift:3739,3777` | `OpenCodeClient.swift:525`; `V2CompactionTests.swift` |
| Podsumowania subagentów w rodzicu | `SessionTranscript.swift:60`, karty aktywności i wpisy synthetic | `V2SubagentToolTests.swift`, `V2SubagentResultTests.swift` |
| Pliki zwracane przez narzędzia | `ToolResultFile.swift`, `ToolResultFileViews.swift`, `ToolResultFileBudget.swift` | `V2ToolFileContentTests.swift` |
| Formularze warunkowe/globalne | `FormView.swift`, `InteractiveFormSafety.swift`, `InboxService.swift:7,113`, `InboxRootView.swift` | `OpenCodeClient.swift:1130,1185`; `OpenCodeV2FormTests.swift` |
| Zmiana lokalizacji z innego klienta | `ChatClient.swift:1761`, odzyskiwanie katalogów i stanu composera | `V2SessionLocationTests.swift` |
| Paginowany picker Review | `ReviewRootView.swift:403,429`, `ReviewSessionPicker.swift:90` | `SessionsService.swift:81`, `OpenCodeClient.swift:133`; `OpenCodePaginationTests.swift` |

Ścieżki UI/service/model są względne do `OpenLens/Views`, `OpenLens/Services` lub `OpenLens/Models` zgodnie z nazwą; testy znajdują się w `OpenLensTests/`. Numery linii odnoszą się wyłącznie do badanego HEAD.

### Korekta załączników i połączeń zdalnych

Wcześniejszy raport błędnie sugerowałby teraz, że usunięcie gatewaya znosi wszystkie ograniczenia rozmiaru. Nadal jest **2 MiB na body promptu**, lecz ustalone lokalnie przez `OpenCodeClient.maximumPromptBodyBytes` (`OpenCodeClient.swift:449`). Klient koduje docelowy JSON, uwzględnia base64/escaping i waliduje rozmiar; obrazy są przygotowywane/zmniejszane przed wysłaniem. Nie potrzeba ponownie implementować tej podstawowej ochrony.

Tunel OpenCode jest częścią obecnego pairing/setup (`README.md:86` i `OpenCodePairingClient.swift`), a nie przywróceniem `OpenLensRemoteCore`. Podczas przyszłych wdrożeń trzeba testować aktualny URL/tunel, TLS/auth, zrywanie połączeń i realne ograniczenia proxy, lecz nie projektować zmian do usuniętej allowlisty. W tym porównaniu nie sprawdzano live działania tunelu.

### Korekta podsumowań i kontekstu

Podsumowanie **kompaktacji** już jest widoczne; nadal brak pomocniczego `session.generate`, które tworzy odpowiedź bez dopisywania do historii. To różne funkcje. Nie proponować „kompaktacji” pod nową nazwą jako brakującej.

`ChatClient.contextUsageSummary` (`:1020`) korzysta z ostatniej wiadomości z usage po kompaktacji i oznacza wartość v2 jako przybliżoną (`isApproximate`). Stare zalecenie, by nie sumować całej historii jako context occupancy, ma już odpowiednik w kodzie. Dalsza dokładność pomiaru wymaga kontraktu serwera, nie dodania samej etykiety procentowej.

### Korekta paginacji

Są już `listSessionsPage`, serwis i paginowany dropdown Review. Ticket 31 nie oznacza braku wszelkiej paginacji. Nadal jednak `SessionsListView.loadSessions` (`:435`) wywołuje `listAllSessions`, a `OpenCodeClient.listTranscript` (`:336`) pobiera wszystkie strony w porządku rosnącym. Rzeczywista pozostała praca to główna lista, zachowanie podczas odświeżenia i najnowsza strona czatu przed starszą historią.

### Dodatkowa drobna luka w skills

Katalog/mentions/chips istnieją. `WorkspaceService.loadSkills` (`:418`) przy błędzie loguje problem i zwraca `[]`, więc UI nie rozróżnia pustego katalogu od nieudanego ładowania. Warto dodać stan błędu i retry w istniejącym przepływie; nie jest potrzebny nowy picker ani „wdrożenie skills” od zera.

### Funkcje mobilne, które także już są

`OpenLensShortcuts.swift` definiuje `NewSessionIntent` z nazwą sesji i App Shortcut, a `PendingAppActions` pozwala obsłużyć żądanie po otwarciu aplikacji. Nie proponować podstawowego „utwórz sesję przez Siri/Shortcuts” jako zupełnie nowej funkcji. Rozszerzenia o wybrany workspace/prompt pozostają możliwe.

`LiveActivityIntents.swift` ma approve/deny i quick reply; to nie jest dowód istnienia APNs ani gwarantowanego strumienia aktualizacji w tle. Te dwie rzeczy należy wyceniać osobno.

## Rekomendowana kolejność prac (ocena 2026-10-21)

Ponowna ocena pakietu `next-workflows` po scaleniu brancha (`aa9932f`): kod aplikacji i testów jest identyczny z `2d5a6b0`, więc żadne z zadań nie zostało jeszcze wdrożone. W planie zostały tylko zadania warte wdrożenia; pełne uzasadnienie i kryteria odbioru są w [drafcie ticketów](OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md), a decyzje techniczne w [specyfikacji](OPENCODE_V2_NEXT_WORKFLOWS_SPEC.md).

| Etap | Zadanie (`next-workflows/NN`) | Dlaczego warto |
|---|---|---|
| 1 | 12 Powód odrzucenia zgody | Pole `message` w stabilnym reply już istnieje; sterowanie agentem z telefonu bez osobnego promptu |
| 1 | 01 Otwieranie sesji subagenta | Karty i wyniki dzieci już są; brakuje tylko przejścia do faktycznej pracy |
| 1 | 04 Wyszukiwanie plików (+05 retry skills) | Stabilny `fs.find` na istniejącym pickerze; `loadSkills` dziś maskuje błąd jako pusty katalog |
| 1 | 14 Podsumowanie `session.generate` | Szybki powrót do długiej sesji na małym ekranie; stabilny, prosty kontrakt bez mutacji historii |
| 2 | 02 → 03 Fork (całość, potem przed wiadomością) | Alternatywa bez niszczenia oryginału; jedyną obecną drogą jest nieodwracalny undo |
| 2 | 13 Potwierdzenie undo z zakresem | `/undo` od razu stage(`files: true`) + commit; wybór „tylko historia / z plikami” i ostrzeżenie. Bez pełnego cyklu stage/clear |
| 2 | 10 Przegląd i cofanie zapisanych zgód | „Always” można nadać z telefonu, ale nie można go sprawdzić ani cofnąć |
| 2 | 09 Review branch/committed z base | Review pyta tylko o `mode=working`, więc zacommitowana praca agenta znika z review |
| 3 | 06 Paginacja listy (→ 07 search) | `listAllSessions` przy każdym otwarciu; search tylko po potwierdzeniu semantyki parametru |
| 3 | 08 Najnowsza strona transcriptu | Pobieranie całej historii przed wyświetleniem; najwyższe ryzyko (Insights, undo, review) |
| 3 | 16 Stats i kalendarz z serwera (+17) | Kalendarz czyta transcript każdej sesji; eksperymentalny endpoint z obecnym liczeniem jako fallback |
| 4 | 20 Nowe zadanie w worktree | Równoległa praca bez konfliktu plików; setup scripts i częściowy sukces wymagają najwięcej pracy |

Wycofane z planu: 11 (edycja reguły), 15 (move z telefonu), 18 (niezawodność narzędzi), 19 (eksport), 21 (fork w worktree) — powody w drafcie ticketów.

Równolegle z wybranym etapem warto wykonać rzeczywisty test desktop + telefon dla już wdrożonych kolejek, attachmentów, viewed, formularzy i zmiany lokalizacji. Rejestr `ENABLED.md` przy wielu ticketach jawnie zaznacza brak takiej weryfikacji. To walidacja istniejących funkcji, nie powód do ich ponownego projektowania.

## Backlog i stare notatki wymagają ostrożnej interpretacji

1. **Ticket 05 „skills through Remote” jest nadal `ready-for-agent`, mimo że dotyczy usuniętej architektury.** Nie oznacza to, że skills brakuje — katalog i composer są. Sensowny następny zakres to błąd/retry katalogu oraz weryfikacja aktualnego połączenia; gateway checklist trzeba przeformułować lub wycofać w osobnej decyzji.
2. **Ticket 12 ma `done`, ale zamknięto go jako superseded po usunięciu narzędzi.** Nie dostarcza działającego launchera TUI. Rejestr wyraźnie to opisuje.
3. **Historyczne wpisy 13–15 w ENABLED wspominają własny Remote.** Są świadectwem wcześniejszego wdrożenia, nie dowodem obecności gatewaya w tym HEAD.
4. **Tickets 31/32 pozostają otwarte, chociaż helpery paginacji już istnieją.** Zakres do wykonania to docelowe główne ekrany, nie cały klient stronicowania od zera.
5. **Nowe pomysły poza trackerem**, np. `session.generate`, metadata/instructions, import czy terminal, wymagają osobnego zakresu. Nie przypisywać ich arbitralnie do już zamkniętych ticketów.

W ramach tego porównania nie zmieniono statusu żadnego ticketu ani `ENABLED.md` i nie wpisano nowych commitów implementacyjnych. Raport nie jest oznaczeniem implementacji jako zakończonej.

## Ograniczenia weryfikacji i aktualne źródła

Przeczytano bieżący kod app/model/service/UI/testów, różnice wobec starego commita, README, indeks ticketów i rejestr ENABLED. Testy wymienione w tabeli **istnieją**, ale nie były uruchamiane w tym researchu. Podobnie historyczne wyniki testów/screenshoty w ENABLED nie są nowym wynikiem weryfikacji dla HEAD `2d5a6b0`.

Zmiany obejmują tylko Markdown i przywrócony publiczny snapshot JSON. Nie zmieniono UI, kodu aplikacji, widgetu ani testów. Przy przyszłych zmianach kodu aktualnym poleceniem weryfikacji jest **`./scripts/test-ios.sh`**, zgodnie z nowym AGENTS.md, z końcowym pełnym przebiegiem. Dawne bezpośrednie `xcodebuild` z archiwalnego raportu nie jest instrukcją dla tego brancha.

Najważniejsze pliki do dalszej pracy:

- [OpenCodeClient](../Services/OpenCodeClient.swift) — istniejące requesty oraz brakujące operacje z rankingu.
- [ChatClient](../Services/ChatClient.swift) — kolejka, admission, kontekst, viewed, rebind i compaction.
- [SessionsService](../Services/SessionsService.swift) i [SessionsListView](../Views/SessionsListView.swift) — root filtering, wyniki i pełne pobranie katalogu.
- [SessionTranscript](../Models/SessionTranscript.swift) — osobna oś kontekstu oraz wyniki subagentów.
- [WorkspaceService](../Services/WorkspaceService.swift) — istniejące skills, repo files i wybór lokalizacji.
- [ReviewRootView](../Views/Review/ReviewRootView.swift) — paginacja pickera i istniejący review.
- [ENABLED](../../.scratch/opencode-v2-completion/ENABLED.md) — historyczne granice verification każdego ticketu.
- [Oficjalny kontrakt API](https://dev.opencode.ai/v2/openapi.json) i [lokalny katalog](OPENCODE_V2_API_RESEARCH.md) — podstawa możliwości upstream; ta aktualizacja nie sprawdzała ponownie strony online.

## Wynik aktualizacji

Queue, attachments, timeline, context/compact oraz outcome/viewed istnieją — utrzymać i zweryfikować integracyjnie. Kolejny pakiet to etap 1 powyżej: **powód odrzucenia zgody, sesje dzieci, wyszukiwanie plików i podsumowanie `session.generate`**, a następnie fork, bezpieczniejsze undo, zapisane zgody i branch review.
