# OpenCode V2 a OpenLens: funkcje API i kolejność dalszych prac

Data: 2026-10-05. Analizowany OpenLens: `1dfb5aa` (2026-10-02). Zakres: zewnętrzny klient iOS, bez zmian kodu aplikacji.

## Wniosek

OpenLens ma już dużą część migracji V2. Największy dalszy zysk da poprawne współdzielenie sesji z desktopem: kanoniczny model/agent, pełna kolejka serwera, wyniki wykonania i historia zmian kontekstu. Następne funkcje produktowe to załączniki z telefonu, kontrola kontekstu oraz sesje w osobnych worktree. Rozbudowywanie wszystkich endpointów administracyjnych ma mniejszą wartość.

To analiza kontraktów i kodu. Nie przeprowadzono w tej pracy rozmowy z żywym serwerem V2, testu dostawcy modelu ani testu na urządzeniu. Znalezione luki dekodowania i routingu są potwierdzone statycznie; skutki zależne od kolejności pracy kilku klientów wymagają scenariuszy integracyjnych.

## Jak ustalono punkt odniesienia

- V2 oznacza serwer OpenCode 2 i publiczne `/api/*`. Stare `@opencode-ai/sdk/v2` nie jest tym samym numerem wersji serwera.
- Oficjalna [migracja](https://opencode.ai/v2/docs/migrate-v1/) określa nowe API jako zmianę wymagającą portowania integracji. Aktualna dokumentacja wskazuje `@opencode/client`; starsze materiały `dev.opencode.ai` opisują wcześniejsze pakiety i beta.
- Sprawdzono opublikowane `@opencode/cli`, `@opencode/client` i `@opencode/core` w wersji **2.0.23**, oraz tag `v2.0.23` wskazujący commit `0fd7e2829449b052abf0078666669302923d77af` (2026-10-05). Źródła wydania są dokładniejszym punktem odniesienia niż ruchome gałęzie `dev` i `v2`.
- Pobrano [aktualne OpenAPI](https://opencode.ai/v2/openapi.json): 117 ścieżek, 141 operacji HTTP. SHA-256: `0612418392961ef22f0337ce0e1e520270917665fc85f29c4af1c94d1e1873ee`.
- Pole `info.version` tej specyfikacji to `0.0.1`, a opis nadal zawiera „Experimental HttpApi”. To wersja/opis dokumentu, nie numer wydania aplikacji ani wystarczający dowód, że całość V2 jest beta.
- [Research upstream](OPENCODE_V2_UPSTREAM_RESEARCH.md) zapisuje wersje opublikowanych pakietów oraz źródła semantyki. Kontrakty z publicznej strony i konkretnej instalacji mogą się różnić; potrzebny jest zapis wersji serwera w wynikach weryfikacji.
- W repo istnieje [plan migracji z 23 września](API_V2_MIGRATION_PLAN.md), ale jego wstęp „predominantly a v1 client” jest już nieaktualny. [Audyt z 25 września](../../.scratch/api-v2-regressions/AUDIT.md) dokumentuje wdrożoną obsługę V2 i pozostawione do wykonania testy z żywym serwerem.

## Co zmienia V2 z perspektywy klienta

Nie każda funkcja poniżej jest nowa dla całego OpenCode. Forki, MCP, obrazy, komendy, undo i sesje potomne występowały także w V1. Nowością lub istotną zmianą jest ich obecny kontrakt, trwały stan i sposób sterowania.

| Obszar | V1 / wcześniejszy sposób | V2 / istotna zmiana | Znaczenie dla OpenLens |
| --- | --- | --- | --- |
| Cykl życia serwera | Klient lokalny albo ręcznie uruchomiony serwer i attach | Domyślnie jeden wspólny background service dla użytkownika; tryb prywatny i jawny `--server` nadal dostępne | Sprawdzić, czy telefon, TUI, desktop i Remote łączą się z tą samą instancją |
| Przyjmowanie zadań | Prompt/message i obserwacja generacji; nowsze V1 miało też elementy schedulera | Trwały inbox; `steer` i `queue`; odczyt, anulowanie i zmiana trybu niedostarczonego wpisu | Pokazać pracę zgłoszoną z każdego klienta, odzyskać ją po restarcie, anulować lub przyspieszyć |
| Model i agent | Parametry promptu i historia odpowiedzi | Jawne właściwości sesji oraz osobne operacje przełączenia; zmiany zapisane w historii | Odtwarzać aktualny wybór z sesji, zachować wariant reasoning, respektować zmiany z desktopu |
| Historia | Głównie wiadomości user/assistant i parts | Timeline obejmuje także zmiany modelu/agenta/lokalizacji, shell, skill, synthetic, system, compaction i idle | Widzieć przyczynę zmiany zachowania agenta i wynik wykonania |
| Interakcje | Pytania i odpowiedzi | Uogólnione forms, w tym wartości liczbowe, boolean, multiselect i external URL | Natywne interakcje z narzędziami i integracjami |
| Uprawnienia | Reguły często związane z nazwami narzędzi | Uporządkowane reguły action/resource/effect, zapisane zgody i ich usuwanie | Pokazać zakres „zawsze”, umożliwić cofnięcie zgody i przekazanie powodu odmowy |
| Kontekst | Summarize i części compaction | Oddzielny odczyt aktywnego kontekstu; compaction jako przyjmowane zadanie; wynik i podsumowanie w historii | Wskaźnik kontekstu, ręczne skrócenie, informacja co zostało zachowane |
| Praca w repo | Projekt/katalog i eksperymentalne worktree | Publiczne worktree list/create/remove/refresh oraz przenoszenie sesji na granicy wykonania | „Nowe zadanie w osobnej gałęzi” i kontynuowanie sesji w wybranym katalogu |
| Undo | Revert/unrevert | Stage/clear/commit; opcjonalna zmiana plików | Cofnięcie odwracalne do momentu commit; można rozdzielić podgląd i zatwierdzenie |
| Shell / tło | Shell i PTY istniały wcześniej | Rejestrowany shell, stronicowany output oraz background dla wspieranych aktywnych narzędzi | Podgląd długo działającego procesu bez pełnego terminala |
| Integracje | API provider auth i MCP | Integrations z metodami logowania i attempts, credentials, osobny katalog MCP | Podgląd przyczyny niedostępności modelu i dokończenie logowania z telefonu |
| Zdarzenia | V1 event vocabulary | Natywne V2 events i oddzielny cykl execution/step/content | Koniec odpowiedzi asystenta nie zawsze kończy wykonanie całej sesji |

Źródła kontraktów: [API V2](https://opencode.ai/v2/docs/api), [OpenAPI V2](https://opencode.ai/v2/openapi.json), [API V1](https://opencode.ai/docs/server/), [migracja](https://opencode.ai/v2/docs/migrate-v1/). Szczegóły porównania historycznego i wykonania: [research upstream](OPENCODE_V2_UPSTREAM_RESEARCH.md).

Cykl życia opisuje [CLI V2](https://opencode.ai/v2/docs/cli). `opencode serve --hostname ... --port ...` pozostaje w [aktualnej liście komend](https://opencode.ai/v2/docs/cli/commands/#serve). Helper [openlens-qr](../../Tools/openlens-qr/Sources/main.swift) uruchamia jednak TUI przez starsze `opencode attach ... --continue --password`. W opublikowanym CLI 2.0.23 nie ma `attach` ani tej flagi hasła; bieżący przepływ to `opencode --server ... --continue` i hasło z environment. To potwierdzona rozbieżność helpera z CLI V2, wymagająca adaptacji dla protokołu/wersji i testu uruchomienia. Źródło dokładnego CLI i obsługiwanych flag: [research upstream](OPENCODE_V2_UPSTREAM_RESEARCH.md). Samo zachowanie komendy `serve` nie weryfikuje części TUI.

## Co już jest wdrożone

| Funkcja | Dowód w obecnym kodzie | Ocena |
| --- | --- | --- |
| Wybór V1/V2 na podstawie `/api/info` i fallback do health | [OpenCodeClient.swift](../Services/OpenCodeClient.swift), `probeCapabilities`; [OpenCodeProtocol.swift](../Models/OpenCodeProtocol.swift) | Wdrożone; nie wymaga ponownej migracji |
| Sesje, wiadomości, koperty odpowiedzi, 204, typowane błędy, paginacja | `OpenCodeClient` i [testy paginacji](../../OpenLensTests/OpenCodePaginationTests.swift) | Wdrożone; UI nadal często pobiera wszystkie strony |
| Queue, steer i interrupt | `queuePrompt`, `steerPrompt`, `abortSession`; [testy kolejki](../../OpenLensTests/QueuedPromptTests.swift) | Wdrożone wysyłanie; brakuje zarządzania pełnym inboxem serwera |
| Formularze V2 | [FormView.swift](../Views/Components/FormView.swift), [InteractiveFormSafety.swift](../Models/InteractiveFormSafety.swift), [testy](../../OpenLensTests/OpenCodeV2FormTests.swift) | Obsługiwane rodzaje pól są już natywne |
| Uprawnienia V2, także wspólne żądania dla widgetu | `replyToPermission`, [LiveActivityIntents.swift](../Models/LiveActivityIntents.swift), [testy](../../OpenLensTests/OpenCodeV2PermissionTests.swift) | Wdrożone; brakuje przeglądu zapisanych zgód |
| Revert stage/clear/commit i diff turn/session/working tree | `revertMessage`, `getWholeSessionDiff`, `getWorkingTreeDiff`, [ReviewService.swift](../Services/ReviewService.swift) | Wdrożone; UX może wykorzystać odwracalny etap |
| Natywny stream i odzyskiwanie stanu po luce | [V2EventAdapter.swift](../Services/V2EventAdapter.swift), [SSEClient.swift](../Services/SSEClient.swift), [testy recovery](../../OpenLensTests/V2ReconciliationTests.swift) | Wdrożone; recovery należy rozszerzyć o inbox i kanoniczne ustawienia sesji |
| Modele, warianty, ceny, capabilities | `listProviders`, `OCV2ModelInfo`, model picker | Wdrożone; DTO pomija `enabled/status`, ale stock API 2.0.23 już filtruje modele enabled |
| Skill mentions i komendy | `listSkills`, [SkillMention.swift](../Models/SkillMention.swift), `sendCommand` | Wdrożone bezpośrednio; lista skills jest blokowana przez Remote |
| Pairing OpenCode | [OpenCodePairingClient.swift](../Services/OpenCodePairingClient.swift), parser linków, Keychain | Wdrożone |
| Izolacja projektów w Remote | [OpenCodeForwarder.swift](../../Tools/openlens-qr-menubar/RemoteSources/OpenCodeForwarder.swift), [GatewayV2EventFilter.swift](../../Tools/openlens-qr-menubar/RemoteSources/GatewayV2EventFilter.swift) | Wdrożona dla obecnego zakresu tras; nowe funkcje wymagają rozszerzenia |

## P1 — poprawki poprawności i współpracy z desktopem

### 1. Kanoniczny model, wariant i agent sesji

**Luka:** `OCSession` nie dekoduje `agent` i `model`. `OCV2SessionMessage.Model` pomija `variant`. `ChatClient.loadMessages` odtwarza wybór z ostatniej obsługiwanej wiadomości, a `syncSessionModelSelection` ustawia `selectedVariant = nil`. `applyV2PromptSelection` wysyła przełączenie modelu przed każdym promptem, gdy model jest wybrany.

**Przykład ryzyka:** użytkownik zmienia model/wariant na desktopie, ale nie generuje jeszcze odpowiedzi. iPhone odczytuje poprzednią odpowiedź i przy następnym wysłaniu ustawia poprzedni model, zamiast kontynuować z aktualnymi ustawieniami sesji.

**Zmiana:** osobno przechowywać domyślny model nowej sesji i bieżące ustawienia istniejącej sesji. Odczytywać `Session.Info.model/agent`, łącznie z wariantem. Wysyłać zmianę po świadomym wyborze użytkownika, zamiast odtwarzać ją przy każdym promptcie. Zapewnić uporządkowanie własnych zmian model/agent/prompt dla jednej sesji; sam actor nie zapewnia nieprzeplatania wieloetapowej operacji przez `await`.

Dowody: [ServerModels.swift](../Models/ServerModels.swift) (`OCSession`, `OCV2SessionMessage.Model`), [ChatClient.swift](../Services/ChatClient.swift) (`loadMessages`, `syncSessionModelSelection`), [OpenCodeClient.swift](../Services/OpenCodeClient.swift) (`applyV2PromptSelection`). Kontrakt: `Session.Info`, `Model.Ref`, `session.switchModel`, `session.switchAgent` w [OpenAPI](https://opencode.ai/v2/openapi.json).

### 2. Pełny inbox sesji jako źródło kolejki

**Luka:** `QueuedPrompt` jest stanem lokalnym. Aplikacja ignoruje wynik przyjęcia promptu i nie ma odczytu/edycji/anulowania inboxa. Reset sesji usuwa lokalną kolejkę. Wpisy `session.inbox.delivered/cancelled` powodują odświeżenie historii, ale nie odczyt kanonicznej kolejki.

**Zmiana:** dodać `GET /api/session/:id/inbox`, `DELETE .../inbox/:inboxID` i `PATCH .../inbox/:inboxID` z `delivery`. Pokazywać także kolejkę utworzoną na desktopie oraz wpisy compaction/move/synthetic. Rozdzielić lokalne „wysyłam” od przyjętego wpisu z ID serwera. Odzyskiwać inbox przy otwieraniu sesji, powrocie do aplikacji i luce SSE. Dostępne działania: anuluj przed dostarczeniem i przełącz queue→steer. Publiczne API nie oferuje dowolnego przestawiania kolejności ani edycji tekstu istniejącego wpisu; takiego UX nie należy obiecywać.

Dowody: [ChatClient.swift](../Services/ChatClient.swift) (`QueuedPrompt`, `queuePrompt`, `resetSessionState`), `sendV2RequestDiscardingResponse` w [OpenCodeClient.swift](../Services/OpenCodeClient.swift), [adapter](../Services/V2EventAdapter.swift). Kontrakt: `session.inbox.*` w [OpenAPI](https://opencode.ai/v2/openapi.json).

### 3. Skills działające także przez Remote

**Potwierdzona rozbieżność:** `OpenCodeClient.listSkills` wykonuje `GET /api/skill`. `OpenCodeForwarder.isAllowed` nie ma tej trasy i kończy niepasujące żądania wynikiem `false`. `WorkspaceService.loadSkills` po błędzie zwraca pustą listę.

**Zmiana:** dopuścić dokładnie `GET /api/skill`, ze sprawdzaniem i wstrzykiwaniem zatwierdzonej lokalizacji tak jak przy agentach/komendach. Odróżnić pusty katalog od błędu pobierania. Dodać kontrolę bezpośredniej i zdalnej zgodności dla każdej nowej funkcji.

Dowody: [OpenCodeClient.swift](../Services/OpenCodeClient.swift) (`listSkills`), [OpenCodeForwarder.swift](../../Tools/openlens-qr-menubar/RemoteSources/OpenCodeForwarder.swift) (`isAllowed`), [WorkspaceService.swift](../Services/WorkspaceService.swift) (`loadSkills`).

### 4. Stan zakończenia i zmiany lokalizacji w otwartej sesji

**Luka:** `OCSession` nie zachowuje `outcome`, `time.idle`, `time.viewed`; wiadomości `idle` są pomijane. `/api/session/active` trafnie pokazuje działające sesje, ale brak sesji w tym snapshotcie sam nie mówi, czy zadanie się udało, nie udało czy zostało przerwane. `restoreProjectContext` działa przy otwieraniu sesji; recovery po zdarzeniach pobiera nową sesję bez jawnego ponownego związania kontekstu projektu.

**Zmiana:** dodać rozróżnienie „zakończono / błąd / przerwano / oczekuje na odpowiedź” na podstawie kanonicznych danych i pending interactions. Nie wywodzić „czeka na zgodę” z samego `outcome`. Po przeprowadzce sesji na desktopie sprawdzać i aktualizować katalog, stream filter, komendy, modele i pliki. `POST .../view` z obserwowanym `idle` pozwala oznaczać zakończenie jako przeczytane; sensowne zastosowanie to badge na liście sesji.

Dowody: [ServerModels.swift](../Models/ServerModels.swift), [ChatClient.swift](../Services/ChatClient.swift) (`restoreProjectContext`, `synchronizeCurrentSessionFromServer`), [OpenCodeClient.swift](../Services/OpenCodeClient.swift) (`getSessionStatus`). Kontrakt: `Session.Info`, `Session.Message.Idle`, `session.view`, `session.move` w [OpenAPI](https://opencode.ai/v2/openapi.json).

### 5. Wyniki subagentów V2

**Potwierdzona rozbieżność:** `ChatMessage.subagentToolState` rozpoznaje narzędzie o nazwie `task`. W wydaniu V2 2.0.23 wbudowane narzędzie ma nazwę `subagent`; dedykowane karty dla tego przebiegu nie zostaną zbudowane z obecnego parsera. Ogólny widok narzędzia może nadal się pojawić.

**Druga luka:** wynik pracy subagenta w tle wraca do rodzica jako wiadomość `synthetic` z metadata `source:subagent`, `childID`, `agent`, `state`. Obecne mapowanie user/assistant usuwa ten wpis. Późniejsza odpowiedź modelu może opisać wynik, ale OpenLens nie zachowuje samego powiadomienia o wykonaniu jako widocznego elementu historii.

**Zmiana:** obsługiwać zarówno V1 `task`, jak i V2 `subagent`; wykorzystać metadata `sessionID/status` z narzędzia oraz `childID/state` z synthetic. Oddzielić zakończenie wywołania narzędzia od zakończenia pracy dziecka: narzędzie może zakończyć wywołanie sukcesem, ale jego metadata nadal mieć `status:running`. Pokazywać wynik dziecka i powiązane prośby o zgodę/odpowiedź.

[StreamToolPartSafety.swift](../Models/StreamToolPartSafety.swift) zachowuje dziś w metadata tylko warianty `sessionID`, a usuwa `status`. Przy poprawce zachować ograniczony, walidowany status; samo rozszerzenie nazwy narzędzia nie wystarczy do rozróżnienia „praca trwa” od „wywołanie zakończone”.

Dowody lokalne: [ChatMessage.swift](../Models/ChatMessage.swift) (`subagentToolState`), [ServerModels.swift](../Models/ServerModels.swift) (`OCV2SessionMessage.asMessage`). Źródła 2.0.23: [narzędzie subagent](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/tool/plugin/subagent.ts), [dostarczenie wyniku w tle](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/subagent-completion.ts). Delegowanie w tle istniało już w późnym V1; tutaj poprawiamy obsługę kontraktu V2.

### 6. Helper QR i tożsamość serwera

Przy uruchamianiu V2 zmienić część helpera otwierającą TUI na wspierany sposób opisany wyżej. Zachować osobną ścieżkę V1. Upewnić się, że TUI po otwarciu używa serwera, do którego prowadzi QR; domyślna usługa V2 może być inną instancją niż osobny `serve` uruchomiony przez OpenLens Remote. Hasło i pairing mają działać dla wskazanego serwera, a zatrzymanie helpera ma dotyczyć tylko procesu, który sam uruchomił.

## P2 — funkcje z największą wartością na iPhonie

### 7. Obrazy i pliki w promptach

Najbardziej bezpośredni nowy przepływ w OpenLens: zrobić zdjęcie/screenshot błędu, wybrać plik z Files lub wskazać plik repo i zadać pytanie. Załączniki istniały w V1; V2 daje kontrakt, z którego obecny klient jeszcze nie korzysta w zwykłym promptcie.

`OCV2PromptInput` ma wyłącznie `id/text/skills/delivery`. Brakuje `files` i `agents`. Dla pliku na telefonie wysyłać `data:` URI; `file:` wskazuje ścieżkę na komputerze serwera. Plik z repo można ograniczyć do linii przez `start/end`. Nie używać URL HTTP jako załącznika. Obsługiwać też załączniki z historii pochodzące z desktopu: `Prompt.FileAttachment` w projekcji zawiera już `data/mime/source`, a nie tylko wejściowe `uri`.

MVP: PNG/JPEG screenshot + tekst + plik repo; zgodność z capabilities wybranego modelu, kompresja i czytelny błąd przy niedostępnym formacie. Dokumentacja V2 wymienia PNG/JPEG/GIF/WebP i UTF-8; PDF, HEIC/AVIF, audio i wideo nie powinny być traktowane jako automatycznie obsługiwane wejście modelu. Zdjęcia iOS wymagają eksportu do wspieranego formatu. Limit Remote jest osobny od limitu OpenCode: trzeba przeliczyć wielkość Base64 i pełnego żądania.

Dowód lokalny: `OCV2PromptInput` i `OCV2SessionMessage` w [ServerModels.swift](../Models/ServerModels.swift). [RemoteProtocol.swift](../../OpenLensRemoteCore/RemoteProtocol.swift) ustawia 2 MiB dla całego HTTP body i 4 MiB dla wiadomości transportowej; Base64 pozostawia mniej niż około 1,5 MiB na surowe pliki w jednym żądaniu, po odjęciu JSON i tekstu. Źródło upstream: [Attachments](https://opencode.ai/v2/docs/attachments/) i [OpenAPI](https://opencode.ai/v2/openapi.json).

Drugą stroną tej funkcji jest wyświetlanie plików/obrazów zwracanych przez narzędzia. Obecny `OCToolState.ContentItem` redukuje V2 `content` do tekstu, nie zachowuje file URI/mime/name. Dodać mały model takich wyników i renderer dla chat/review, z istniejącymi ograniczeniami rozmiaru; dotyczy też częściowego wyniku błędu. Źródło: [Tool.Content 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/tool.ts).

### 8. Pełniejsza historia i kontrola kontekstu

`OCV2SessionMessage.asMessage` zwraca `nil` dla wszystkiego poza `user/assistant`; `listMessages` usuwa takie wpisy przez `compactMap`. Dodać dyskretne wiersze „zmieniono model”, „zmieniono agenta/katalog”, „użyto skilla”, „skrócono kontekst” i wynik shell/idle. Nie trzeba pokazywać każdego technicznego wpisu jako dużej bańki.

Dodać `GET .../context` i `POST .../compact`, stan działania i podgląd summary. Rozdzielić pełną historię od tego, co agent obecnie widzi. Sumy tokenów wszystkich odpowiedzi są kosztem historycznym, nie miarą aktualnego wypełnienia okna kontekstu. Wskaźnik bieżącego użycia wymaga danych ostatniego żądania/context i limitu modelu; nie wyliczać go z sumy w Insights.

Dowody: `asMessage` w [ServerModels.swift](../Models/ServerModels.swift), `listMessages` w [OpenCodeClient.swift](../Services/OpenCodeClient.swift), [SessionInsightsService.swift](../Services/SessionInsightsService.swift). Źródła: [Compaction](https://opencode.ai/v2/docs/compaction/), [OpenAPI](https://opencode.ai/v2/openapi.json).

### 9. Worktree, fork i kontynuowanie w innym katalogu

Dodać przepływ „Nowe zadanie w osobnej gałęzi”: `GET/POST /api/worktree`, następnie utworzenie sesji w zwróconym katalogu. W inventory pokazywać prawdziwe worktree; obecny workspace picker opiera się na projektach i zapamiętanych katalogach.

Fork istniejącej rozmowy pozwala sprawdzić drugi pomysł bez usuwania jej historii. `POST .../fork` z `before` kopiuje historię przed wskazaną wiadomością; fork nie jest automatycznie nowym worktree ani izolacją plików. Do eksperymentu izolowanego użyć dodatkowo worktree i `POST .../move`. W implementacji 2.0.23 fork ma `parentID` puste i osobne `fork:{sessionID,boundary}`; obecny root filter go nie ukryje, ale DTO gubi to powiązanie. Fork dziedziczy aktualny agent/model/reguły, a nie odtwarza ich historycznych wartości z wybranej granicy. Sesje subagentów z `parentID` wymagają osobnej nawigacji, ponieważ główna lista je filtruje.

Remote wymaga jawnego zatwierdzenia nowego katalogu w rejestrze Maca. Sam fakt, że worktree powstał pod znanym projektem, nie nadaje mu obecnie dostępu. Przenoszenie sesji wymaga także walidacji katalogu docelowego, nie tylko aktualnej własności sesji.

Dowody: [WorkspaceService.swift](../Services/WorkspaceService.swift), [WorkspaceSelection.swift](../Models/WorkspaceSelection.swift), `rootSessions/visibleSessions` w [SessionsService.swift](../Services/SessionsService.swift), [relay](../../Tools/openlens-qr-menubar/RemoteSources/OpenCodeForwarder.swift). Kontrakt: `worktree.*`, `session.fork`, `session.move` w [OpenAPI](https://opencode.ai/v2/openapi.json). Semantyka forka: [Session 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session.ts), [projector](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/projector.ts).

### 10. Przegląd pracy w tle i subagentów

Podstawowa infrastruktura kart i powiązania pytań/uprawnień już jest; dopasowanie nazw i wyników V2 opisuje poprawka P1 nr 5. Dalsze rozszerzenie: lista sesji potomnych, przejście do ich rozmów, osobne wyniki, koszt i oczekujące interakcje.

Dla wspieranych procesów dodać akcję „kontynuuj w tle” przez `POST .../background`, następnie podgląd stanu i ograniczonego output. To przenosi backgroundable tools do obserwacji w tle; nie oznacza uruchomienia iOS w tle ani uniwersalnego odłączenia dowolnego procesu. Pełny interaktywny PTY zostawić na później, szczególnie w Remote: obecny transport obsługuje HTTP/SSE, a PTY wymaga osobnej obsługi połączenia WebSocket.

Dowody: [AgentActivity.swift](../Models/AgentActivity.swift), [SSEEventHandler.swift](../Services/SSEEventHandler.swift) (`relatedSessionID`), [ChatMessage.swift](../Models/ChatMessage.swift) (persisted subagent). Kontrakt: `session.background`, `shell.output`, `pty.*` w [OpenAPI](https://opencode.ai/v2/openapi.json); szczegóły subagentów w [research upstream](OPENCODE_V2_UPSTREAM_RESEARCH.md).

### 11. Świadome i odwracalne zatwierdzanie

Dodać odczyt/usuwanie zapisanych zgód przez `/api/permission/saved`, widoczny zakres zapisania reguły i opcjonalny `message` przy odmowie. Natywne pojedyncze approve/reject już działa, więc to rozbudowa kontroli użytkownika.

W Review opcjonalnie wykorzystać stage/clear/commit do odwracalnego cofnięcia przed zatwierdzeniem. Stage z `files:true` może już zmienić pliki; nie jest czysto informacyjnym podglądem. Clear odwraca staged revert. Zachować obecną szybką akcję tylko jeśli użytkownik rozumie zakres; dodać wybór historii/pliki tam, gdzie ma to sens.

Źródła: [Permissions](https://opencode.ai/v2/docs/permissions/), [Snapshots](https://opencode.ai/v2/docs/snapshots/), [OpenAPI](https://opencode.ai/v2/openapi.json). Dowód lokalny: `replyToPermission/revertMessage` w [OpenCodeClient.swift](../Services/OpenCodeClient.swift).

### 12. Formularze warunkowe

Podstawowe typy formularzy już działają. `OCFormField.hasConditionalRules` oznacza pola z `when` jako unsupported, a UI świadomie blokuje wysłanie i kieruje do OpenCode. To bezpieczna degradacja, ale nadal brak możliwości wykonania niektórych interakcji z telefonu. Dodać ocenę warunków, reagowanie na zmianę odpowiedzi, pomijanie nieaktywnych pól w payload i walidację tylko aktywnych. Osobno sprawdzić w Inbox forms MCP z właścicielem `global`; nie należy wymagać, żeby każdy formularz należał do otwartego czatu. Kontrakt: [Form 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/form.ts).

## P3 — późniejsza rozbudowa

| Funkcja | Powód i ograniczenie |
| --- | --- |
| Podgląd stanu MCP/integracji i dokończenie OAuth | Ułatwia naprawienie niedostępnego modelu/narzędzia; nowy protokół attempts i credentials. Pełna konfiguracja dostawców ma mniejszy priorytet niż read-only diagnostyka |
| Eksport/import sesji | Przydatne do archiwizacji i zgłoszeń; aktualne ścieżki `/api/experimental/session/...` wymagają detekcji możliwości. Eksport nie jest publicznym linkiem share |
| VCS branch/committed diff i wybór base | Obecnie Review obejmuje turn/session oraz working tree; można dodać przegląd gałęzi przez `mode=branch/committed` |
| Szybkie wyszukiwanie plików | `GET /api/fs/find` przydatne przy `@file`; dziś klient głównie listuje katalogi |
| Generowanie krótkiego tekstu bez dopisywania do historii | `POST .../generate`; np. propozycja dalszego promptu. Wymaga oceny wartości UX i kosztu wywołania |
| Session environment, synthetic i instruction entries | Potężne do automatyzacji, ale zwykle niepotrzebne w pierwszym mobilnym UX. Instruction entries są obecnie experimental |
| Plugin RPC i zarządzanie pluginami | Warto rozważyć dopiero dla konkretnej integracji; nie wykonywać w iOS kodu serwerowych pluginów |
| Pełniejsze metadane modeli | `OCV2ModelInfo` pomija `enabled/status`. W stock 2.0.23 handler już używa `models.available()` i filtruje enabled, więc nie jest to obecnie potwierdzony błąd wyboru modelu. Zachować pola dla wariantów serwera i oznaczeń alpha/beta/deprecated; odświeżać katalog po zmianach integracji |
| Statystyki bez pobierania wszystkich rozmów | `GET /api/experimental/session/stats` agreguje aktywność, usage i niezawodność narzędzi dla zakresu czasu/projektu/strefy. Potencjalnie duży zysk dla obecnego kalendarza i Insights; przed zastąpieniem lokalnych obliczeń sprawdzić znaczenie każdej metryki i dostępność endpointu |
| Trwały log konkretnej sesji | `GET /api/experimental/session/:id/log?after=...&follow=true` umożliwia odczyt po wyłącznej sekwencji agregatu i późniejszą obserwację. To osobny, eksperymentalny kontrakt; nie jest replay globalnego `/api/event` i nie odzyskuje całego efemerycznego stanu forms/permissions/catalogs |

Filtr dostępnych modeli w konkretnym wydaniu potwierdza [handler model 2.0.23](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/handlers/model.ts).

Kontrakty powyżej są w [OpenAPI](https://opencode.ai/v2/openapi.json). Lista nie oznacza zalecenia wdrożenia całego API.

## Co usprawnić przy wdrażaniu

1. **Paginacja w UX.** `SessionsListView.loadSessions` pobiera wszystkie sesje, a transcript pobiera wszystkie strony od początku. Pokazywać najnowszą stronę i doładowywać starsze, wykorzystywać wyszukiwanie/filtry serwera. Insights i kalendarz mogą wymagać osobnego pełnego odczytu; nie wolno zastąpić ich niepełnymi sumami bez oznaczenia zakresu.
2. **Recovery po luce.** Zachować istniejącą regenerację stanu z REST. `/api/event` jest ulotne, gubi zdarzenia podczas rozłączenia i może się przepełnić. `id` SSE nie zapewnia replay. Dodać inbox, model/agent i kontekst lokalizacji do tego samego poprawnie anulowalnego odzyskiwania.
3. **Idempotencja wysyłania.** Zachować caller ID promptu przy ponowieniu tego samego żądania po niepewnym wyniku sieciowym, zamiast tworzyć następne zadanie. Potwierdzać przyjęcie/kolejkę z serwera. Nie uznawać timeout za dowód, że zadanie nie zostało zapisane. W 2.0.23 pierwszy wpis tego samego typu/sesji wygrywa: zmiana tekstu przy tym samym ID nie edytuje już przyjętego promptu. Zmieniony prompt wymaga nowego ID. Źródło: [core inbox](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/inbox.ts).
4. **Capability checks.** `OpenCodeServerCapabilities.supports` w praktyce ustala trzy opcje na podstawie V1/V2. Przy rozszerzaniu o nowe i experimental funkcje dodać odrębne, niemutujące sprawdzenia możliwości i czytelne stany braku wsparcia. Zachować decyzję o trwałym wsparciu V1/V2 bez narzucania minimalnego wydania V2.
5. **Zdalna zgodność.** Każdy nowy endpoint dopisać wraz z jego regułą lokalizacji/własności. Nie używać ogólnego `/api/*` i nie uznawać testu LAN za dowód działania przez bramkę.
6. **Rzeczywiste kontrakty.** Posiadane testy są użyteczne, ale syntetyczne fixtures nie zastępują przykładów z aktualnego serwera. Zapisać zanonimizowane response/event dla wybranego wydania i wykonać scenariusze dwóch klientów, reconnect, przełączenia modelu, move, fork oraz załączników bezpośrednio i przez Remote.

## Rzeczy, których V2 samo nie rozwiązuje

- **Push/APNs i Live Activities po zamknięciu aplikacji.** API wykonuje pracę na komputerze; otwarty stream w iOS nie daje automatycznie dostarczania w tle. To osobna funkcja wymagająca odpowiedniej ścieżki powiadomień. Obecny [README](../../README.md) opisuje to ograniczenie Remote.
- **Todo i publiczne share.** W przeanalizowanym publicznym OpenAPI nie ma bezpośrednich odpowiedników dawnych todo/share endpointów. Obecne wygaszanie tych opcji dla V2 jest uzasadnione. Eksport i konfiguracja share nie dowodzą istnienia endpointu share dla klienta.
- **LSP.** Aktualna [migracja](https://opencode.ai/v2/docs/migrate-v1/#supported-fields-without-direct-native-equivalents) mówi, że V2 nie uruchamia language servers, nie wystawia narzędzi LSP i nie generuje tych diagnostyk. Sprawdzenie lint/typecheck/compiler musi być jawnym zadaniem; nie budować nowego UI na dawnym `/lsp`.
- **Fork i worktree.** Kopia historii i izolacja plików są oddzielnymi operacjami.
- **Dowolne binarne załączniki.** Informacja o możliwościach modelu nie rozszerza formatów, które sam OpenCode przekazuje do modelu.

## Proponowana kolejność wydań

| Etap | Zakres | Warunek ukończenia |
| --- | --- | --- |
| A — zgodność między klientami | Kanoniczny model/agent/variant, pełny inbox, skills przez Remote, outcomes oraz reakcja na move; subagenci V2 i aktualny helper QR | Desktop i telefon pokazują ten sam stan; powrót do aplikacji nie gubi kolejki ani nie nadpisuje wyboru |
| B — najważniejsze użycie telefonu | Screenshot/obraz/tekst/pliki repo i wyniki plikowe narzędzi; historia, compaction i formularze warunkowe | Załącznik faktycznie dociera do modelu; użytkownik widzi aktywny kontekst i kończy obsługiwane interakcje na telefonie |
| C — kilka zadań równolegle | Worktree, fork/move, sesje potomne i obserwacja background tools | Oddzielne zadania są osiągalne i mają czytelne wyniki; zasady Remote obejmują nowe katalogi |
| D — zarządzanie | Saved permissions, diagnostyka integracji/MCP, eksport oraz dodatkowe diff | Użytkownik może naprawić konkretny problem z telefonu bez rozbudowy przypadkowych paneli administracyjnych |

Przy każdym etapie używać istniejących services, `@Environment` i `@Observable`, zgodnie z [AGENTS.md](../../AGENTS.md). Nie jest potrzebna nowa warstwa ViewModel/Presenter. Zmiany kodu wymagają projektu iOS/widget oraz zdalnej bramki stosownie do zakresu, zgodnie z aktualnymi poleceniami w `AGENTS.md`; ta analiza nie uruchamia tych zestawów, bo nie zmienia kodu.
