# OpenCode V2: zweryfikowane zmiany API względem V1

Data odczytu: 2026-10-05. Zakres: kontrakt serwera dla zewnętrznego klienta iOS. Research nie zmienia kodu aplikacji i nie potwierdza działania z konkretnym żywym serwerem.

## Punkt odniesienia i wiarygodność źródeł

Aktualne oficjalne pakiety `@opencode/cli`, `@opencode/client` i `@opencode/core` mają tag `latest` **2.0.23**. Wydanie CLI opublikowano 5 października 2026 o 05:26 UTC. GitHub tag **v2.0.23** wskazuje commit **0fd7e2829449b052abf0078666669302923d77af**, utworzony o 05:24:37 UTC. Źródła poniżej są przypięte do tego wydania. [Metadata CLI](https://registry.npmjs.org/@opencode%2fcli/2.0.23), [metadata klienta](https://registry.npmjs.org/@opencode%2fclient/2.0.23), [rewizja wydania](https://github.com/anomalyco/opencode/commit/0fd7e2829449b052abf0078666669302923d77af).

Publiczne [OpenAPI V2](https://opencode.ai/v2/openapi.json), pobrane tego dnia, zawiera 117 ścieżek i 141 operacji; SHA-256: `0612418392961ef22f0337ce0e1e520270917665fc85f29c4af1c94d1e1873ee`. `info.version=0.0.1` to wersja dokumentu API, nie wersja binarki. Konkretną instalację identyfikuje `GET /api/info`. Opis OpenAPI nadal zawiera „Experimental HttpApi”; część endpointów jest jawnie eksperymentalna.

**Nie należy nazywać obecnego wydania V2 betą na podstawie starego dev site.** Kanoniczna [migracja](https://opencode.ai/v2/docs/migrate-v1/) opisuje released V2 API i pakiet `@opencode/client`. `dev.opencode.ai` oraz gałąź `dev` mają wcześniejsze kontrakty z `@opencode-ai/client`, `opencode2`, zagnieżdżonym `prompt` i starszymi ścieżkami. Obie obecne generacje używają binarki `opencode`.

W tym raporcie **V1** oznacza legacy, nieprefiksowane API obsługiwane także przez pakiet o mylącej nazwie `@opencode-ai/sdk/v2`. Porównano jego kontrakty z tagu `v1.18.34`. To wydanie miało również hybrydowe eksperymenty `/api/*`; ich obecność nie zamienia legacy SDK w klienta released OpenCode 2. [V1 OpenAPI](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/sdk/openapi.json), [checklista starej migracji](https://github.com/anomalyco/opencode/blob/dev/packages/app/V1_API_MIGRATION.md).

## Funkcje i zmiany istotne dla klienta

### 1. Trwały inbox i jawne queue/steer — rozszerzony kontrakt sterowania

V2 `POST /api/session/:id/prompt` zapisuje zadanie i zwraca `{data: Inbox.User}`; nie jest obietnicą gotowej odpowiedzi asystenta. Payload jest płaski: `id`, `text`, `files`, `agents`, `skills`, `metadata`, `delivery`, `resume`. Domyślne `delivery` to `steer`; domyślne `resume` uruchamia lub budzi wykonanie. `resume:false` pozwala przyjąć pracę bez jej uruchamiania. [Handler promptu](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/handlers/session.ts#L306), [admission](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/session.ts#L155).

`steer` dostarcza dodatkową treść na granicy kroku obecnej pracy; `queue` czeka na kolejną turę. Inbox jest trwały i wspólny dla klientów. Obejmuje `user`, `synthetic`, `compaction`, `move`, z ID, payload, delivery i czasem. Można odczytać pending items, anulować niedostarczony wpis lub zmienić jego tryb. Nie ma dowolnego sortowania kolejki ani aktualizacji jej tekstu. Steering ma pierwszeństwo; move tworzy granicę, której promocja innych wpisów nie przekracza. [Inbox, promocja i mutacje](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/inbox.ts), [typy inboxa](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/session-inbox.ts).

Idempotencja promptu opiera się na stabilnym caller ID: pierwsze przyjęcie wygrywa dla tej samej sesji i typu. Powtórzenie może zwrócić istniejący wpis, także po jego promocji do wiadomości, bez ponownego przygotowywania plików. Zmieniony tekst z tym samym ID **nie edytuje** wcześniejszego promptu. Nie znaleziono liczbowego limitu exact retries w tym kontrakcie; polityka ponowień należy do klienta. Niepewny timeout nie dowodzi braku przyjęcia. [Reconcile](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/inbox.ts#L152).

To formalizuje i rozszerza wcześniejsze wysyłanie podczas generowania. V1 miało prompt synchroniczny, `prompt_async` i `noReply`; samo wysyłanie asynchroniczne nie jest nowością V2. [V1 server API](https://opencode.ai/docs/server/#messages).

### 2. Cancel, interrupt i background są różnymi czynnościami

Cancel usuwa pending inbox input; niedostępny wpis jest no-op. Interrupt zatrzymuje aktywne wykonanie należące do bieżącego procesu; przy bezczynności zwraca `interrupted:false`. Przyjęcie przerwania nie oznacza zakończenia wszystkich finalizerów. `resume=true` to parametr query: wznowi steering i najbliższe control items, ale pozostawi queued prompts. Stop nie powinien być przedstawiany jako automatyczne usunięcie całej kolejki. [Wykonanie](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/execution.ts#L20).

`POST .../background` zwraca **204**, jest no-op przy bezczynności i przenosi aktywne foreground **backgroundable tools** do obserwacji w tle. Nie dotyczy dowolnego procesu ani działania aplikacji iOS w tle. [Kontrakt](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/session.ts#L745), [Job.block/background](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/job.ts#L328).

### 3. Kanoniczny stan sesji i bogatsza historia

Sesja ma osobne `agent`, `model` z `variant`, sumy `cost/tokens`, ostatni `outcome` oraz `time.idle/viewed`. Model i agent zmieniane są oddzielnymi operacjami. Ostatnia odpowiedź asystenta nie jest wiarygodnym odczytem obecnego wyboru na innym kliencie. `outcome` oznacza ostatnie zakończone wykonanie; sam w sobie nie opisuje aktualnego oczekiwania na zgodę. `POST .../view` z obserwowanym `idle` obsługuje przeczytanie zakończenia. [Session.Info](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/session.ts).

Timeline obejmuje `user`, `assistant`, `agent-switched`, `model-switched`, `location-switched`, `synthetic`, `system`, `skill`, `shell`, `compaction` oraz **`idle`**. Idle grupuje kroki w turę, także dodatkowe prompty steered podczas pracy. Shutdown nie zapisuje idle: wznowienie kontynuuje tę samą turę. `assistant.time.streamed` i `completed` też opisują różne momenty. Pomijanie wszystkich typów poza user/assistant usuwa istotne wyniki i historię zmian. [Session.Message](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/session-message.ts).

### 4. Native SSE: nowe słownictwo, nadal konieczny recovery

`GET /api/event` emituje native events we wspólnym streamie wszystkich lokalizacji, także plugin RPC. Payload ma `id/type/data` i opcjonalną lokalizację/metadane; część durable events ma aggregate sequence. To inne koperty niż V1 `properties` i globalny wrapper `payload`. [Event contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/event.ts).

**Ten stream nie replayuje luk.** Serwer wysyła `data:` frames, `server.connected` i heartbeat co 15 sekund. Zdarzenia podczas rozłączenia przepadają, a przekroczenie 4096 oczekujących frames odbiorcy zamyka stream. ID w JSON nie zapewnia obsługi `Last-Event-ID`. Klient powinien odbudować stan przez REST: sesja, active snapshot, historia, inbox, pending forms/permissions i katalogi właściwej lokalizacji. To rekomendacja wynikająca z ulotnego transportu. [EventFeed](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/event-feed.ts), [SSE handler](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/handlers/event.ts).

Osobno istnieje eksperymentalny **durable session log**: `GET /api/experimental/session/:id/log?after=N&follow=true`. `after` jest exclusive aggregate sequence; wynik obejmuje durable session events i `EventLog.Synced`. To selektywny replay jednej sesji, nie replay całego `/api/event`, uprawnień ani formularzy. [Session.log](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session.ts#L408).

### 5. Formularze zamiast ograniczonego modelu pytań

V1 pytania, multiple choice i odpowiedzi już istniały. V2 uogólnia je do forms: string, number, integer, boolean, multiselect, external URL, constraints, defaults, opcje custom i warunkowe `when`. Stan to pending/answered/cancelled. Nieaktywne pola nie są wymagane ani dopuszczone do odpowiedzi. MCP elicitation może obecnie mieć właściciela `sessionID:"global"`; schemat celowo nie ogranicza go do ID sesji. Interakcje te trzeba rozróżniać od trwałych wiadomości. [Form schema](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/form.ts), [V1 question contract](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/sdk/openapi.json).

### 6. Uprawnienia — precyzyjniejszy zakres i zarządzanie zgodami

Zgoda once/always/reject występowała w V1. V2 używa uporządkowanych reguł `action/resource/effect`, ostatnie dopasowanie wygrywa. `bash→shell`, `task→subagent`, `write/patch→edit` to nazwy akcji. Request ma `resources`, proponowane `save`, `source` i opcjonalną wiadomość; publiczne API umożliwia odczyt oraz usuwanie zapisanych zgód. Always zapisuje allow dla projektu; nie uchyla deny. Reject może przekazać feedback i odrzuca też inne pending permission requests tej sesji. [Permissions](https://opencode.ai/v2/docs/permissions/), [Permission schema](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/permission.ts).

### 7. Subagenci: zmienione nazwy, wyniki i powiązania

Actual wbudowana nazwa narzędzia V2 to **`subagent`**, nie `task`; pole kontynuacji to `sessionID`, nie V1 `task_id`. Foreground jest domyślny, `background:true` zwraca wcześniej. Progress metadata zawiera `sessionID/status`; typowany wynik narzędzia ma `status:"completed"|"running"`. Wywołanie może zakończyć się poprawnie ze statusem **running**, podczas gdy dziecko pracuje dalej. [Subagent tool](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/tool/plugin/subagent.ts).

Wynik tła trafia do rodzica jako **synthetic** z metadata `{source:"subagent", childID, agent, state}` oraz treścią wyniku/błędu/anulowania. Dziecko jest osobną sesją z `parentID`; powiązanie pozwala otworzyć rozmowę i jej pending requests. [Dostarczenie wyniku](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/subagent-completion.ts).

**Subagenci ani sam background nie są absolutnie nowe:** V1 1.18.34 `task` już obsługiwało foreground, background, kontynuację i automatyczne powiadomienie. Nowe dla integracji są nazwy, payloady, lifecycle i native timeline. [V1 task](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/tool/task.ts).

### 8. Location, worktree, move i fork

Obecny klient terminalowy domyślnie łączy się ze wspólną usługą użytkownika, która obsługuje różne katalogi. Publiczne zasoby zależne od katalogu używają location; query ma format `location[directory]`, a część odpowiedzi `{location,data}`. Lokalne ścieżki zawsze należą do maszyny serwera. [Usługa](https://opencode.ai/v2/docs/cli/#background-service), [Location contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/location.ts).

V1 miało eksperymentalne worktrees. V2 ma `/api/worktree` list/create/remove oraz refresh. **Move sesji** zapisuje control item i przełącza lokalizację na granicy kroku; nie jest kopiowaniem plików ani tworzeniem worktree. Klient powinien po move odświeżyć katalogi modeli/agentów/komend, pliki i VCS. [Worktree contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/worktree.ts), [SessionMove](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/move.ts).

Fork istniał w V1. V2 `before` jest exclusive; bez niego kopiowana jest historia przez ostatnią wiadomość. Actual fork ma **`parentID` nieustawione** oraz osobne `fork:{sessionID,boundary}`. Nie jest sesją subagenta ani izolacją plików. Dziedziczy aktualny model/agent/permissions/metadata i aktualne instruction values, nie wszystkie ustawienia z historycznej granicy. Kopiuje tylko settled projekcje assistant/shell/compaction. [Tworzenie fork](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session.ts#L319), [fork projector](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/projector.ts#L117).

### 9. Undo, diffs, compaction i checkpoints

Undo i snapshots istniały wcześniej. V2 rozróżnia stage/clear/commit. Stage domyślnie może od razu przywrócić pliki; `files:false` ogranicza operację do historii. Clear przywraca staged rollback. Nowy poprawnie przygotowany prompt automatycznie commits wcześniejszy stage. Cofnięcie nie jest bezpiecznym usunięciem durable logu. [Revert](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/revert.ts), [Snapshots](https://opencode.ai/v2/docs/snapshots/).

`GET .../diff?from=<messageID>&to=<messageID>` porównuje snapshot początku tury z końcem zakresu. Kilka steered prompts należy do jednej tury; active step może porównywać working copy. Zakres przekraczający zmianę lokalizacji jest odrzucany. Nie utożsamiać tego z `GET /api/vcs/diff`, który porównuje Git w trybach working/branch/committed. [SessionDiff](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/diff.ts), [VCS contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/vcs.ts).

Compaction V2 jest przyjmowaną pracą z lifecycle/events i historią statusu, podsumowania oraz recent context. `GET .../context` odczytuje aktywny kontekst; API-managed instruction entries i generation bez zmiany historii mają osobne eksperymentalne ścieżki. Native compaction może używać providerowego checkpointu: nie należy mylić go z snapshotem plików. Checkpoint jest powiązany z provider/model/endpoint; po zmianie modelu używana jest oryginalna rozmowa. Historyczne sumy tokenów nie mierzą zajętości obecnego kontekstu. [Compaction](https://opencode.ai/v2/docs/compaction/), [InstructionEntry](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/core/src/session/instruction-entry.ts), [provider context](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/session-provider-context.ts).

### 10. Załączniki, wyniki narzędzi i nowe możliwości administracyjne

Załączniki i obrazy nie są nowością, ale V2 input używa `uri`, opcjonalnego name/description/mention; historia ma już `data/mime/source`. Z telefonu używać `data:`; `file:` czyta plik serwera. HTTP(S) attachments są niewspierane. Model otrzymuje UTF-8, listing katalogu lub PNG/JPEG/GIF/WebP. Direct PDF, audio, wideo i inne unsupported binary attachments nie są przekazywane jako widoczne wejście. Limit to 20 MiB decoded per item, oddzielny od limitów klienta/relay/provider. [Attachments](https://opencode.ai/v2/docs/attachments/).

Wynik narzędzia ma tablicę **content** z text i file (`uri/mime/name`) oraz metadata, zamiast polegania na samym tekstowym output. UI powinno zachować pliki/obrazy także przy tool failure; generyczny renderer jest konieczny dla pluginów i Code Mode. [Tool.Content](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/schema/src/tool.ts).

V2 rozdziela integrations, credentials, provider i model catalogs, z attempts dla OAuth/command auth oraz osobnym zarządzaniem MCP. MCP i OAuth istniały wcześniej; nowe są ujednolicone lifecycle i zarządzanie credentials. Modele zachowują capabilities, variants, status; stock `/api/model` **filtruje `enabled=true`** przez `models.available()`, więc ignorowanie enabled w DTO nie jest samo w sobie dowodem, że można wybrać disabled model. [Integration contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/integration.ts), [MCP contract](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/mcp.ts), [model handler](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/handlers/model.ts).

File browser, Git diff, shell i PTY także istniały w V1. V2 ma location-scoped `/api/fs/*`, w tym bezpośredni write, osobny shell lifecycle/output oraz **eksperymentalny persistent PTY** z snapshotami i read terminala sesji. PTY używa WebSocket i short-lived single-use tickets; terminal cursor nie jest cursorem event replay. Persistent PTY może być niedostępne; sprawdzać capability z `/api/info`. [Filesystem](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/fs.ts), [shell](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/shell.ts), [PTY](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/pty.ts), [persistent PTY](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/protocol/src/groups/persistent-pty.ts).

Nowe pairing: `POST /api/pair`, jednorazowy `/auth/connect/:code`; klient API otrzymuje `{token}`. Token używany jest jako **password w Basic Auth** z username `opencode`, ma ważność 30 dni, a zmiana hasła serwera go unieważnia. Nie nazywać tego tokenem provider API ani zakładać Bearer na podstawie przykładowego nagłówka klienta. [Auth](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/auth.ts), [pairing handler](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/handlers/server.ts).

### 11. Kompatybilność helpera CLI

`opencode serve --port 4096 --hostname ...` nadal działa według kontraktu CLI 2.0.23; nie trzeba zastępować go `service start`. Ręczny serve honoruje `OPENCODE_PASSWORD` oraz legacy fallback `OPENCODE_SERVER_PASSWORD`. Username Basic Auth jest stałe **`opencode`**; własne `OPENCODE_SERVER_USERNAME` nie zmienia go w obecnym serwerze. [Komendy](https://raw.githubusercontent.com/anomalyco/opencode/0fd7e2829449b052abf0078666669302923d77af/packages/cli/src/commands/commands.ts), [env CLI](https://raw.githubusercontent.com/anomalyco/opencode/0fd7e2829449b052abf0078666669302923d77af/packages/cli/src/env.ts), [uruchamianie serwera](https://raw.githubusercontent.com/anomalyco/opencode/0fd7e2829449b052abf0078666669302923d77af/packages/cli/src/server-process.ts), [username serwera](https://github.com/anomalyco/opencode/blob/v2.0.23/packages/server/src/auth.ts#L20).

Zmieniono jednak podłączanie TUI: obecna kompletna specyfikacja nie rejestruje komendy `attach` ani flagi `--password`. Klient uruchamia się przez `opencode --server URL --continue`, pobierając hasło z powyższych zmiennych środowiska. Source connection potwierdza Basic Auth i jawny adres serwera. Helper używający `opencode attach URL --continue --password ...` wymaga dopasowania osobno od nadal obsługiwanego serve. Po zmianie potrzebny jest test uruchomienia, sprawdzający czy TUI i telefon wskazują tę samą instancję. To zalecenie integracyjne; w tej pracy nie uruchamiano TUI. [Specyfikacja CLI](https://raw.githubusercontent.com/anomalyco/opencode/0fd7e2829449b052abf0078666669302923d77af/packages/cli/src/commands/commands.ts), [ServerConnection](https://raw.githubusercontent.com/anomalyco/opencode/0fd7e2829449b052abf0078666669302923d77af/packages/cli/src/services/server-connection.ts).

## Ograniczenia obecnego V2

- **Sharing nie jest jeszcze obsługiwane.** Export/import historii nie jest odpowiednikiem publicznego share link. [Sharing](https://opencode.ai/v2/docs/sharing/).
- **LSP nie działa w V2** mimo akceptowania konfiguracji; nie ma narzędzi ani diagnostyk language servers. Należy używać lint/typecheck/compiler. Nie ma też publicznych legacy odpowiedników todo ani mutacji pojedynczych message parts. [Migracja](https://opencode.ai/v2/docs/migrate-v1/#supported-fields-without-direct-native-equivalents), [API](https://opencode.ai/v2/docs/api).
- Per-agent `request` jest zachowywane, ale current runner nie wysyła tych overlays do model request; aktywne ustawienia konfigurować na provider/model/variant. [Agents](https://opencode.ai/v2/docs/agents/#request).
- Snapshoty są best effort, wymagają Git i dotyczą aktywnego directory; nie odwracają side effects shell ani zmian poza tym zakresem. [Snapshots](https://opencode.ai/v2/docs/snapshots/).
- Nowe plugin API wymaga portowania pluginów V1; iOS konsumuje ich wyniki/RPC, nie wykonuje ich implementacji. V1 config jest normalizowane, ale natywne nazwy V2 różnią się: agents/providers/commands/permissions/skills, `media`, model variants i `compaction.keep.tokens`. [Migracja pluginów](https://opencode.ai/v2/docs/build/plugins/migrate-v1/), [migracja config](https://opencode.ai/v2/docs/migrate-v1/).

## Krótka lista zmienionych kontraktów

| Legacy V1 | Released V2 | Zmiana klienta |
| --- | --- | --- |
| `/global/health`, `/path` | `/api/info`, `/api/location` | Version/capabilities i lokalizacja |
| `/global/event`, `/event` | `/api/event` | Native payload; REST recovery, brak global replay |
| `/session/status` | `/api/session/active` + Session.Info outcome | Active i outcome to różne dane |
| `/session/:id/message`, `/prompt_async` | `/api/session/:id/prompt` | Płaski input, durable Inbox response |
| Brak publicznego durable inbox control | `/api/session/:id/inbox/*` | Read/cancel/change delivery, bez text edit/reorder |
| Prompt.model/agent | Session.model/agent + `/model`, `/agent` | Zachować kanoniczny wybór i wariant |
| `/abort` | `/interrupt?resume=...` | Przerwanie wykonania, nie wyczyszczenie inboxa |
| `task`, `task_id` | `subagent`, `sessionID` | Metadata i synthetic completion |
| `/question/*` | `/api/form`, `/api/session/:id/form/*` | Typed forms i constraints |
| `/permission`, reply | `/api/permission/request`, saved, session reply | Resources/save/source/feedback |
| `/revert`, `/unrevert` | `/revert/stage`, DELETE `/revert`, `/revert/commit` | Odwracalny etap + możliwość przywracania plików |
| `/fork` z messageID | `/fork` z before | Exclusive boundary i osobne fork ancestry |
| `/summarize` | `/compact` | Przyjęcie zadania; wynik później |
| `/file`, `/file/content`, `/find/file` | `/api/fs/list`, `/api/fs/read/*`, `/api/fs/find` | Location query; odczyt i write |
| `/experimental/worktree` | `/api/worktree` | Publiczne operacje + osobne session move |
| `/auth/:provider`, provider OAuth | integration attempts + credentials | Nowy lifecycle logowania |
| `/pty/*` | `/api/pty/*`; experimental persistent PTY | WebSocket/ticket i opcjonalne capability |
| `opencode attach URL --password ...` | `opencode --server URL`, hasło przez env | Zmiana helpera TUI; serve nadal obsługiwane |

Tabela jest indeksem zmian opisanych i zacytowanych powyżej, a nie zaleceniem implementacji całej powierzchni API. Priorytety wynikające z obecnego OpenLens zapisuje osobny [raport luk](OPENCODE_V2_OPENLENS_GAP_ANALYSIS.md).
