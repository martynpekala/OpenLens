# 13: Czytelne potwierdzenie undo (zakres zawężony)

**What to build:** Przed cofnięciem użytkownik widzi granicę i wybiera: tylko historia albo historia + pliki.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

**Zawężono 2026-10-21:** Obecne `/undo` (`ChatClient.undo` → `OpenCodeClient.revertMessage`) od razu wykonuje `revert/stage` z `files: true` i `revert/commit`, bez wyjaśnienia i wyboru. Pełny cykl stage/clear/commit z obietnicą przywrócenia nie wchodzi w zakres: semantyka odtworzenia przez `clear` nie jest potwierdzona kontraktem, a widoczny stan „staged” komplikuje sesję bez proporcjonalnej korzyści. Szczegóły: [draft ticketów](../../../OpenLens/Playbook/OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md).

- [ ] Przed wykonaniem widoczna jest granica (od której wiadomości); użytkownik wybiera `files: false` (tylko historia) albo `files: true` (historia + pliki), po czym commit jak dotąd.
- [ ] Komunikat uprzedza, że wariant z plikami zmienia dysk i nie jest podglądem.
- [ ] Busy, konflikt i utrata odpowiedzi kończą się kanonicznym odczytem sesji/diffu, a nie domniemanym sukcesem; nie wymaga nowego branch review ani stanu „staged” w UI.
- [ ] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [ ] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [ ] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [ ] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [ ] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [ ] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [ ] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [ ] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: 26 (tylko potwierdzenie). User stories specyfikacji: 18, 19, 20.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
