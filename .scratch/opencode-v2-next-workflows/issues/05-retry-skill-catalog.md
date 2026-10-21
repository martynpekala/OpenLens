# 05: Błąd i ponowienie ładowania skills

**What to build:** Użytkownik rozróżnia pusty katalog skills od awarii i ponawia pobranie bez utraty promptu.

**Blocked by:** None (can start immediately).

**Status:** merged into 04 (2026-10-21) — nie podejmować osobno.

**Powód:** Ta sama powierzchnia composera co [04](04-search-repository-attachments.md); kryteria przeniesiono tam z prefiksem (05). Szczegóły: [draft ticketów](../../../OpenLens/Playbook/OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md).

- [ ] Usługa i composer odróżniają sukces pusty, sukces z wynikami, brak obsługi oraz błąd.
- [ ] Retry dotyczy aktualnej lokalizacji i zachowuje szkic oraz wybrane skills; spóźnione odpowiedzi są odrzucane.
- [ ] Nie powstaje nowy picker ani obsługa usuniętego gatewaya.
- [ ] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [ ] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [ ] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [ ] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [ ] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [ ] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [ ] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [ ] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: 05: tylko aktualna luka; stary gateway poza zakresem. User stories specyfikacji: 18.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
