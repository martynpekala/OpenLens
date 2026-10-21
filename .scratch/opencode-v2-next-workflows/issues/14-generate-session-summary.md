# 14: Podsumowanie bez zmiany rozmowy

**What to build:** Użytkownik generuje podsumowanie lub następny krok, kopiuje wynik i jawnie go odświeża.

**Blocked by:** None (can start immediately).

**Status:** done (2026-10-21) w `4c78f85`; wpis w [ENABLED](../../opencode-v2-completion/ENABLED.md).

- [x] Session generate wyświetla wynik poza transcript, bez prompt admission i bez kompaktacji.
- [x] Cache jest przypisany do sesji i rewizji kontekstu; ponowne otwarcie nie wywołuje automatycznie modelu.
- [x] Błędy i stare wyniki nie zmieniają rozmowy; UI odróżnia odpowiedź modelu od stanu wykonania i nie obiecuje darmowej generacji.
- [x] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [x] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [x] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [x] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [x] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [x] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [x] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [x] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: nowy zakres. User stories specyfikacji: 11, 12, 13.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
