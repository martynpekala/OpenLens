# 15: Przeniesienie sesji z telefonu

**What to build:** Użytkownik wybiera inną zweryfikowaną lokalizację i widzi move jako oczekujące wykonanie.

**Blocked by:** None (can start immediately).

**Status:** withdrawn (2026-10-21) — nie podejmować.

**Powód wycofania:** Rzadki scenariusz mobilny; rebind po move z desktopu już działa. Samodzielna wartość pojawiała się głównie jako krok 21. Szczegóły: [draft ticketów](../../../OpenLens/Playbook/OPENCODE_V2_NEXT_WORKFLOWS_TICKET_DRAFT.md#wycofane-z-planu).

- [ ] Akcja przyjmuje move z właściwą delivery i wykorzystuje już istniejący inbox oraz rebind.
- [ ] Lokalizacja wiążąca zmienia się dopiero po kanonicznym potwierdzeniu; odrzucenie/cancel/reconnect nie gubią szkicu i wymagają przeglądu starych repo references.
- [ ] Move nie kopiuje dirty files. Niepewnego POST nie wolno automatycznie ponawiać jako nowej operacji bez sprawdzenia efektu.
- [ ] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [ ] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [ ] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [ ] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [ ] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [ ] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [ ] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [ ] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: 22. User stories specyfikacji: 43, 44, 45, 46.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
