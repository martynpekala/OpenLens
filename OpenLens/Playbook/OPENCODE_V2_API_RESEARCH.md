# OpenCode v2 — katalog API i możliwości dla OpenLens

> Aktualizacja porównania z aplikacją: branch `feature/super-cool-new-features`, HEAD `2d5a6b0`; zobacz [aktualny raport produktowy](FEATURE_RESEARCH_OPENCODE_V2.md). Ten dokument kataloguje upstream API, a nie stan wdrożenia funkcji w OpenLens. Kontrakt pozostaje snapshotem z pierwotnego researchu 2026-10-19, bez ponownej weryfikacji online.

Stan badania: 2026-10-19. Ukończono katalog HTTP i analizę kontraktów. Weryfikacja: oficjalna dokumentacja, snapshot OpenAPI i audyt upstream; bez uruchamiania operacji na prywatnym serwerze.

## Źródła i zakres

- [Oficjalny OpenAPI JSON](https://dev.opencode.ai/v2/openapi.json)
- [Oficjalna dokumentacja HTTP API](https://dev.opencode.ai/v2/docs/api)
- Snapshot: OpenAPI 3.1.0, wersja kontraktu `0.0.1`, 144 operacji, 294 schematów.
- SHA-256 pobranego JSON: `27de5afb635ac3f3be48f930d50716e11a6c46a5ac36fc24ad8eea1e6e3281a9`.
- Pełna powierzchnia HTTP jest określona jako eksperymentalna. Numer `0.0.1` jest wersją specyfikacji, nie dowodem wersji uruchomionego serwera.
- Poniższa mapa opisuje rzeczywiste operacje HTTP z oficjalnego kontraktu. `operationId` nie oznacza osobnego RPC. Jedynym ogólnym dispatcherem plugin RPC w tej mapie jest `/api/rpc/{rpcID}/{method}`.

## Pełna mapa endpointów

Parametry ścieżki pominięto w kolumnie parametrów; wynikają ze ścieżki. `*` oznacza wymagane pole. Kontrakty inline mogą zawierać dodatkowe struktury — przed implementacją należy czytać wskazany schemat JSON.

### server

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/info` | `server.info` | — | — |
| `POST /api/pair` | `server.pair` | — | — |
| `GET /auth/connect/{code}` | `server.connect` | — | — |

### location

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/location` | `location.get` | location | — |
| `POST /api/location/reload` | `location.reload` | — | — |

### agent

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/agent` | `agent.list` | location | — |
| `GET /api/agent/{agentID}` | `agent.get` | location | — |

### plugin

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/plugin` | `plugin.list` | location | — |
| `POST /api/plugin/check` | `plugin.check` | location | target |
| `POST /api/plugin/update` | `plugin.update` | location | targets* |

### session

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/session` | `session.list` | limit, order, search, parentID, directory, project, subpath, cursor | — |
| `POST /api/session` | `session.create` | — | id, parentID, title, agent, model, location, metadata, permissions |
| `GET /api/experimental/session/stats` | `experimental.session.stats` | from, to, project, timezone, tools | — |
| `POST /api/experimental/session/import` | `experimental.session.import` | — | info*, messages*, location |
| `GET /api/experimental/session/{sessionID}/export` | `experimental.session.export` | sanitize | — |
| `GET /api/session/active` | `session.active` | — | — |
| `GET /api/session/{sessionID}` | `session.get` | — | — |
| `DELETE /api/session/{sessionID}` | `session.remove` | — | — |
| `PATCH /api/session/{sessionID}` | `session.update` | — | title, metadata, permissions |
| `POST /api/session/{sessionID}/fork` | `session.fork` | — | before |
| `POST /api/session/{sessionID}/agent` | `session.switchAgent` | — | agent* |
| `POST /api/session/{sessionID}/model` | `session.switchModel` | — | model* |
| `POST /api/session/{sessionID}/move` | `session.move` | — | directory*, delivery |
| `POST /api/session/{sessionID}/prompt` | `session.prompt` | — | id, text*, files, agents, skills, metadata, delivery, resume |
| `POST /api/session/{sessionID}/command` | `session.command` | — | name*, text*, files, agents, skills, delivery |
| `POST /api/experimental/session/{sessionID}/skill` | `experimental.session.skill` | — | id*, resume |
| `POST /api/session/{sessionID}/synthetic` | `session.synthetic` | — | id, text*, description, metadata, delivery, resume |
| `POST /api/session/{sessionID}/shell` | `session.shell` | — | id, command* |
| `POST /api/session/{sessionID}/compact` | `session.compact` | — | id, delivery |
| `POST /api/experimental/session/{sessionID}/wait` | `experimental.session.wait` | — | — |
| `POST /api/session/{sessionID}/revert/stage` | `session.revert.stage` | — | messageID*, files |
| `DELETE /api/session/{sessionID}/revert` | `session.revert.clear` | — | — |
| `POST /api/session/{sessionID}/revert/commit` | `session.revert.commit` | — | — |
| `GET /api/session/{sessionID}/context` | `session.context` | — | — |
| `GET /api/session/{sessionID}/diff` | `session.diff` | from, to, context | — |
| `GET /api/session/{sessionID}/inbox` | `session.inbox.list` | — | — |
| `DELETE /api/session/{sessionID}/inbox/{inboxID}` | `session.inbox.cancel` | — | — |
| `PATCH /api/session/{sessionID}/inbox/{inboxID}` | `session.inbox.update` | — | delivery* |
| `GET /api/experimental/session/{sessionID}/instructions/entries` | `experimental.session.instructions.entry.list` | — | — |
| `PUT /api/experimental/session/{sessionID}/instructions/entries/{key}` | `experimental.session.instructions.entry.put` | — | value* |
| `DELETE /api/experimental/session/{sessionID}/instructions/entries/{key}` | `experimental.session.instructions.entry.remove` | — | — |
| `POST /api/session/{sessionID}/generate` | `session.generate` | — | prompt* |
| `GET /api/experimental/session/{sessionID}/log` | `session.log` | after, follow | — |
| `POST /api/session/{sessionID}/interrupt` | `session.interrupt` | resume | — |
| `POST /api/session/{sessionID}/background` | `session.background` | — | — |
| `GET /api/session/{sessionID}/message/{messageID}` | `session.message.get` | — | — |
| `GET /api/session/{sessionID}/form` | `session.form.list` | — | — |
| `POST /api/session/{sessionID}/form` | `session.form.create` | — | Form.CreatePayload |
| `GET /api/session/{sessionID}/form/{formID}` | `session.form.get` | — | — |
| `DELETE /api/session/{sessionID}/form/{formID}` | `session.form.cancel` | message | — |
| `POST /api/session/{sessionID}/form/{formID}/reply` | `session.form.reply` | — | Form.Reply |
| `PUT /api/session/{sessionID}/environment` | `session.environment` | — | variables* |
| `POST /api/session/{sessionID}/view` | `session.view` | — | idle* |
| `GET /api/session/{sessionID}/message` | `session.message.list` | limit, order, cursor, type | — |

### model

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/model` | `model.list` | location | — |
| `GET /api/model/default` | `model.default` | location | — |

### generate

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `POST /api/experimental/generate` | `experimental.generate.text` | — | prompt*, model |

### voice

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `POST /api/experimental/voice/session` | `experimental.voice.session` | — | model*, session, transport* |

### provider

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/provider` | `provider.list` | location | — |
| `GET /api/provider/{providerID}` | `provider.get` | location | — |

### integration

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/integration` | `integration.list` | location | — |
| `GET /api/integration/{integrationID}` | `integration.get` | location | — |
| `POST /api/experimental/integration/wellknown` | `experimental.integration.wellknown.add` | location | url* |
| `POST /api/integration/{integrationID}/connect/key` | `integration.connect.key` | location | key*, answer, label |
| `POST /api/integration/{integrationID}/connect/external` | `integration.connect.external` | location | methodID*, answer, label |
| `POST /api/integration/{integrationID}/connect/oauth` | `integration.oauth.connect` | location | methodID*, answer, label |
| `GET /api/integration/{integrationID}/connect/oauth/{attemptID}` | `integration.oauth.status` | location | — |
| `DELETE /api/integration/{integrationID}/connect/oauth/{attemptID}` | `integration.oauth.cancel` | location | — |
| `POST /api/integration/{integrationID}/connect/oauth/{attemptID}/complete` | `integration.oauth.complete` | location | code |
| `POST /api/integration/{integrationID}/connect/command` | `integration.command.connect` | location | methodID*, label |
| `GET /api/integration/{integrationID}/connect/command/{attemptID}` | `integration.command.status` | location | — |
| `DELETE /api/integration/{integrationID}/connect/command/{attemptID}` | `integration.command.cancel` | location | — |

### mcp

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/mcp` | `mcp.list` | location | — |
| `PUT /api/experimental/mcp/{server}` | `experimental.mcp.add` | location | config* |
| `DELETE /api/experimental/mcp/{server}` | `experimental.mcp.remove` | location | — |
| `POST /api/experimental/mcp/{server}/connect` | `experimental.mcp.connect` | location | — |
| `POST /api/experimental/mcp/{server}/disconnect` | `experimental.mcp.disconnect` | location | — |
| `GET /api/mcp/resource` | `mcp.resource.catalog` | location | — |

### credential

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/credential` | `credential.list` | — | — |
| `POST /api/credential` | `credential.create` | — | Credential.CreateInput |
| `PATCH /api/credential/{credentialID}` | `credential.update` | — | label* |
| `DELETE /api/credential/{credentialID}` | `credential.remove` | — | — |
| `POST /api/credential/{credentialID}/activate` | `credential.activate` | — | — |

### project

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/project` | `project.list` | archived | — |
| `PATCH /api/project/{projectID}` | `project.update` | — | canonical, name, icon, commands |

### form

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/form` | `form.list` | location | — |

### permission

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/permission/request` | `permission.request.list` | location | — |
| `GET /api/permission/saved` | `permission.saved.list` | projectID | — |
| `PATCH /api/permission/saved/{id}` | `permission.saved.update` | — | action, resource |
| `DELETE /api/permission/saved/{id}` | `permission.saved.remove` | — | — |
| `POST /api/session/{sessionID}/permission` | `session.permission.create` | — | id, action*, resources*, save, metadata, source, agent |
| `GET /api/session/{sessionID}/permission` | `session.permission.list` | — | — |
| `GET /api/session/{sessionID}/permission/{requestID}` | `session.permission.get` | — | — |
| `POST /api/session/{sessionID}/permission/{requestID}/reply` | `session.permission.reply` | — | decision*, message |

### filesystem

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/fs/read/*` | `fs.read` | location | — |
| `GET /api/fs/list` | `fs.list` | location, path | — |
| `GET /api/fs/find` | `fs.find` | location, query*, type, limit | — |
| `POST /api/experimental/fs/write` | `experimental.fs.write` | location, path* | application/octet-stream |

### command

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/command` | `command.list` | location | — |

### skill

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/skill` | `skill.list` | location | — |

### rpc

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `POST /api/rpc/{rpcID}/{method}` | `rpc.call` | location | Rpc.Input |

### event

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/event` | `event.subscribe` | — | — |

### pty

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/pty` | `pty.list` | location | — |
| `POST /api/pty` | `pty.create` | location | command, args, cwd, title, env |
| `GET /api/pty/{ptyID}` | `pty.get` | location | — |
| `PUT /api/pty/{ptyID}` | `pty.update` | location | title, size |
| `DELETE /api/pty/{ptyID}` | `pty.remove` | location | — |
| `POST /api/pty/{ptyID}/connect-token` | `pty.connect.token` | location | — |
| `GET /api/pty/{ptyID}/connect` | `pty.connect` | location[directory], cursor, ticket | — |

### persistentPty

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/experimental/session/{sessionID}/terminal/read` | `server.experimental.persistentPty.read` | lines | — |
| `GET /api/experimental/session/{sessionID}/terminal` | `server.experimental.persistentPty.list` | — | — |
| `POST /api/experimental/session/{sessionID}/terminal` | `server.experimental.persistentPty.create` | — | PersistentPty.CreateInput |
| `POST /api/experimental/persistent-pty/shutdown` | `server.experimental.persistentPty.shutdown` | — | — |
| `POST /api/experimental/persistent-pty/handoff` | `server.experimental.persistentPty.handoff` | — | — |
| `GET /api/experimental/persistent-pty/{ptyID}` | `server.experimental.persistentPty.get` | — | — |
| `PUT /api/experimental/persistent-pty/{ptyID}` | `server.experimental.persistentPty.update` | — | PersistentPty.UpdateInput |
| `DELETE /api/experimental/persistent-pty/{ptyID}` | `server.experimental.persistentPty.remove` | — | — |
| `GET /api/experimental/persistent-pty/{ptyID}/snapshot` | `server.experimental.persistentPty.snapshot` | — | — |
| `POST /api/experimental/persistent-pty/{ptyID}/connect-token` | `server.experimental.persistentPty.connectToken` | — | — |
| `GET /api/experimental/persistent-pty/{ptyID}/connect` | `persistentPty.connect` | cursor, role, attachment_id, takeover, input_protocol, ticket | — |

### shell

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/shell` | `shell.list` | location | — |
| `POST /api/shell` | `shell.create` | location | command*, cwd, timeout, metadata |
| `GET /api/shell/{id}` | `shell.get` | location | — |
| `DELETE /api/shell/{id}` | `shell.remove` | location | — |
| `GET /api/shell/{id}/output` | `shell.output` | location, cursor, limit | — |

### reference

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/reference` | `reference.list` | location | — |

### worktree

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/worktree` | `worktree.list` | projectID* | — |
| `POST /api/worktree` | `worktree.create` | — | Worktree.CreateInput |
| `DELETE /api/worktree` | `worktree.remove` | — | Worktree.RemoveInput |
| `POST /api/worktree/refresh` | `worktree.refresh` | — | projectID* |

### vcs

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `POST /api/vcs/init` | `vcs.init` | location, provider | — |
| `GET /api/vcs` | `vcs.get` | location | — |
| `GET /api/vcs/base` | `vcs.base` | location | — |
| `GET /api/vcs/status` | `vcs.status` | location | — |
| `GET /api/vcs/branch` | `vcs.branch.list` | location, search, limit | — |
| `GET /api/vcs/diff` | `vcs.diff` | location, mode*, base, context | — |

### debug

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/debug/location` | `debug.location.list` | — | — |
| `DELETE /api/debug/location` | `debug.location.evict` | location | — |

### migration

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/experimental/migration/v1` | `experimental.migration.v1.status` | — | — |

### websearch

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/websearch/provider` | `websearch.providers` | location | — |
| `POST /api/websearch` | `websearch.query` | location | query*, providerID |

### config

| Metoda i ścieżka | Operation ID | Query | Body: pola / schemat |
|---|---|---|---|
| `GET /api/config` | `config.get` | location | — |
| `GET /api/config/shell` | `config.shells` | — | — |
| `PATCH /api/experimental/config` | `experimental.config.update` | — | Config.Patch |

## Pochodzenie i reprodukcja

Pełny niezmodyfikowany snapshot JSON (589 797 bajtów) zapisano w [ResearchSources/opencode-v2-openapi-2026-10-19.json](ResearchSources/opencode-v2-openapi-2026-10-19.json). Pobrano publiczny adres `https://dev.opencode.ai/v2/openapi.json` przez HTTPS 2026-10-19; hash powyżej umożliwia sprawdzenie identyczności. To kontrakt opublikowany przez dokumentację, a nie introspekcja serwera użytkownika. Nie wykonywano żadnych mutacji na serwerze ani odczytów credentiali.

## Ważne rozróżnienie: HTTP, SDK, RPC i dawne indeksy

Aktualny kontrakt zawiera **worktree**, lecz nie zawiera CRUD **workspace**. Oficjalny audyt repozytorium wprost zapisuje usunięcie `POST /api/workspace` i `DELETE /api/workspace/{workspaceID}` z HTTP przy pozostawieniu wewnętrznej obsługi w core/embedded SDK. Ten audyt ma historyczną liczbę 139 operacji i datę regeneracji 2026-09-13, dlatego nie zastępuje aktualnego snapshotu 144 operacji. Zawiera też decyzje o usunięciu `/api/health`, `/api/server`, `/api/project/current` i config/preferences. [Źródło: audyt upstream](https://github.com/anomalyco/opencode/blob/dev/V2_HTTP_API_AUDIT.md).

W aktualnym JSON **nie ma** `vcs.patch`, osobnego HTTP commit/push/checkout, ogólnego HTTP wywołania narzędzia, MCP resource read/render ani endpointu do tworzenia pull requestów. Nazwa odnaleziona w dawnym indeksie routes/operations, typie SDK lub module wewnętrznym nie jest potwierdzeniem obecnego HTTP. `POST /api/rpc/{rpcID}/{method}` wywołuje metodę faktycznie zarejestrowanego pluginu; nie zamienia automatycznie wszystkich operacji core w publiczne RPC. Funkcje te można ewentualnie zbudować przez własny plugin lub kontrolowany shell, ale jest to dodatkowa integracja. [Źródło: pełny zbiór paths w OpenAPI](https://dev.opencode.ai/v2/openapi.json).

## Kontrakty o największym znaczeniu produktowym

### Kolejka pracy i sterowanie agentem

`prompt` przyjmuje `text`, opcjonalne `files`, `agents`, `skills`, `metadata`, `id`, `delivery`, `resume`. Delivery ma dokładnie wartości `steer` i `queue`; `resume=false` zapisuje wejście bez automatycznego wznowienia pętli. Inbox jest trwały i zawiera typy user, synthetic, compaction, move, uporządkowane kolejnością przyjęcia. **PATCH inbox zmienia wyłącznie delivery**. Nie ma aktualizacji treści ani dowolnego przestawienia kolejności. UX może oferować „wyślij teraz jako steering”, „zostaw w kolejce” i „anuluj”. Edycja przez anulowanie i ponowne dodanie wymaga obsługi wyścigu z dostarczeniem; nie jest atomową edycją. `interrupt` z `resume=true` wznawia steering i kontrolne compaction/move, pozostawiając queued prompts zaparkowane. [Źródło: Session.Inbox.Delivery i operacje session.prompt/inbox/interrupt](https://dev.opencode.ai/v2/openapi.json).

### Fork, przeniesienie i cofnięcie

Fork przyjmuje opcjonalne `before` — historię kopiuje **przed** wskazaną wiadomością; brak pola kopiuje całość. Jest potomną sesją z relacją do źródła. Kontrakt nie obiecuje utworzenia worktree ani odtworzenia plików na stan historyczny. Produkt „spróbuj alternatywnego rozwiązania w izolacji” wymaga odrębnego worktree i świadomego ustawienia lokalizacji. `move` przyjmuje absolutny `directory` oraz delivery; nie jest obietnicą transferu lokalnych zmian Git. Revert ma etap `stage(messageID, files?)`, anulowanie przez DELETE i osobny commit. Warto pokazać granicę cofnięcia i pliki przed zatwierdzeniem. [Źródło: session.fork/move/revert oraz Worktree.CreateInput](https://dev.opencode.ai/v2/openapi.json).

### Kontekst, kompakcja i trwałe instrukcje

`context` zwraca aktywną projekcję wiadomości od ostatniej kompakcji. Nie należy opisywać jej jako dokładnego surowego requestu dostawcy ani całego finalnego system promptu. `compact` jest trwałym poleceniem; domyślnie steering, wykonywanym na granicy kroku. API-managed instructions entries mają osobne list/put/remove, trwałe klucze i ogłaszanie zmian przy następnej granicy kroku. To dobra baza dla „stałych zasad tej sesji”, ale nie edytor wszystkich AGENTS.md. `session.generate` tworzy tekst z kontekstu bez mutacji historii — dobry kandydat do „podsumuj postęp”, „wyjaśnij decyzję”, „przygotuj handoff”. Generacja jest nadal wywołaniem modelu, a brak zmiany historii nie oznacza braku kosztu. [Źródło: session.context/compact/generate i experimental.session.instructions.entry.*](https://dev.opencode.ai/v2/openapi.json).

### Wiadomości, stan odczytania i odporność na rozłączenia

Typy osi czasu obejmują także wybór modelu/agenta, zmianę lokalizacji, skill, shell, synthetic, system, compaction oraz idle. Interfejs renderujący wyłącznie user/assistant traci zdarzenia tłumaczące przebieg zadania. Session.Info zawiera cost, tokens, outcome oraz time.idle/viewed/archived, lecz samo występowanie archived w odczycie nie dowodzi publicznego mutatora archiwizacji: session.update pozwala na title, metadata, permissions. `session.view` wymaga watermark `idle`, co pozwala uniknąć oznaczenia nowego wyniku jako przeczytanego przez spóźniony request. Lista wiadomości ma paginację i filtr type, który trzeba utrzymać na kolejnych stronach. [Źródło: Session.Info, Session.Message.Info, session.view i message.list](https://dev.opencode.ai/v2/openapi.json).

Globalne `GET /api/event` jest ulotne: rozłączenie gubi zdarzenia, a zbyt wolny odbiorca może przepełnić strumień. Nie wystarczy więc sam reconnect. Eksperymentalny session log czyta po wyłącznym numerze sekwencji `after` i ma `follow=true`; daje podstawę odzyskiwania strumienia konkretnej sesji. Należy nadal odświeżać snapshoty sesji, inbox, pending forms i permissions. `session.active` oznacza pętle foreground należące do tego procesu, nie wszystkie istniejące/background zadania na dowolnym serwerze. [Źródło: event.subscribe, session.log, session.active](https://dev.opencode.ai/v2/openapi.json).

### Review kodu i przeglądarka plików

`session.diff` daje strukturalne różnice per plik dla zakresu tur. Tura obejmuje prompty skierowane podczas pracy aż do idle; diff nie jest koniecznie „zmianami jednej dymkowej wiadomości”. Zakres przekraczający zmianę lokalizacji jest odrzucany. `vcs.diff` rozróżnia `working`, `branch`, `committed`, z opcjonalnym base i context. Review base może być null lub niejednoznaczny — potrzebny wybór bazowej gałęzi. Warto budować kartę „Co zmienił agent?” i review zmian branch/working bez udawania obsługi stage/commit/push. [Źródło: session.diff, vcs.diff/base](https://dev.opencode.ai/v2/openapi.json).

Read pliku zwraca surowe bajty, obsługuje ETag, Last-Modified, HTTP Range, 206/304/416. Nadaje się do podglądu kodu, obrazów i artefaktów oraz cache. List może wychodzić do rodziców i rodzeństwa lokalizacji. Eksperymentalny write zapisuje raw request body i tworzy katalogi nadrzędne, także poza lokalizacją. Nie ma potwierdzonej atomowej ochrony przed równoległą edycją przez agenta; przed udostępnieniem edytora trzeba zdefiniować konflikt i backup. `find` jest wyszukiwaniem wpisów filesystemu, nie obietnicą pełnotekstowego ripgrep. [Źródło: fs.read/list/find i experimental.fs.write](https://dev.opencode.ai/v2/openapi.json).

### Worktree i projekty

Create worktree wymaga projectID; opcjonalnie przyjmuje from, branch, directory, name. Uruchamia strategię z kanonicznej konfiguracji projektu i skrypt setup. List to zapisany inventory; refresh odkrywa stan fizyczny i go uzgadnia. Projekt może przechowywać metadata i workspace commands, ale nie daje to publicznego API provider-backed workspace. Warto pokazać koszt/stan przygotowania oraz możliwość odświeżenia listy. VCS init obsługuje wybrany provider, domyślnie Git; nie każdy provider implementuje init. [Źródło: Worktree.CreateInput i worktree.*, project.*, vcs.init](https://dev.opencode.ai/v2/openapi.json).

### Terminal, shell i podgląd aktywnego procesu

Są trzy odmienne powierzchnie: zwykłe PTY z WebSocketem, persistent PTY powiązane z sesją oraz noninteractive shell z zapisem stdout/stderr do stronicowanego pliku. Zwykłe PTY ma token jednorazowego połączenia i zachowuje zakończone wpisy do usunięcia. Shell output używa absolutnego kursora bajtowego, a lista shell pokazuje tylko running. Persistent terminal read daje fizyczne wiersze, rozmiar i kursor bez przejmowania sterowania; może zwrócić null, a wybór bieżącego terminala resetuje się przy restarcie. `ServerInfo.capabilities.persistentPty` umożliwia wykrycie obsługi. Snapshot persistent PTY zawiera tekst i checkpoint base64. To pozwala zacząć od prostego „pokaż terminal agenta”, a pełny emulator z wejściem potraktować jako osobny etap. [Źródło: pty.*, shell.*, PersistentPty.*, ServerInfo](https://dev.opencode.ai/v2/openapi.json).

### Integracje, MCP i sekrety

Integrations obsługują key, external credentials, OAuth z pollingiem i completion dla odpowiednich metod, oraz command authentication z pollingiem i cancel. Można pokazywać dostępne metody zamiast zakładać jeden uniwersalny OAuth. MCP list pokazuje stan, resource catalog udostępnia resources/templates; mutacje experimental MCP są runtime i nie gwarantują trwałego zapisu po restarcie. `credential.list` według kontraktu zwraca także wartości sekretów — nie wolno traktować go jako niewinnej listy etykiet ani wrzucać pełnych odpowiedzi do telemetryki. Przełączanie aktywnego credentialu może być funkcją mobilną, ale wymaga ostrożnego projektu przepływu danych. [Źródło: integration.*, mcp.*, credential.*](https://dev.opencode.ai/v2/openapi.json).

### Głos: czego API rzeczywiście dostarcza

`POST /api/experimental/voice/session` bierze `model`, opcjonalny object `session`, i transport. Dla WebRTC wymaga SDP i opcjonalnego dcid, zwraca SDP answer. Dla WebSocket zwraca url, token i expiresAt. Serwer brokeruje połączenie na podstawie skonfigurowanych provider credentials. **Brak wymaganego sessionID OpenCode** oznacza, że ten endpoint sam nie potwierdza gotowej konwersacji głosowej sterującej konkretną sesją kodującą. OpenLens musi dodać audio transport, uprawnienia mikrofonu, UX połączenia, mapowanie transkryptu/komend na sesję oraz obsługę możliwości providera. To większy projekt niż prosty przycisk do transkrypcji. [Źródło: VoiceSessionResponse, VoiceTransportInput, VoiceTransport](https://dev.opencode.ai/v2/openapi.json).

### Statystyki i koszty

Stats przyjmuje from/to, project, timezone oraz tools=`none|summary|detail`. Schemat zawiera sessions, subagents, prompts, steps, tokens, cost, activeDays, streak, activity i rozkład modeli; tools obejmuje statystyki niezawodności. Daje bazę dashboardu aktywności i kosztów po projektach oraz okresach. To lokalna agregacja danych sesji, nie rachunek dostawcy, saldo subskrypcji ani kwota pozostałego limitu. Dla nieznanych kosztów/modeli należy unikać pozornej precyzji. [Źródło: experimental.session.stats, SessionStats.Info](https://dev.opencode.ai/v2/openapi.json).

### Eksport/import, permissions i formularze

Eksport zwraca projected transcript i parametr sanitize; import wymaga info/messages, opcjonalnie location, a rodzic musi istnieć przed importem dziecka. Nie jest to kopia całego projektu, worktree, plików i wszystkich sekretów ani dowód odtwarzania dokładnego event logu. Dobrze pasuje do przenośnego archiwum rozmowy. Saved permissions można listować, edytować action/resource i usuwać; pending requests odpowiadają decision `once|always|reject`. Formularze mają listę globalną i per sesja, odczyt definicji/stanu, reply i cancel. Możliwy jest mobilny „inbox decyzji”, nie tylko modal w aktywnym czacie. [Źródło: experimental.session.import/export, permission.*, session.form.*](https://dev.opencode.ai/v2/openapi.json).

## Luki i ograniczenia wymagające jawnego opisu w roadmapie

- Brak potwierdzonego publicznego APNs/push registration, harmonogramu cron i background notification relay. To komponent OpenLens/backend, nie darmowa funkcja SSE.
- Brak HTTP CRUD workspace providerów, commit/push/stage/cherry-pick/PR oraz uniwersalnej obsługi remote host transfer.
- Config.Patch obecnie ma wyłącznie `shell`; nie należy obiecywać dowolnego ustawiania modeli, providerów, MCP i policy przez ten endpoint.
- Skills list i aktywacja istnieją, ale nie ma dedykowanego CRUD ani instalatora skillów w HTTP. Ewentualna instalacja przez zapis plików jest odrębnym procesem.
- Fork nie jest snapshotem filesystemu; move nie gwarantuje przeniesienia zmian; import nie jest pełnym backupem środowiska.
- Pomysły „edycja kolejki” i „drag-to-reorder” wykraczają poza PATCH inbox; obsługiwana jest jedynie zmiana delivery i anulowanie.
- Aktualny JSON nie ustanawia minimalnej wersji serwera dla każdej operacji. Trzeba przetestować konkretny wspierany build, obsłużyć 404/501 i zbudować kontrolę możliwości.

Powyższe ograniczenia wynikają z zakresu aktualnego [OpenAPI](https://dev.opencode.ai/v2/openapi.json), a nie twierdzenia, że dana funkcja nigdy nie będzie istniała w OpenCode.
