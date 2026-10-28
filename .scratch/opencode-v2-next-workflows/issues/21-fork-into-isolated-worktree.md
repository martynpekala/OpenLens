# 21: Alternatywna rozmowa w izolowanym worktree

**What to build:** Jedna jawna operacja prowadzi od pełnej historii do forka pracującego w osobnym worktree.

**Blocked by:** 02: Fork całej rozmowy, 15: Przeniesienie sesji z telefonu, 20: Nowe zadanie w osobnym worktree.

**Status:** withdrawn (2026-10-21) — nie podejmować.

**Powód wycofania:** Nieatomowa kompozycja trzech operacji zależna od 15; główną potrzebę pokrywa 20 + 03 wykonane kolejno. Szczegóły: [draft ticketów](../../../OpenLens/Playbook/OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md#wycofane-z-planu).

- [ ] Workflow składa istniejące tworzenie worktree, fork i move; nie tworzy niepotrzebnej pustej sesji i nie zmienia lokalizacji oryginału.
- [ ] Wynik każdej zakończonej operacji jest zachowany, a ponowienie dotyczy tylko nieukończonego etapu po odczycie stanu.
- [ ] Izolacja jest potwierdzana dopiero po zweryfikowaniu docelowej lokalizacji; błędy nie wywołują automatycznego usuwania plików. Fork od wybranej granicy nie jest wymagany w tym ticketcie.
- [ ] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [ ] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [ ] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [ ] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [ ] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [ ] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [ ] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [ ] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: kompozycja 20/21/22. User stories specyfikacji: 57.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
