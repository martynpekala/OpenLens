# Pozostałe workflow OpenCode V2 — zadania warte wdrożenia

Stan: **ponowna ocena 2026-10-21**. Zastępuje podział z 2026-10-19 (21 ticketów). Baseline kodu bez zmian: `aa9932f` ma identyczne `OpenLens/` i `OpenLensTests/` jak `2d5a6b0`, więc **żadne z zadań nie jest jeszcze wdrożone** i `ENABLED.md` nie ma wpisów `next-workflows`.

Źródła oceny: [specyfikacja](OPENCODE_V2_NEXT_WORKFLOWS_SPEC.md), [porównanie funkcji](FEATURE_RESEARCH_OPENCODE_V2.md), [katalog API](OPENCODE_V2_API_RESEARCH.md), [snapshot OpenAPI](ResearchSources/opencode-v2-openapi-2026-10-19.json). Numery `NN` pozostają zgodne z plikami w [`.scratch/opencode-v2-next-workflows/issues/`](../../.scratch/opencode-v2-next-workflows/README.md); w pracy używać nazwy `next-workflows/NN`.

## Kryteria oceny

Zadanie zostaje w planie, jeśli spełnia co najmniej dwa z warunków i nie ma przeważającego ryzyka:

1. **Wartość na telefonie** — usuwa powód, by wracać do komputera, albo chroni przed błędną decyzją podjętą z telefonu.
2. **Gotowe fundamenty** — rozszerza istniejący ekran/usługę, zamiast budować nowy podsystem.
3. **Stabilny kontrakt** — endpoint poza `/api/experimental/`; eksperymentalny tylko z zachowanym fallbackiem.
4. **Koszt proporcjonalny do wartości** — bez nieatomowych kompozycji i destrukcyjnych efektów ubocznych.

## Wspólne kryteria każdego zadania

- Kompletna funkcja: kontrakt, istniejące usługi, kontrolki i stany produktu oraz testy zachowania. Brak kontroli UI nie oznacza pominięcia interfejsu.
- Swift Testing na granicy publicznych akcji ChatClient/usług, z podstawionym `OpenCodeTransport` i produkcyjną projekcją HTTP/SSE. Bez UI automation, screenshot acceptance i testów na żywym serwerze/tunelu.
- V1 bez zmian; dla V2 rozróżnione unsupported / not found / transport error; mutacja nigdy nie służy jako probe. Spóźnione odpowiedzi nie zmieniają innej sesji, lokalizacji ani porównania. Nie zakładać idempotencji POST.
- Architektura projektu: usługi przez `@Environment`, logika w `@Observable`, stan widoku w `@State`, bez ViewModel/Presenter. Ukrywanie tab bara zostaje na `NavigationStack` w `ConnectedRootView`.
- Weryfikacja: `./scripts/test-ios.sh` (iteracje z `--only-testing`, końcowo pełny suite).
- Po ukończeniu wpis do [ENABLED](../../.scratch/opencode-v2-completion/ENABLED.md) z prefiksem `next-workflows/NN`, efektem dla użytkownika i commitami.

## Etap 1 — małe zmiany o dużej wartości

### 12. Powód odrzucenia prośby o zgodę

**Blocked by:** brak.

**Dlaczego warto:** Najtańsza zmiana w całym planie — `session.permission.reply` (stabilny) przyjmuje już opcjonalne pole `message`, a `PermissionRequestSheet` i `ChatClient.respondToPermission` istnieją. Dziś „Reject” z telefonu zatrzymuje agenta bez informacji, co ma zrobić inaczej; użytkownik musi wysłać osobny prompt.

- Opcjonalna wiadomość trafia do pola `message` reply przy zachowaniu owning session/request.
- Odrzucenie bez wyjaśnienia działa jak dotąd; błąd zachowuje wpisany tekst do ponowienia.
- V1 nie otrzymuje nieobsługiwanego pola.

### 01. Otwieranie sesji subagenta

**Blocked by:** brak.

**Dlaczego warto:** Karty subagentów i ich wyniki są już w transcript rodzica (`SessionTranscript`, `V2SubagentResultTests`), ale nie da się zobaczyć faktycznej pracy dziecka. To największa luka nawigacyjna przy pracy z agentami delegującymi zadania; wymaga tylko `session.get` i istniejącej nawigacji sesji.

- Zweryfikowany child ID otwiera kanoniczną sesję; brak zasobu/dostępu daje czytelny błąd zamiast pustej rozmowy.
- Powrót zachowuje sesję rodzica, szkic i kontekst; permissions/forms należą do faktycznego właściciela.
- Spóźnione odpowiedzi nie zmieniają nowej sesji. Bez pełnego eksploratora drzewa.

### 04. Wyszukiwanie plików do załączenia (z 05: błąd i retry skills)

**Blocked by:** brak. 05 można dostarczyć osobno lub w tym samym przebiegu — dotyczy tego samego composera.

**Dlaczego warto:** Przeklikiwanie głębokich folderów to najbardziej uciążliwa czynność composera na telefonie. `fs.find` jest stabilny, a `RepositoryFilePicker`, walidacja zakresu linii i załączanie już działają. 05 to drobna poprawka tej samej powierzchni: `WorkspaceService.loadSkills` przy błędzie zwraca `[]`, więc awaria wygląda jak pusty katalog.

- Wyszukiwanie używa zweryfikowanej lokalizacji sesji i `fs.find`; nie obiecuje wyszukiwania treści kodu.
- Wynik przechodzi istniejący podgląd, walidację ścieżki/zakresu i załączanie; przeglądanie folderów pozostaje.
- Pusty wynik, brak obsługi i błąd są odrębne; stare query/location nie nadpisują wyników.
- (05) Katalog skills rozróżnia pusty sukces, błąd i brak obsługi; retry zachowuje szkic i wybrane skills.

### 14. Podsumowanie bez zmiany rozmowy

**Blocked by:** brak.

**Dlaczego warto:** Powrót do długiej sesji na telefonie to typowy scenariusz, a przewijanie historii na małym ekranie jest kosztowne. `session.generate` jest stabilny, ma prosty kontrakt (`prompt` → `text`) i nie mutuje historii — nie jest to kompaktacja pod nową nazwą.

- Wynik wyświetlany poza transcript, bez prompt admission i bez kompaktacji.
- Cache przypisany do sesji i rewizji transcriptu; ponowne otwarcie arkusza nie wywołuje modelu, odświeżenie jest jawne.
- Błąd nie zmienia rozmowy; UI oznacza tekst jako odpowiedź modelu (z kosztem), nie jako status wykonania.

## Etap 2 — kontrola nad pracą agenta

### 02. Fork całej rozmowy

**Blocked by:** brak.

**Dlaczego warto:** Fork pozwala spróbować innego podejścia bez niszczenia oryginału — dziś jedyną alternatywą jest nieodwracalny undo. `session.fork` jest stabilny. 02 dostarcza wspólny przepływ (odzyskiwanie, nawigacja, widoczność w katalogu), na którym opiera się 03.

- Fork bez `before` otwiera wynik z kanonicznymi ustawieniami, lokalizacją i lineage.
- Kontrakt opisuje wynik jako „child session”, a `SessionsService` ukrywa sesje z `parentID` — fork nie może zniknąć z katalogu ani być mylony z subagentem.
- UI wyjaśnia, że fork współdzieli pliki. Niepewny wynik POST nie powoduje automatycznego kolejnego forka.

### 03. Fork przed wybraną wiadomością

**Blocked by:** 02.

**Dlaczego warto:** To właściwy scenariusz „cofnij się i spróbuj inaczej” — bardziej użyteczny niż kopia całej historii, a koszt po 02 jest mały (jeden parametr `before` i akcja na wiadomości).

- Wybrany rekord jest wyłączną granicą `before`; UI jednoznacznie mówi, że ta wiadomość nie trafia do forka.
- Obsłużone pierwsza i środkowa granica oraz odrzucenie nieobsługiwanego rekordu.

### 13. Czytelne potwierdzenie undo (zakres zawężony)

**Blocked by:** brak.

**Dlaczego warto (w zawężonej formie):** Obecne `/undo` (`ChatClient.undo` → `OpenCodeClient.revertMessage`) od razu wykonuje `revert/stage` z `files: true` i `revert/commit` — bez wyjaśnienia, że zmienia pliki na dysku, i bez możliwości wyboru. To realne ryzyko przy decyzji z telefonu. Pełny cykl stage/clear/commit z obietnicą przywrócenia **nie wchodzi** w zakres: semantyka odtworzenia przez `clear` nie jest potwierdzona kontraktem, a dodatkowy stan „staged” komplikuje sesję bez proporcjonalnej korzyści.

- Przed wykonaniem użytkownik widzi granicę (od której wiadomości) i wybiera: tylko historia (`files: false`) albo historia + pliki.
- Komunikat uprzedza, że wariant z plikami zmienia dysk i nie jest podglądem.
- Busy, konflikt i utrata odpowiedzi kończą się kanonicznym odczytem sesji/diffu, a nie domniemanym sukcesem.

### 10. Przeglądanie i cofanie zapisanych zgód

**Blocked by:** brak.

**Dlaczego warto:** „Always” można dziś nadać z telefonu, ale nie można sprawdzić ani cofnąć — to luka bezpieczeństwa i zaufania. `permission.saved.list/remove` są stabilne; panel to prosta lista w istniejącym obszarze ustawień/inbox.

- Lista saved permissions w zakresie projektu z action/resource.
- Usunięcie odświeża kanoniczne reguły; błąd lub utrata odpowiedzi nie oznacza sukcesu.
- Opis rozróżnia przyszłe uprawnienia od cofnięcia już wykonanych operacji.

### 09. Review gałęzi i commitów z wyborem base

**Blocked by:** brak.

**Dlaczego warto:** Review to jeden z głównych ekranów, ale `getWorkingTreeDiff` pyta tylko o `mode=working` — po commicie agenta zmiany „znikają” z review. `vcs.diff` (`mode`, `base`), `vcs.base` i `vcs.branch.list` są stabilne, a prezentacja diffu istnieje.

- Tryby working / branch / committed z właściwą semantyką i istniejącą prezentacją.
- Niejasna lub niedostępna baza ma stan wyboru/błędu, nie pusty diff.
- Zmiana trybu, bazy lub lokalizacji unieważnia starszy wynik; session/turn review pozostają osobne.

## Etap 3 — skalowanie dużych katalogów i historii

### 06. Paginacja głównej listy sesji (z 07: wyszukiwanie)

**Blocked by:** brak (07 po 06).

**Dlaczego warto:** `SessionsListView` wywołuje `listAllSessions`, więc czas otwarcia rośnie z liczbą sesji — najbardziej odczuwalne na mobilnym łączu i przez tunel. Helpery stron (`listSessionsPage`) i wzorzec z pickera Review już istnieją. Lista nie ma dziś żadnego wyszukiwania, więc po wprowadzeniu stron 07 staje się jedynym sposobem dotarcia do starej sesji bez przewijania.

- (06) Pierwsza strona wyświetla się bez pobierania całości; wybór, outcome/viewed i załadowane wiersze przetrwają odświeżenie i błąd kolejnej strony; duplikaty, powtórzony cursor i strony bez root sessions są obsłużone.
- (07) Warunek: przed implementacją potwierdzić semantykę parametru `search` w `session.list` (OpenAPI go nie opisuje) i podać ten zakres w UI. Zmiana zapytania resetuje cursor; wyczyszczenie przywraca katalog.

### 08. Najnowszy transcript i starsze strony

**Blocked by:** brak.

**Dlaczego warto:** `listTranscript` pobiera wszystkie strony rosnąco przed pokazaniem czatu; kontekst, pliki narzędzi i wyniki subagentów zwiększają ten koszt. `session.message.list` obsługuje `order=desc` i cursor. To zadanie o najwyższym ryzyku w planie, dlatego jest po prostszych etapach.

- Początkowy odczyt to najnowsza strona; starsze wpisy dokładane ze stabilnym anchor i identyfikatorami, SSE w trakcie nie dubluje wpisów.
- Wiadomości, context entries, pliki narzędzi i wyniki subagentów zachowują porządek między stronami.
- Viewed dotyczy pokazanego wyniku. Insights (`SessionInsightsService.makeSnapshot` liczy z wiadomości czatu), undo i turn review nie traktują niepełnej historii jako kompletnej — osobny pełny odczyt albo jawne oznaczenie częściowych danych.

### 16. Statystyki i kalendarz aktywności z serwera (z 17)

**Blocked by:** brak.

**Dlaczego warto:** `SessionsService.loadActivityDays` pobiera listę sesji i transcript każdej pasującej sesji, by policzyć kalendarz — N żądań przy każdym otwarciu. Jedno wywołanie `experimental.session.stats` (`from`, `to`, `project`, `timezone`) zastępuje ten odczyt i daje koszt/modele z wielu sesji, czego Insights dziś nie pokazuje. Endpoint jest eksperymentalny, dlatego obecne liczenie zostaje jako fallback.

- Koszt, tokeny, modele i dni aktywności z jawnym zakresem i strefą czasową; zmiana filtra odrzuca stare odpowiedzi.
- Nieznany koszt nie jest zerem, parent/child nie są liczone podwójnie, dane nie udają billingu providera.
- Brak obsługi → obecne Insights/kalendarz z prawidłową etykietą zakresu.

## Etap 4 — izolowane zadania

### 20. Nowe zadanie w osobnym worktree

**Blocked by:** brak.

**Dlaczego warto:** Pozwala z telefonu uruchomić równoległe zadanie bez konfliktu plików z trwającą pracą — fork tego nie zapewnia. `worktree.list/create/refresh` są stabilne. Jest na końcu, bo tworzenie uruchamia skrypty setup projektu i wymaga obsługi częściowego sukcesu.

- Inventory/refresh, walidacja projektu i pól, utworzenie worktree, potem nowa sesja w zweryfikowanym katalogu.
- Postęp nie udaje procentów; błędy setup i brak wsparcia są jawne.
- Po częściowym sukcesie zostaje informacja o worktree i możliwość wznowienia etapu sesji — bez nowego katalogu i bez force cleanup.

## Kolejność i zależności

| Etap | Zadania | Zależności |
|---|---|---|
| 1 | 12, 01, 04 (+05), 14 | brak |
| 2 | 02 → 03, 13, 10, 09 | 03 po 02 |
| 3 | 06 (→ 07), 08, 16 (+17) | 07 po 06 |
| 4 | 20 | brak |

Etapy to kolejność produktowa, nie blokery: zadania bez zależności można realizować równolegle. Paginacja transcriptu nie czeka na stats, fork nie czeka na nawigację subagentów.

## Wycofane z planu

| NN | Zadanie | Powód |
|---|---|---|
| 11 | Edycja zapisanej reguły | Revoke (10) + ponowne „Always” daje ten sam efekt; edycja wzorców action/resource na telefonie jest niszowa, a PATCH ma konflikty duplikatów. |
| 15 | Move sesji z telefonu | Rzadki scenariusz mobilny; rebind po move z desktopu już działa. Samodzielna wartość pojawiała się głównie jako krok 21. |
| 18 | Niezawodność narzędzi w Insights | Diagnostyka dla dewelopera, nie decyzja podejmowana z telefonu; opiera się na eksperymentalnym `tools=detail`. |
| 19 | Eksport transcriptu | Eksperymentalny endpoint, ryzyko ujawnienia danych mimo `sanitize`, a handoff i archiwizacja i tak odbywają się na desktopie. |
| 21 | Fork w izolowanym worktree | Nieatomowa kompozycja trzech operacji zależna od 15; główną potrzebę pokrywa 20 + 03 wykonane kolejno. |

W lokalnym trackerze te tickety mają status `withdrawn`, a 05 i 17 — `merged into 04/16`; [indeks](../../.scratch/opencode-v2-next-workflows/README.md) odzwierciedla tę ocenę.
