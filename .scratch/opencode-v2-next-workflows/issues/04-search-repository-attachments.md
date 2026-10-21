# 04: Wyszukiwanie plików do załączenia (z 05: błąd i retry skills)

**What to build:** W istniejącym pickerze można znaleźć plik i załączyć go lub zakres linii. W tym samym composerze katalog skills odróżnia awarię od pustego wyniku i pozwala ponowić pobranie.

**Scalono 2026-10-21:** zakres ticketu 05 należy do tego ticketu — ta sama powierzchnia composera, drobna zmiana (`WorkspaceService.loadSkills` przy błędzie zwraca `[]`).

**Blocked by:** None (can start immediately).

**Status:** done (2026-10-21) — zmiany niezacommitowane; wpis w [ENABLED](../../opencode-v2-completion/ENABLED.md).

- [x] Wyszukiwanie używa zweryfikowanej lokalizacji sesji i fs.find, bez obietnicy wyszukiwania treści kodu.
- [x] Wynik przechodzi istniejący podgląd, walidację ścieżki/zakresu i załączanie do promptu.
- [x] Puste wyniki, brak obsługi i błąd są odrębne; przeglądanie folderów pozostaje dostępne; stare query/location nie nadpisują wyników.
- [x] (05) Usługa i composer odróżniają pusty sukces, sukces z wynikami, brak obsługi oraz błąd ładowania skills.
- [x] (05) Retry dotyczy aktualnej lokalizacji i zachowuje szkic oraz wybrane skills; spóźnione odpowiedzi są odrzucane. Nie powstaje nowy picker ani obsługa usuniętego gatewaya.
- [x] Funkcja jest podłączona do istniejącego interfejsu oraz publicznych akcji ChatClient/usług; nie kończy się na samych DTO lub metodach HTTP.
- [x] Zachowane są istniejące wzorce architektury: współdzielone usługi przez @Environment, logika w usługach @Observable, stan widoku w @State, bez ViewModel/VM/Presenter. Ukrywanie tab bara czatu pozostaje na NavigationStack ConnectedRootView.
- [x] V1 zachowuje dotychczasowe zachowanie. Dla V2 brak obsługi, brak zasobu i błąd transportu są rozróżnione; mutacja nie służy do sprawdzania dostępności funkcji.
- [x] Zmiana sesji/lokalizacji unieważnia spóźnione odpowiedzi. Błędy zachowują potrzebne dane użytkownika i oferują właściwe odzyskanie; retry nie zakłada niepotwierdzonej idempotencji.
- [x] Swift Testing sprawdza obserwowalne zachowanie na istniejącej granicy ChatClient/usług z podstawionym OpenCodeTransport, produkcyjnymi dekoderami/projekcją i symulowanym HTTP/SSE. Odpowiednie scenariusze konkurencji, reconnect i utraty odpowiedzi korzystają ze stanowych fixtures.
- [x] Nie są wymagane ani wykonywane kontrole UI, UI automation, screenshot acceptance ani testy na żywym serwerze OpenCode/tunelu. Weryfikacja nawigacji i prezentacji dotyczy stanu aplikacji udostępnionego przez istniejące interfejsy.
- [x] Po zmianach kodu przechodzi repozytoryjny runner testów i końcowy pełny suite na skonfigurowanym iPhone 18 Pro; symulator jest hostem testów, nie kontrolą UI. Niepowodzenia są zgłaszane wraz z zachowanymi logami/wynikami.
- [x] Po rzeczywistym ukończeniu odnotowano w projektowym rejestrze ENABLED możliwości użytkownika i commity, identyfikując ticket prefiksem next-workflows, aby nie pomylić go ze starym numerem.

Powiązanie ze starym backlogiem: 35 oraz 05 (tylko aktualna luka). User stories specyfikacji: 7, 8, 9, 10.

Baseline: branch feature/super-cool-new-features, commit 2d5a6b0 lub jego następca. Podstawy queue/attachments/context już istnieją. Własny gateway OpenLens Remote pozostaje poza zakresem.

Powiązanie ze starszym ticketem oznacza pokrywający się zakres, nie drugie zadanie do niezależnej implementacji. Nie zmieniać statusu starego ticketu na done na podstawie samego utworzenia tego pliku.
