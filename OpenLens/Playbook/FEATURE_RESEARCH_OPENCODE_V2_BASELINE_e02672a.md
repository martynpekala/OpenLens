> ARCHIWUM: stan commita `e02672a`; nie opisuje obecnego brancha. Aktualne porównanie: [FEATURE_RESEARCH_OPENCODE_V2.md](FEATURE_RESEARCH_OPENCODE_V2.md).

# OpenLens — możliwości rozwoju na OpenCode v2

Data: 2026-10-19. Stan: ukończone; ustalenia zapisywano etapami.
Badany commit OpenLens: `e02672a6e6b6271a31ffdbbe57dd99bda821db89`.

## Jak czytać raport

Raport porównuje aktualny kod aplikacji z oficjalnym API OpenCode v2. Dokument `API_V2_MIGRATION_PLAN.md` jest historycznym planem, nie opisem obecnego stanu. OpenLens już obsługuje v2. Propozycje produktowe i priorytety są oceną autora, nie obietnicą upstreamu. Szczegółowy katalog źródeł i kontraktów znajduje się w [OPENCODE_V2_API_RESEARCH.md](OPENCODE_V2_API_RESEARCH.md).

## Zapis 1 — stan aplikacji potwierdzony w kodzie

Nie warto planować ponownej implementacji poniższych funkcji:

| Obszar | Co już istnieje | Dowód lokalny |
|---|---|---|
| Rozpoznawanie protokołu | Probe `/api/info`, v1 fallback przy 404/405, osobne zdarzenia v2 | `Services/OpenCodeClient.swift`, `Models/OpenCodeProtocol.swift` |
| Sesje | Lista, utworzenie, odczyt, tytuł, usunięcie, status aktywności, przerwanie | `Services/OpenCodeClient.swift:85–200` |
| Rozmowa | Wiadomości, strumieniowanie, queue i steer, slash commands, zmiana agenta/modelu | `Services/ChatClient.swift`, `Services/OpenCodeClient.swift` |
| Pytania i zgody | Uprawnienia, formularze v2, odpowiedź i anulowanie formularza | `Services/InboxService.swift`, `Services/QuestionService.swift`, `Views/Components/FormView.swift` |
| Review | Diff sesji/tury, working tree, staged revert + commit | `Services/ReviewService.swift`, `Views/Review/ReviewRootView.swift` |
| Workspace | Foldery, treść plików, projekty, kontekst katalogu, zmienione pliki | `Services/WorkspaceService.swift`, `Views/Workspace/WorkspaceRootView.swift` |
| Git przez agenta | Zmiana brancha, push i utworzenie PR przez prompt do sesji | `Views/Workspace/WorkspaceRootView.swift:1110–1203` |
| Insights | Koszt i tokeny bieżącej sesji, modele, drogie odpowiedzi | `Services/SessionInsightsService.swift` |
| Łączność | LAN, pairing OpenCode v2, szyfrowany Remote z allowlistą | `Services/OpenCodePairingClient.swift`, `Services/OpenCodeTransport.swift`, `Tools/openlens-qr-menubar/RemoteSources/OpenCodeForwarder.swift` |
| Aktywność | Live Activities, Inbox, kalendarz aktywności | `Services/LiveActivityManager.swift`, `Services/SessionsService.swift` |

Istotne ograniczenia obecnego produktu:

- `OpenCodeOptionalFeature` wyłącza dla v2 todo, udostępnianie sesji i synchroniczny prompt. Trzeba odróżnić brak endpointu od funkcji, którą aplikacja może zbudować lokalnie, np. eksport rozmowy.
- `queuedPrompts` jest stanem klienta; sama możliwość wysłania `queue` nie oznacza pełnego zarządzania serwerową kolejką po restarcie telefonu.
- Insights oblicza dane z przekazanych `ChatMessage`; nie stanowi jeszcze serwerowego zestawienia kosztów wszystkich projektów.
- Wybór projektu/folderu nie jest tym samym co tworzenie i zarządzanie workspace przez API.
- README jawnie opisuje brak push i aktualizacji Live Activity, kiedy aplikacja jest zamknięta. Sam SSE nie usuwa tego ograniczenia.
- Zmiana gałęzi/push/PR jest dziś poleceniem dla agenta, nie deterministycznym klientem endpointów Git.

## Dalsze kroki badania

1. Potwierdzenie pełnej powierzchni aktualnego HTTP API i źródeł implementacji.
2. Macierz luk: istniejące / częściowe / nowe / wymagające dodatkowej infrastruktury.
3. Konkretne pomysły produktowe, zakres MVP, ryzyka, priorytety i kolejność wdrożenia.
4. Oddzielenie natywnego API od pomysłów wymagających narzędzia, pluginu lub backendu.

## Zapis 2 — ranking możliwości produktowych

Źródłem API dla poniższych propozycji jest [oficjalny OpenAPI JSON](https://dev.opencode.ai/v2/openapi.json), pobrany 2026-10-19. Dokładne ścieżki i pola są rozpisane w [katalogu](OPENCODE_V2_API_RESEARCH.md). Wszystkie operacje należą do eksperymentalnej powierzchni v2; prefiks `/experimental` oznacza dodatkowo jawnie eksperymentalną grupę. Oceny wartości i nakładu są moją oceną dla obecnego OpenLens. S = małe rozszerzenie istniejącego ekranu, M = nowy przepływ lub kilka integracji, L = nowy podsystem/transport. Nie są to estymacje w dniach.

| # | Propozycja | Stan w OpenLens | Wartość | Nakład | Priorytet |
|---|---|---|---|---|---|
| 1 | Trwała kolejka: odczyt, anulowanie, queue → steer | Samo wysyłanie już jest | Bardzo duża | M | P0 |
| 2 | Screenshoty, zdjęcia i pliki w promptach | Prompt DTO ma tylko id/text/delivery | Bardzo duża | M | P0 |
| 3 | Fork rozmowy od wybranego miejsca | Brak endpointu i akcji | Duża | M | P0 |
| 4 | „Co wydarzyło się od mojej ostatniej wizyty?” + nieprzeczytane | Aktywność już jest, pełne viewed/outcome nie | Bardzo duża | M | P0 |
| 5 | Skrót sesji / wyjaśnienie diffu bez dopisywania do rozmowy | Brak generate | Duża | S–M | P0 |
| 6 | Dobór kontekstu: pliki, fragmenty, skills, referencje | Foldery i commands już są | Bardzo duża | M | P1 |
| 7 | Pełna oś zdarzeń sesji | Adapter zachowuje user/assistant | Duża | M | P1 |
| 8 | Podgląd kontekstu i ręczna kompaktacja | Brak endpointów w kliencie | Duża | M | P1 |
| 9 | Kontrola zapisanych zgód „always” | Są tylko bieżące zgody | Duża | S–M | P1 |
| 10 | Globalne koszty, aktywność, niezawodność narzędzi | Tylko lokalne Insights sesji | Duża | M | P1 |
| 11 | Review branch / committed + wybór base | Working diff i session diff już są | Duża | S–M | P1 |
| 12 | Worktree: lista, tworzenie, sesja w izolowanym katalogu | Wybór katalogu już jest | Duża | L | P1 |
| 13 | Drzewo subagentów i forków | Lista główna filtruje sesje dzieci | Duża | M | P1 |
| 14 | Wyszukiwanie sesji po stronie serwera | Klient pobiera strony listy | Średnia/duża | S–M | P1 |
| 15 | Eksport/import rozmów | Brak v2 export/import | Średnia/duża | M | P1 |
| 16 | Status integracji i ponowne logowanie | Lista modeli/providerów już jest | Duża | L | P2 |
| 17 | Panel MCP i katalog zasobów | Brak endpointów MCP | Średnia/duża | M–L | P2 |
| 18 | Logi uruchomień shell i terminal tylko do odczytu | Karty narzędzi już są | Duża | M | P2 |
| 19 | Interaktywny terminal | Brak transportu PTY | Zależna od odbiorcy | L | P2 |
| 20 | Przeniesienie sesji do innego katalogu | Jest przełączenie kontekstu aplikacji | Średnia/duża | M–L | P2 |
| 21 | Tagi/piny/notatki sesji we własnych metadata | Brak obsługi pola | Średnia | M | P2 |
| 22 | Głos na żywo | Brak voice transport | Potencjalnie duża | L | P3 / spike |
| 23 | Prosty edytor plików | Jest odczyt | Średnia | L | P3 |
| 24 | Diagnostyka pluginów i konfiguracji | Brak panelu | Średnia | M | P2 |
| 25 | Push, harmonogramy i twarde limity budżetu | Brak odpowiedniego natywnego API | Bardzo duża | L + infrastruktura | Osobny projekt |

P0 oznacza rekomendowany pierwszy etap produktu, nie krytyczny błąd.

### 1. Trwała kolejka poleceń

**Problem użytkownika:** wysyła kilka poleceń, zamyka aplikację i po powrocie chce wiedzieć, co rzeczywiście czeka na serwerze. Chce też anulować pomyłkę lub przekazać pilną korektę.

**API:** `GET /api/session/{sessionID}/inbox`, `DELETE .../inbox/{inboxID}`, `PATCH .../inbox/{inboxID}` z `delivery`. Lista zawiera niedostarczone elementy w kolejności przyjęcia: user, synthetic, compaction i move. Zmiana na steer budzi wykonanie sesji.

**MVP:** panel „Oczekujące” w czacie, odtwarzany z REST po wejściu/reconnect; akcje „Anuluj” i „Przekaż teraz”. Pozostawić istniejące queue/steer w composerze. Nazwać panel inaczej niż obecny Inbox zgód/formularzy lub wyraźnie oddzielić sekcje.

**Granice:** PATCH nie edytuje tekstu i nie przyjmuje dowolnego priorytetu ani pozycji. Nie obiecywać drag-and-drop reorder. „Popraw treść” wymaga cancel + nowy prompt, co nie jest atomowe. W trakcie dotknięcia element może już zostać wykonany. Anulowanie niedostępnego elementu jest no-op, więc UI musi odświeżyć stan.

**Integracja:** rozszerzyć `OpenCodeClient`, `MessagesService`, `ChatClient`; `queuedPrompts` traktować jako optymistyczną projekcję serwerowego inbox. Rozszerzyć allowlistę Remote dla trzech tras i sprawdzać własność sesji.

**Kryterium odbioru:** polecenie wysłane na komputerze pojawia się na telefonie; restart aplikacji nie gubi kolejki; anulowanie nie usuwa już wykonanej wiadomości.

### 2. Załączniki z iPhone'a i iPada

**Scenariusze:** „Napraw layout ze screenshota”, zdjęcie błędu na monitorze, diagram, plik tekstowy z aplikacji Files. To szczególnie mocna funkcja mobilna.

**API:** `files` w prompt/command; URI `data:` dla danych telefonu, `file:` dla pliku dostępnego na serwerze. Fragment tekstu można wskazać parametrami `start`/`end` w `file:`. HTTP(S) nie jest obsługiwanym URI załącznika. Formatami przekazywanymi do modelu są UTF-8 i PNG/JPEG/GIF/WebP; SVG jest tekstem. PDF, audio i video nie trafiają bezpośrednio do modelu w tym mechanizmie. Dokumentacja podaje limit 20 MiB po dekodowaniu na element; to nie limit produktu OpenLens. [Załączniki OpenCode](https://dev.opencode.ai/v2/docs/attachments).

**MVP:** photo picker + Files, miniatury, usuwanie przed wysłaniem, rozmiar, rozpoznanie możliwości wybranego modelu. PDF można później jawnie konwertować do tekstu/obrazów. Share Extension to kolejny etap, nie warunek pierwszego wydania.

**Ważny lokalny blocker:** `OpenLensRemoteCore/RemoteProtocol.swift` ogranicza HTTP body do **2 MiB**, a wiadomość wire do **4 MiB**. Base64 rośnie około 4/3, więc obraz ~1,5 MiB przed kodowaniem już pozostawia zbyt mały margines na JSON przy limicie 2 MiB. Potrzebne kompresowanie/skalowanie i wspólny jawny limit liczony z gotowego payloadu, a nie podnoszenie samych limitów UI.

**Integracja:** dodać pola do `OCV2PromptInput`; klient command obsługuje już tablice files/agents/skills, lecz obecny flow composera korzysta z ich pustych wartości domyślnych. Dla `file:` sprawdzić, czy ścieżka mieści się w zatwierdzonym workspace Remote — sama walidacja endpointu nie wystarcza, bo ścieżka jest w body.

**Kryterium odbioru:** ten sam obraz działa przez LAN i Remote, brak cichego pominięcia PDF, zmiana na model bez image input daje czytelny komunikat przed kosztownym wywołaniem.

### 3. Fork i alternatywne rozwiązania

**API:** `POST /api/session/{sessionID}/fork` z opcjonalnym `before`. Bez niego kopiuje pełną projekcję historii; z nim historię **przed** wskazaną wiadomością. Wynik to nowa sesja potomna.

**MVP:** „Spróbuj inaczej od tego miejsca” na wiadomości oraz „Duplikuj rozmowę” na sesji. Po fork przejść do nowego czatu z informacją o pochodzeniu; zachować łatwy powrót do oryginału.

**Granice:** fork historii nie jest klonem stanu plików. Do porównania dwóch agentów zmieniających kod potrzebne są osobne worktree; dwa forki we wspólnym katalogu mogą nadpisywać te same pliki. Testować semantykę `before`, nie nazywać jej „łącznie z tą wiadomością”.

**Lokalnie:** `SessionsService` filtruje root sessions po `parentID`; nowy fork może zniknąć z obecnej listy. Rozszerzenie nawigacji/drzewa jest częścią tej funkcji.

### 4. Powrót do pracy: wynik, nieprzeczytane, co wymaga reakcji

**API:** `Session.Info.outcome` (`succeeded`, `failed`, `interrupted`), `time.idle`, `time.viewed`, aktywne sesje oraz `POST /api/session/{sessionID}/view` z `idle`.

**MVP:** ekran „Od ostatniej wizyty”: zakończone z powodzeniem, błędy, wymagane zgody/formularze; badge nieprzeczytanej zakończonej tury. Przy odczycie zgłosić dokładny obserwowany `idle`, aby nie oznaczyć przypadkiem kolejnej, niewidzianej tury.

**Wartość:** telefon staje się narzędziem nadzoru, nie tylko drugim oknem czatu. Jest to rozwinięcie istniejącego Inbox i aktywności, a nie ich zamiennik.

**Granice:** outcome nie gwarantuje przejścia testów ani jakości kodu. `succeeded` opisać jako zakończenie wykonania. SSE po rozłączeniu wymaga odczytu REST. Ta funkcja działa po powrocie do aplikacji i sama nie daje push w tle.

### 5. Pomocnicze podsumowania bez zmieniania rozmowy

**API:** `POST /api/session/{sessionID}/generate` z `prompt` generuje tekst z kontekstu sesji bez mutowania jej historii. Osobno `/api/experimental/generate` daje generację bez sesji.

**MVP:** „Podsumuj dotychczasową pracę”, „Co mam teraz sprawdzić?”, „Wyjaśnij ostatnią zmianę”. Wynik w arkuszu, możliwość kopiowania; dołączenie do rozmowy tylko jawną akcją użytkownika. Podsumowanie cache'ować według wersji/ostatniej wiadomości, żeby otwieranie ekranu nie generowało kolejnych kosztów.

**Granice:** brak zmiany historii nie oznacza darmowego wywołania. To odpowiedź modelu, a nie deterministyczny raport statusu. Bazować na aktualnym kontekście, nie obiecywać pamięci całej historii sprzed kompaktacji. Treść do wyjaśnienia, np. wybrany diff, może wymagać przekazania w prompt.

### 6. Jawny wybór kontekstu i katalog skills

**API:** `GET /api/fs/find`, `/api/reference`, `/api/skill`; prompt przyjmuje `files`, `agents`, `skills`. Dodatkowo jest eksperymentalne dołączenie skill do sesji.

**MVP:** przycisk „Dodaj kontekst” z wyszukiwaniem plików i listą skills; chips pokazujące, co trafi do następnego polecenia. W pliku akcja „Zapytaj o ten fragment”. Skills pokazywać z opisem, podglądem treści i ścieżką/źródłem, bez zakładania marketplace instalacyjnego.

**Granice:** `fs.find` wyszukuje wpisy filesystemu; nie obiecywać pełnotekstowego grep kodu. Referencje mogą być ukryte (`hidden`) lub poza obecnym katalogiem: potrzebna polityka ekspozycji. Samo wystąpienie nazwy agenta w tekście nie zastępuje strukturalnego `agents`.

**Integracja:** wykorzystać istniejące listy folderów i slash actions. Obsługa plików, skills i agentów powinna przechodzić przez jeden composer dla prompt i command.

### 7. Pełna oś zdarzeń

**Potwierdzona luka:** `OCV2...asMessage` w `ServerModels.swift` mapuje `user` i `assistant`, a dla innych typów zwraca `nil`. Aktualna unia API zawiera również agent-selected, model-selected, location-switched, synthetic, system, skill, shell, compaction i idle.

**MVP:** lekkie wpisy „Zmieniono model”, „Zmieniono katalog”, „Dołączono skill”, „Skompaktowano kontekst”, „Przerwano”. Szczegóły techniczne zwijane. Jest to ważne przy sesji używanej jednocześnie z desktopu i telefonu.

**Granice:** nie renderować wszystkich wariantów jak wiadomości asystenta; wiadomości systemowe mogą ujawniać wewnętrzny kontekst. Zachować obsługę nieznanych typów, stabilne ID i spójną kolejność REST/SSE. Najpierw dodać model domenowy zdarzeń, dopiero potem nowe elementy UI.

### 8. Kontekst i kompaktacja

**API:** `GET /api/session/{sessionID}/context` zwraca aktywne wiadomości po ostatniej kompaktacji; `POST .../compact` przyjmuje opcjonalne `id` i `delivery`.

**MVP:** panel „Kontekst rozmowy”, informacja o ostatniej kompaktacji, ręczne „Skróć kontekst”, stan w toku/zakończone/błąd. Metryki tokenów pokazać osobno od szacunku zajęcia okna kontekstu.

**Semantyka:** odpowiedź HTTP potwierdza przyjęcie, nie ukończenie. Kompaktacja odbywa się w bezpiecznym punkcie; jest stratna. Idempotentne `id` pomaga przy ponowieniu po utracie połączenia. [Dokumentacja kompaktacji](https://dev.opencode.ai/v2/docs/compaction).

**Granice:** suma historycznych tokenów zużycia nie jest aktualnym rozmiarem context window. Endpoint context nie obiecuje gotowego procentu zajęcia. Nie pokazywać precyzyjnego „87%” bez odpowiedniej podstawy.

## Zapis 3 — dalsze funkcje i warunki wdrożenia

### 9. Panel trwałych zgód

**API:** `GET /api/permission/saved?projectID=...`, `PATCH /api/permission/saved/{id}` (`action`, `resource`), `DELETE /api/permission/saved/{id}`; opcjonalnie reguły sesji w create/update.

**MVP:** „Na co agent ma już zgodę?” z filtrem projektu, wzorcem zasobu, akcją i możliwością cofnięcia. Przy odpowiedzi „always” link do tego panelu. Jest to naturalne dopełnienie istniejących promptów uprawnień.

**Granice:** cofnięcie reguły nie cofa już wykonanej operacji. Uprawnienia zapisane dla projektu nie są tym samym co globalny dostęp do serwera. Nie nadawać masowo szerokich uprawnień tylko po to, by zmniejszyć liczbę dotknięć. W Remote endpointy globalne wymagają filtrowania przez dozwolone projekty.

### 10. Insights dla całej pracy

**API:** `GET /api/experimental/session/stats` z `from`, `to`, `project`, `timezone`, `tools=none|summary|detail`. Dane obejmują sesje, subagentów, prompty, kroki, koszt, tokeny, aktywne dni, streak, aktywność, użycie modeli oraz wywołania narzędzi. Narzędzia mają liczniki succeeded/failed/unfinished i opcjonalną medianę czasu.

**MVP:** tydzień/miesiąc/projekt, koszt i tokeny, aktywność, najczęściej zawodzące narzędzia. Rozszerzyć istniejące Insights, a nie budować osobną sekcję tylko dlatego, że API jest inne. Parametr strefy czasowej jest istotny przy kalendarzu.

**Granice:** statystyki dotyczą lokalnych danych tego serwera, nie rachunku całego konta u providera. Nie obiecywać salda subskrypcji, limitów dostawcy lub „oszczędności” bez dodatkowego źródła. Koszt 0 przy modelu/subskrypcji nie oznacza braku kosztów użytkownika.

**Remote:** endpoint agreguje ponad sesjami. Samo dopuszczenie ścieżki może ujawnić dane projektów spoza rejestru. MVP może wymagać jednego dozwolonego `project` na zapytanie; agregacja wszystkich zatwierdzonych projektów po stronie gateway/app musi unikać podwójnego liczenia.

### 11. Review całej gałęzi

**API:** `GET /api/vcs/branch`, `/api/vcs/base`, `/api/vcs/diff?mode=working|branch|committed&base=...&context=...`; session diff ma `from`, `to`, `context`.

**MVP:** segmenty „Niecommitowane”, „Cała gałąź”, „Commity”; wybór branch bazowego, więcej linii kontekstu. Obecna aplikacja prosi o `mode=working`; infrastruktura wyświetlania diffów już istnieje.

**Semantyka:** working porównuje HEAD z working copy, branch merge-base z working copy, committed merge-base z HEAD. To pozwala odpowiedzieć „Co naprawdę trafi do PR?”, także gdy część zmian jest już zacommitowana.

**Granice:** brak natywnych endpointów stage/commit/push/merge/PR w tym kontrakcie. Nie sugerować ich jako prostego dodania REST. Obecne prompty agenta dla push/PR pozostają uzasadnione. „Zastosuj pojedynczy hunk” nie wynika z API diffu.

### 12. Izolowane zadania w worktree

**API:** `GET/POST/DELETE /api/worktree`, `POST /api/worktree/refresh`; create ma `projectID`, opcjonalnie `from`, `branch`, `directory`, `name`; remove wymaga `force`.

**MVP:** lista worktree projektu, „Nowe zadanie w osobnym worktree”, utworzenie sesji w zwróconym katalogu. Następny etap: fork historii do tej lokalizacji i porównanie rezultatów. Zaczynać od list/create; destructive cleanup może poczekać.

**Granice:** list zwraca zapisany inventory; refresh uruchamia odkrywanie. Create ładuje konfigurację kanoniczną i uruchamia setup script. To nie operacja wyłącznie UI i może trwać/błądzić. `from` ma typ ścieżki absolutnej — nie traktować go jak dowolnego Git SHA. Usuwanie z `force` wymaga osobnej, czytelnej decyzji użytkownika produktu.

**Remote:** utworzony katalog często wyjdzie poza aktualnie zatwierdzony root. Trzeba określić, jak gateway autoryzuje nowe worktree i ich sesje; nie rozszerzać arbitralnie dostępu do całego home. W planie implementacji uwzględnić rejestr workspace, filtrowanie list i zdarzeń, setup scripts oraz obsługę częściowego sukcesu „worktree powstało, sesja nie”.

**Ważne rozróżnienie:** nowy worktree nie jest ogólnym CRUD `/api/workspace`. Stare katalogi operacji nie są miarodajnym kontraktem HTTP. [Audyt upstream](https://github.com/anomalyco/opencode/blob/dev/V2_HTTP_API_AUDIT.md).

### 13. Drzewo subagentów i wariantów rozwiązania

**API:** parentID w session, filtr `parentID` w liście; fork ma dodatkową informację o źródle i granicy.

**MVP:** sekcja „Zadania potomne” w czacie: nazwa, aktywność, outcome, koszt, przejście do historii. Rozróżnić sesję utworzoną przez subagenta i fork użytkownika na podstawie rzeczywistych danych, nie samego parentID.

**Wartość:** zrozumienie, dlaczego zadanie trwa i co można już przejrzeć. Obecne `AgentActivityCard` pokazuje aktywność narzędzia; pełne drzewo uzupełnia je o nawigację.

**Granice:** samo API listowania nie daje schedulerowi OpenLens kontroli nad całym drzewem. Przerwanie rodzica nie powinno być w UI opisywane jako gwarantowane zatrzymanie wszystkich potomków bez testu kontraktu. Koszt rodzica i dziecka może mieć różną semantykę agregacji — zapobiec podwójnemu liczeniu.

### 14. Wyszukiwanie i duże archiwum sesji

**API:** lista sesji obsługuje `search`, `parentID`, `directory`, `project`, `subpath`, `order`, `limit`, `cursor`; lista wiadomości ma `type`, `order`, `cursor`, `limit`.

**MVP:** wyszukiwanie server-side, filtry projektu i potomków, lazy pagination; pozycja na liście zachowana po powrocie. W czacie „Przejdź do poprzednich wiadomości” zamiast wymagania pełnego transcriptu od razu.

**Granice:** nie reklamować `search` jako wyszukiwania treści wszystkich rozmów, dopóki implementacja tego nie potwierdzi. Serwerowa paginacja nie daje automatycznie cache offline. Należy ustalić, które ekrany rzeczywiście potrzebują wszystkich stron: kalendarz/Insights mogą używać stats, a lista jedynie bieżącej strony.

### 15. Eksport i przenoszenie sesji

**API:** `GET /api/experimental/session/{sessionID}/export?sanitize=...`, `POST /api/experimental/session/import` (`info`, `messages`, opcjonalna `location`).

**MVP:** „Eksportuj rozmowę” do JSON przez systemowy share sheet; później Markdown generowany przez aplikację, a import początkowo jako zaawansowana akcja z wyborem serwera/katalogu.

**Granice:** eksport dotyczy projected transcriptu. Nie jest backupem repozytorium, credentiali, pełnego event logu ani wszystkich plików. Należy sprawdzić dokładną semantykę sanitize, a wynik pokazać do kontroli przed wysłaniem poza urządzenie. Nie obiecywać publicznego linku share: takiego endpointu brak. Większy transcript może przekroczyć obecny limit 2 MiB odpowiedzi Remote; wymaga strategii rozmiarów/transportu.

**Wartość:** użytkownik nie traci historii i może przekazać kontekst współpracownikowi lub zgłosić błąd. Import wymaga testów kolizji ID, wersji kontraktu i mapowania lokalizacji.

### 16. Integracje i logowanie do providerów

**API:** integration list/get, connect key/external/oauth/command; OAuth/command mają attempt status i cancel, OAuth ma complete. Provider get udostępnia więcej niż obecny model picker.

**MVP:** panel „Dlaczego model jest niedostępny?” ze stanem integracji i kontrolowanym rozpoczęciem ponownego logowania. Najpierw odczyt + link do właściwego procesu; następnie natywny flow start → autoryzacja → polling → complete, z obsługą wyjścia z aplikacji.

**Granice:** callback OAuth do localhost komputera nie jest localhost telefonu. Przetestować typy auth oferowane przez konkretną integrację; nie obiecywać, że każdy provider połączy się całkowicie z iPhone'a. Flow `command` uruchamia proces na serwerze.

**Szczególnie ważne:** opis `GET /api/credential` jawnie mówi, że zwraca również wartości sekretów. Nie używać go jako zwykłego źródła nazw kont na ekranie; panel statusu oprzeć na integracjach albo zbudować świadomą redakcję po stronie gateway. Nie logować raw payloadu auth. Nie jest to hipotetyczne ryzyko, lecz cecha aktualnego kontraktu.

### 17. Panel MCP

**API:** `GET /api/mcp`, `GET /api/mcp/resource`, eksperymentalne add/remove/connect/disconnect.

**MVP:** status skonfigurowanych serwerów, przyczyna problemu, reconnect i katalog zasobów/templates. Użytkownik widzi, czy agent ma dostęp do potrzebnego systemu.

**Granice:** obecny HTTP kontrakt nie zawiera ogólnego `mcp.tool.call`, `mcp.prompt.render` ani `mcp.resource.read` z dawnych indeksów. Katalog zasobów nie oznacza możliwości odczytu każdego zasobu przez osobny REST. Zarządzanie konfiguracją lokalnego MCP może uruchamiać programy na komputerze; oddzielić status od administratora konfiguracji. [Dokumentacja MCP](https://dev.opencode.ai/v2/docs/mcp-servers).

**Później:** predefiniowane, konkretne akcje przez plugin RPC lub agenta. Ogólny `/api/rpc/{rpcID}/{method}` wymaga zainstalowanego pluginu i jego własnego kontraktu; nie jest standardową biblioteką gotowych funkcji.

### 18. Logi zadań i terminal tylko do odczytu

**API:** `GET /api/shell`, `GET /api/shell/{id}`, `GET /api/shell/{id}/output` (`cursor`, `limit`); osobno eksperymentalny `GET /api/experimental/session/{sessionID}/terminal/read?lines=...` i persistent terminal snapshot.

**MVP:** „Pokaż log testów/builda”, przewijanie z paginacją, aktualny wynik, kopiowanie fragmentu. Zacząć od istniejących uruchomień; szybkie uruchamianie zapisanych poleceń przez `POST /api/shell` można dodać później.

**Granice:** shell output używa absolutnego kursora bajtowego i ma flagę `truncated`; nie traktować kursora jak numeru wiersza. Terminal read zachowuje puste wiersze i może zwrócić null. Wybór aktualnego terminala jest lokalny dla serwera i resetuje się po restarcie.

**Wartość:** znaczna część użyteczności terminala bez od razu budowania emulatora, klawiatury i pełnego interaktywnego transportu.

### 19. Terminal interaktywny

**API:** zwykłe PTY list/create/get/update/delete/connect-token/connect i osobna grupa persistent PTY z snapshotem, biletem, rolą attachmentu oraz takeover.

**MVP po spike:** attach do istniejącego terminala, rozmiar, reconnect z kursorem, copy/paste i dodatkowy pasek klawiszy. Tryb obserwacji jako domyślny, przejęcie sterowania jawne.

**Bloker:** `pty.connect` wymaga WebSocket; obecny Remote przenosi HTTP i SSE we własnym szyfrowanym kanale, nie jest transparentnym tunelem każdego upstream WebSocket. Dodanie ścieżki do allowlisty nie implementuje PTY. Potrzebny most dwukierunkowy, flow control, limity, framing, cykl życia oraz autoryzacja ticketów.

**Granice:** nie utożsamiać zwykłego PTY z persistent PTY. Najpierw ustalić wymagania po restarcie serwera i politykę owner/viewer. Przy iPhone koszty UX duże; na iPadzie wartość może być wyraźnie większa.

### 20. Przenoszenie kontekstu sesji

**API:** `POST /api/session/{sessionID}/move` z `directory` i `delivery`.

**MVP:** „Kontynuuj w innym worktree” po wybraniu zatwierdzonej lokalizacji; oczekujący move widoczny w serwerowym inbox, nowa lokalizacja pokazana dopiero po wykonaniu.

**Granice:** operacja zmienia lokalizację sesji. Nie obiecuje automatycznego skopiowania dirty changes, merge'a branchy lub przekopiowania filesystemu. Obecna zmiana `ConnectionManager` context nie wykonuje tej operacji na sesji.

**Remote:** aktualny ownership lookup sesji nie wystarcza — trzeba sprawdzić także katalog docelowy z body. Przeniesienie do niezatwierdzonej lokalizacji mogłoby ukryć sesję albo naruszyć model dostępu.

### 21. Własna organizacja sesji i instrukcje zadania

**API:** `metadata` w create/update session, eksperymentalne instrukcje per session: list/put/remove entries. PUT instrukcji ogłasza zmianę przy następnej granicy kroku. To dwa różne mechanizmy.

**MVP:** tagi, ulubione, notatka użytkownika w namespacowanym metadata, np. pole `openlens`; osobno „Instrukcje dla tego zadania” jako jawna funkcja wpływająca na agenta. Read-modify-write musi zachować obce metadata, a semantykę merge/replacement trzeba potwierdzić przed zapisem.

**Granice:** pole `time.archived` w projekcji nie dowodzi istnienia publicznej operacji archiwizacji. Aktualny PATCH session ma title/metadata/permissions, nie archived. Lokalne ukrywanie sesji można zbudować, ale nie przedstawiać go jako zsynchronizowane archiwum OpenCode.

**Nie mylić:** notatka użytkownika w metadata nie musi być widoczna dla modelu. Instrukcje mają wpływać na model i powinny być prezentowane jako takie.

### 22. Głos

**API:** `POST /api/experimental/voice/session` z `model`, `transport`, opcjonalnym `session` zwraca SDP answer WebRTC albo ephemeral token WebSocket, korzystając z credentiali skonfigurowanych na serwerze.

**Wniosek:** istnieje realna podstawa pod rozmowę głosową, ale to broker transportu/provider auth, nie gotowe „steruj aktualną sesją kodowania przez mikrofon”. Kontrakt nie wymaga identyfikatora sesji kodowania w ścieżce. Trzeba zaprojektować przekładanie wypowiedzi na prompt/steer, dostęp do kontekstu i obsługę odpowiedzi.

**Rekomendacja:** najpierw prosty głos → tekst → istniejący composer jako osobna funkcja iOS; później techniczny spike realtime. Zakres obejmuje audio session, przerwania, mikrofon, opóźnienie, transkrypcję, koszty i zachowanie po blokadzie ekranu. Nie ogłaszać produkcyjnego voice na podstawie samego 200 z endpointu.

### 23. Edycja plików

**API:** `POST /api/experimental/fs/write` przyjmuje bytes z `path` i `location`; odczyt już jest.

**MVP:** edycja małych plików tekstowych, podgląd zmian przed zapisem, ponowny odczyt na dysku. Przydatne dla konfiguracji i małych poprawek, szczególnie na iPadzie.

**Granice:** brak potwierdzonego atomowego compare-and-swap/ETag w tym endpointcie. Porównanie przed zapisem wykrywa część konfliktów, ale nie usuwa wyścigu z agentem zapisującym ten sam plik. Nie nazywać tego bezpieczną edycją współbieżną bez dodatkowego mechanizmu. Zapisy FS nie są stage/commit w Git. Odłożyć duży edytor kodu, dopóki nie ma dowodu zapotrzebowania.

### 24. Diagnostyka serwera i pluginów

**API:** plugin list/check/update, config get, shell config, location reload, debug location; eksperymentalny session log.

**MVP:** stan integracji/pluginów, wersja serwera, wybrany protokół i konkretne brakujące możliwości, eksport zredagowanego raportu diagnostycznego. Później sprawdzanie aktualizacji pluginów. Update, reload i debug eviction to operacje ingerujące w runtime, nie niewinne odświeżenie UI.

**Granice:** obecny `PATCH /api/experimental/config` ma wyłącznie pole `shell`. Nie da się z niego wywnioskować pełnego edytora config, agentów, modeli i polityk. Pełniejsza edycja pliku config to inny przepływ z ryzykiem konfliktów, walidacją i reload.

### 25. Push, harmonogramy, limity kosztu — oddzielny zakres infrastruktury

**Push:** produktowo jedna z najmocniejszych funkcji mobilnych: „Agent skończył”, „Potrzebuje zgody”, „Testy nie przeszły”. API event pozwala wykrywać zdarzenia na stale działającym komputerze, ale nie daje natywnego endpointu rejestracji urządzenia APNs. ActivityKit zdalnie aktualizuje Live Activities przez APNs. [Dokumentacja Apple](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

**Implikacja dla OpenLens:** potrzebny komponent dostarczania APNs, zarządzanie tokenami urządzeń/aktywności i deduplikacja. Obecny self-hosted Remote bez backendu OpenLens tego nie zapewnia. Decyzja o centralnej usłudze versus zaawansowanym self-hostingu zmienia produkt; nie umieszczać jej jako drobnego rozszerzenia SSE. Nie dystrybuować wspólnego klucza dostawcy APNs razem z publicznym helperem.

**Harmonogramy:** queue oznacza kolejność wykonania, nie „uruchom jutro o 09:00”. Potrzebny scheduler na stale działającym hoście/pluginie/backendzie. Sam telefon nie gwarantuje takiego uruchomienia w tle.

**Budżety:** stats pozwala prezentować użycie; alarm w UI nie jest twardym limitem kosztu. Twarde zatrzymanie wymaga egzekwowania po stronie serwera/providera. Polling kosztu może reagować dopiero po naliczeniu kolejnego kroku.

**Inne rozszerzenia lokalne:** App Intents, skróty do wybranej sesji, widget z ostatnim snapshotem, offline read-only, lokalne szkice i Markdown export są możliwe po stronie OpenLens. Nie potrzebują dedykowanego endpointu v2; należy je wyceniać osobno i nie mylić z nowymi możliwościami serwera.

## Zapis 4 — mniejsze możliwości i uzupełnienia istniejących funkcji

Poniższe funkcje uzupełniają ranking; nie każda zasługuje na osobny ekran:

| Możliwość | Podstawa | Sensowna forma produktu | Ograniczenie |
|---|---|---|---|
| Cofnięcie z możliwością odstąpienia | revert stage / clear / commit | Etap wyboru granicy, jasne pokazanie zakresu, oddzielne zatwierdzenie | `stage` z `files=true` może już zmienić pliki. Nie przedstawiać stage jako czysto wizualnego dry-run; obecny klient od razu stage + commit |
| Kontynuacja po przerwaniu | interrupt `resume=true`, prompt `resume` | „Przerwij i uwzględnij korektę”, odróżnienie od zatrzymania | Queue pozostaje zaparkowane zgodnie z kontraktem interrupt; nie zakładać, że stop usuwa kolejkę |
| Odblokowanie długiego narzędzia | session background | „Pozwól agentowi kontynuować, obserwuj proces w tle” | Dotyczy backgroundable foreground tools, nie iOS background execution |
| Wyszukiwanie w internecie | websearch providers + query | Wybór źródeł do promptu, research przed zadaniem | Osobne wywołanie providera; linki nie stają się automatycznie obsługiwanymi HTTP załącznikami |
| Nazwy i ikony projektów | project PATCH name/icon/commands/canonical | Czytelny switcher kilku repozytoriów | Nie mieszać kosmetycznej nazwy z canonical path i komendami setup |
| Lista modeli i dostępności | model/provider get/list | Wyjaśnienie niedostępności, porównanie capabilities | Model picker już istnieje; rozszerzenie, nie nowa funkcja od zera |
| Środowisko poleceń sesji | PUT session environment | Zaawansowany wybór przygotowanego profilu | PUT **zastępuje** środowisko; nie przyrostowe dopisanie jednej zmiennej. Sekrety nie powinny trafiać do zwykłych ustawień telefonu |
| Formularz z aplikacji | session form create | Strukturalna ankieta w kontrolowanym workflow pluginu | Sam formularz nie definiuje biznesowej automatyzacji; aktualne odpowiadanie już działa |
| Wiadomość syntetyczna | session synthetic | Handoff lub kontekst dostarczony przez integrację | Oznaczyć źródło; nie udawać rzeczywistej wypowiedzi użytkownika |
| Trwały log sesji | experimental session log `after`, `follow` | Wiarygodniejsze odtwarzanie przebiegu po rozłączeniu | Sekwencja jednej sesji nie jest globalnym Last-Event-ID; koszt pamięci i forward compatibility |
| Cache i podgląd artefaktów | fs read: Range/ETag/Last-Modified | Obrazy, tekst, wybrane fragmenty dużych plików | Surowe bajty wymagają rozpoznania typu; HTTP Range nie znosi limitów odpowiedzi Remote |
| Status migracji v1 | experimental migration status | Pomoc przy diagnozie starej historii | Narzędzie wsparcia, nie istotny argument marketingowy |

Źródło: opisy i schematy operacji w [zapisanym OpenAPI](ResearchSources/opencode-v2-openapi-2026-10-19.json).

## Co zmienić w fundamentach przed większą rozbudową

### Możliwości konkretnego serwera

Obecny `OpenCodeServerCapabilities` rozróżnia v1/v2 i trzy opcjonalne funkcje. To za mało do bezpiecznego pokazania całej nowej powierzchni. `ServerInfo.capabilities.persistentPty` istnieje w aktualnym schemacie, ale lokalny `OCV2ServerInfo` go nie dekoduje.

Proponuję zachować istniejącą zasadę „możliwości zamiast minimalnej wersji”, rozszerzając ją o capability per funkcja i źródło dowodu. Nie oznaczać jako dostępnego wszystkiego tylko dlatego, że `/api/info` odpowiedziało 200. Odczyty można wykrywać read-only; mutacji nie wywoływać jako probe. W razie 404 rozróżnić brak trasy i brak konkretnej sesji/zasobu przez typed error, a nie automatycznie wyłączać funkcję globalnie. Błąd transportu nie jest dowodem braku funkcji.

### Bezpośrednie połączenie versus Remote

Każda nowa funkcja wymaga dwóch osobnych odpowiedzi: „czy obsługuje ją OpenCode?” i „czy przepuszcza ją OpenLens Remote?”. Obecna allowlista jest celowo wąska. Poniższe kategorie mają odmienne wymagania:

| Kategoria | Przykłady | Co sprawdzić w gateway |
|---|---|---|
| Zasób sesji | inbox, fork, context, generate, log | Własność sesji przy każdym żądaniu; wynik nowego fork; filtrowanie zdarzeń |
| Zasób lokalizacji | fs/find, skills, MCP, VCS | Wstrzyknięcie zatwierdzonej lokalizacji; brak obejścia przez query/body/URI |
| Zasób projektu/globalny | stats, saved permissions, worktree, credentials | Filtrowanie wyników, ograniczenie projectID i docelowych katalogów; brak wycieku spoza rejestru |
| Duże payloady | obrazy, export/import, logi | Limit gotowego body, kompresja/paginacja/Range; pamięć i czytelny błąd |
| Interaktywny transport | PTY, voice | Osobny projekt kanału albo bezpośrednie połączenie do providera; allowlista HTTP nie wystarcza |

Nie należy „naprawiać” wsparcia nowych funkcji przez blanket allow `/api/*`. Dla produktu można początkowo pokazać funkcję tylko przez LAN, ale musi to być jawna decyzja i widoczna informacja, nie przypadkowa porażka dopiero po kliknięciu.

### Stan i architektura aplikacji

Trzymać się istniejących usług i reguł projektu: logika biznesowa w usługach `@Observable`, wstrzykiwanie współdzielonych zależności przez `@Environment`, lokalny stan ekranów przez `@State`, bez nowych ViewModel/Presenter. Raport nie proponuje przebudowy całej aplikacji. Największe wspólne rozszerzenia to DTO sesji/osi czasu, reconciliacja kolejki i capabilities.

Nowe dane session (`outcome`, `viewed`, metadata, fork, cost) wymagają także przeglądu porównań/equality oraz cache. Aktualne `OCSession.==` bierze pod uwagę ID, title, updated i revert. Dopisanie pola do dekodera nie wystarczy, jeśli zmiana nie wywoła odświeżenia używającego porównania.

### Reconciliacja i odzyskiwanie połączenia

`/api/event` jest ulotne; nie ma gwarancji odtworzenia zdarzeń z czasu rozłączenia. [Opis strumienia](https://dev.opencode.ai/v2/docs/api). Obecne mechanizmy reconnect należy rozszerzać razem z nowymi funkcjami: aktualna sesja, ostatnie wiadomości, inbox, forms, permissions, capabilities. Trwały log jednej sesji może pomóc, ale nie zastępuje snapshotu wszystkich zasobów. Nie sumować kosztów ani nie tworzyć badge tylko na podstawie liczby odebranych eventów.

## Rekomendowana kolejność wydań

### Etap A — lepsza kontrola istniejącej pracy

1. Capabilities dla planowanych funkcji, poszerzenie DTO session, kontrakty REST i Remote.
2. Trwała kolejka i anulowanie/steer.
3. Outcome + viewed + ekran powrotu do pracy.
4. `session.generate` do podsumowania i następnego kroku.

**Efekt dla użytkownika:** otwiera aplikację po godzinie i rozumie, co się wydarzyło, co czeka i gdzie potrzebna jest jego decyzja. To najmocniej wykorzystuje mobilny charakter OpenLens bez nowego backendu.

### Etap B — bogatszy kontekst i wygodne alternatywy

1. Załączniki z telefonu z poprawnym limitem Remote.
2. Picker plików/skills i linie pliku jako kontekst.
3. Fork z nawigacją do rodzica/dzieci.
4. Oś zdarzeń, kontekst i ręczna kompaktacja.

**Efekt:** użytkownik może pokazać problem obrazem, precyzyjnie wskazać kod i spróbować alternatywnego podejścia. Część B można wysunąć przed A, jeśli główny feedback dotyczy braku obrazów; ranking nie zastępuje danych od użytkowników.

### Etap C — review i kontrola kosztów

1. Diff gałęzi/commitów i wybór base.
2. Saved permissions.
3. Globalne stats i ulepszony kalendarz.
4. Eksport sesji oraz wyszukiwanie server-side.

**Efekt:** łatwiej ocenić jakość i zakres pracy agenta przed powrotem do komputera.

### Etap D — praca w izolacji i administracja

1. Worktree inventory/create i polityka Remote.
2. Fork + worktree + move jako spójny, odporny na częściowy sukces workflow.
3. Integrations/MCP status, następnie wybrane procesy logowania.
4. Shell output i terminal read-only.

### Osobne eksperymenty

Pełny terminal, realtime voice, współbieżny edytor plików, push/APNs i harmonogramy wycenić osobno po spike. Każdy z nich może być dobrym kierunkiem, ale zależy od nowego transportu, infrastruktury lub znacznie trudniejszego UX.

## Minimalne scenariusze weryfikacyjne przy implementacji

To plan testów przyszłych funkcji, nie twierdzenie, że zostały uruchomione w tym researchu.

| Obszar | Scenariusz, który powinien przejść |
|---|---|
| Kolejka | Dodanie na desktopie, odczyt na iPhonie, restart app, anulowanie równolegle z dostarczeniem |
| Fork | `before` pierwszej/środkowej wiadomości, pełna historia, widoczność dziecka, brak obietnicy rollback plików |
| Nieprzeczytane | Nowa tura kończy się przed odpowiedzią na stary `view`; nowy wynik nadal wymaga odczytu |
| Załączniki | Granica 2 MiB gotowego body Remote, nietypowy MIME, model bez image input, data URI, niedozwolony file URI |
| Worktree/move | Nieudany setup, nowy katalog poza rejestrem Remote, brudny katalog, częściowy sukces, przeniesienie przy aktywnej turze |
| Stats | Różne timezone, brak danych, zero/nieznany koszt, dostęp tylko do jednego projektu |
| Generate | Błąd providera, timeout, brak mutacji historii, brak ponownego generowania przy każdym renderze |
| Context/compact | Pending/failed/completed, retry z tym samym id, reconnect w trakcie |
| Permissions | Cofnięcie istniejącej reguły, równoległa decyzja na desktopie, niedozwolony projectID |
| Integrations | OAuth cancelled/expired/completed, callback na innym urządzeniu, brak sekretów w logach |
| Export/import | Duża odpowiedź, sanitized payload, brak rodzica, kolizja ID, inna lokalizacja |
| Terminal | Bilet wygasły, reconnect, obserwator versus właściciel, limity bufora, zakończenie procesu |

Dla zmian app/widget obowiązuje repozytoryjne `xcodegen generate && xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,id=F323E9E4-4B39-4EB6-A42B-AB9E203A3E9A' CODE_SIGNING_ALLOWED=NO test`. Dla zmian gateway potrzebne są również odpowiednie testy Remote. Research zmienia wyłącznie dokumenty i snapshot publicznego API, więc nie wymaga kompilacji aplikacji.

## Pewność ustaleń i czego nie sprawdzono

- **Wysoka:** obecność endpointów i pól w zapisanym oficjalnym OpenAPI; opisane luki wynikające z odczytu aktualnego kodu OpenLens.
- **Umiarkowana:** zachowanie opisane w dokumentacji API bez uruchomienia konkretnego builda serwera. Spec jest eksperymentalny; szczegóły trzeba potwierdzić testem integracyjnym.
- **Ocena produktowa:** ranking, proponowane MVP i nakład. Nie przeprowadzono wywiadów, analizy telemetryki ani badań gotowości do płacenia.
- **Nie wykonano:** wywołań na prywatnym serwerze, odczytu sekretów, kosztownych generacji, mutacji sesji, testów na urządzeniu, zmian kodu produkcyjnego.
- **Nie należy utożsamiać:** historycznego planu migracji, wewnętrznego SDK, numeru wersji OpenAPI `0.0.1` i publicznej funkcji HTTP dostępnej w każdym buildzie.

## Źródła i utrwalone materiały

1. [Główny kontrakt OpenAPI v2](https://dev.opencode.ai/v2/openapi.json) — źródło ścieżek, pól, odpowiedzi i opisów semantyki.
2. [Czytelna dokumentacja HTTP](https://dev.opencode.ai/v2/docs/api) — punkt wejścia do dokumentacji.
3. [Audyt powierzchni HTTP upstream](https://github.com/anomalyco/opencode/blob/dev/V2_HTTP_API_AUDIT.md) — wyjaśnienie usuniętych operacji workspace/legacy.
4. [Załączniki](https://dev.opencode.ai/v2/docs/attachments) — URI, formaty i limity.
5. [Kompaktacja](https://dev.opencode.ai/v2/docs/compaction) — przebieg i semantyka.
6. [MCP](https://dev.opencode.ai/v2/docs/mcp-servers) — runtime, konfiguracja i uwierzytelnienie.
7. [Apple ActivityKit push](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications) — wymóg osobnego mechanizmu zdalnych aktualizacji.
8. [Pełny katalog 144 operacji](OPENCODE_V2_API_RESEARCH.md) — szczegółowe query/body i ograniczenia.
9. [Zapisany JSON](ResearchSources/opencode-v2-openapi-2026-10-19.json) — snapshot do późniejszej implementacji bez zależności od dostępności rozmowy.
10. Kod repozytorium w commicie podanym na początku raportu: `OpenCodeClient`, `ServerModels`, `OpenCodeProtocol`, `ChatClient`, `SessionsService`, `SessionInsightsService`, `WorkspaceService`, `WorkspaceRootView`, `OpenCodeForwarder`, `RemoteProtocol` oraz README.

## Stan końcowy

Research ukończony: inwentaryzacja lokalnego produktu, katalog aktualnego HTTP, ranking 25 głównych propozycji, mniejsze rozszerzenia, zależności Remote/iOS, plan wdrożenia i kryteria weryfikacji. Materiały były zapisywane etapami. Kontynuacja implementacji powinna zaczynać się od wybrania jednego etapu i ponownego sprawdzenia kontraktu konkretnego serwera; nie wymaga odzyskania tej rozmowy.
