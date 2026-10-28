# 16: Statystyki i kalendarz aktywności z serwera (z 17)

**What to build:** Insights pokazuje użycie wielu sesji dla projektu i okresu, a kalendarz aktywności korzysta z tych samych agregatów serwera w wybranej strefie czasowej.

**Scalono 2026-10-21:** zakres ticketu 17 należy do tego ticketu — oba korzystają z jednego wywołania `experimental.session.stats` (`from`, `to`, `project`, `timezone`, `tools=none`). Kalendarz (`SessionsService.loadActivityDays`) pobiera dziś transcript każdej pasującej sesji; agregat zastępuje N żądań jednym. Endpoint jest eksperymentalny, więc obecne liczenie zostaje jako fallback.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Wspierane stats zasilają koszt, tokeny i modele z jawnym zakresem; zmiana filtra odrzuca stare odpowiedzi.
- [ ] Nieznany koszt nie jest zerem, parent/child nie są sumowane podwójnie, a dane nie udają billingu providera.
- [ ] Brak obsługi ma czytelny fallback do obecnych Insights z prawidłową etykietą zakresu; ticket nie wymaga nowej paginacji UI.
- [ ] (17) Okres i timezone są częścią żądania oraz identyfikacji wyniku; granice dni, brak danych i zmiana strefy nie tworzą fałszywych zer ani przesuniętych dni.
- [ ] (17) Fallback kalendarza jawnie opisuje pokrycie i nie używa jednej strony katalogu jako całej aktywności.
- [ ] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [ ] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [ ] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [ ] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [ ] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [ ] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [ ] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [ ] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: 33 (użycie i kalendarz). User stories specyfikacji: 31, 32.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
