# 01: Otwieranie sesji subagenta

**What to build:** Z karty pracy użytkownik otwiera rozmowę dziecka i wraca do rodzica z zachowanym kontekstem.

**Blocked by:** None (can start immediately).

**Status:** done (2026-10-21) w `4c78f85`; wpis w [ENABLED](../../opencode-v2-completion/ENABLED.md).

- [x] Zweryfikowany child ID prowadzi do kanonicznej sesji; brak dostępu lub zasobu daje czytelny błąd zamiast pustej rozmowy.
- [x] Powrót zachowuje właściwą sesję, szkic i kontekst; permissions/forms nadal należą do faktycznego właściciela.
- [x] Spóźnione odpowiedzi nie zmieniają nowej sesji. Nie powstaje pełny eksplorator drzewa.
- [x] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [x] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [x] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [x] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [x] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [x] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [x] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [x] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: 23. User stories specyfikacji: 3, 4, 5, 6.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
