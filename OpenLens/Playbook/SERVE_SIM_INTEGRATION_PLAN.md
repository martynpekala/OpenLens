# Plan integracji serve-sim z OpenLens

Status: propozycja, bez zmian w kodzie aplikacji.  
Data analizy: 2026-10-05.  
Cel: po połączeniu OpenLens z komputerem otworzyć na iPhonie lub iPadzie bieżący obraz symulatora działającego na tym Macu, również poza siecią lokalną.

## Wniosek i zakres pierwszej wersji

Integracja jest wykonalna. serve-sim dostarcza przechwytywanie obrazu symulatora oraz lokalne endpointy do jego odbioru. OpenLens ma już agenta na Macu, parowanie urządzeń, Cloudflare Access i tunel z szyfrowaniem HPKE. Brakuje połączenia tych dwóch części oraz ekranu podglądu w aplikacji.

Rekomendacja: **natywny podgląd w OpenLens, serve-sim jako lokalna zależność agenta OpenLens Remote, osobny uwierzytelniony kanał obrazu**. Zachować dotychczasowe parowanie QR oraz szyfrowanie między telefonem i Maciem. Poniższy projekt transportu jest propozycją OpenLens; serve-sim nie dostarcza tego protokołu.

MVP:

- wybór jednego z uruchomionych, udostępnionych na Macu symulatorów;
- aktualizowany obraz w pionie i poziomie, dopasowany do ekranu, z możliwością powiększenia;
- wejście z Workspace → Simulators → Preview;
- stan połączenia i czytelne komunikaty o braku symulatora, wyłączonym udostępnianiu lub utracie Maca;
- wznowienie po chwilowym zerwaniu sieci;
- transmisja tylko podczas oglądania, zakończona po zamknięciu widoku lub przejściu aplikacji w tło.

Zakładamy podgląd jednego symulatora na urządzenie. Sterowanie dotykiem, Home, obrót symulatora i wprowadzanie tekstu to kolejny etap. Sam podgląd spełnia opisane wymaganie bez dostępu do HID.

## Jak to ma działać

1. Na Macu użytkownik włącza „Udostępnianie symulatorów” w OpenLens Remote i wybiera dozwolone urządzenia. To osobne uprawnienie: ekran symulatora nie jest przypisany do folderu workspace i może pokazywać inne aplikacje.
2. OpenLens korzysta z dotychczasowego profilu Remote. Agent informuje, czy obsługuje podgląd i czy udostępnianie jest włączone.
3. Aplikacja pokazuje listę dozwolonych, uruchomionych symulatorów. Wybranie urządzenia otwiera podgląd.
4. Agent pobiera lokalny MJPEG z serve-sim, wydziela kompletne obrazy JPEG, ogranicza ich rozmiar i częstotliwość, szyfruje i wysyła do telefonu.
5. Telefon odszyfrowuje obrazy i wyświetla najnowszy. Czaty i zdarzenia OpenCode nadal korzystają ze swojego połączenia.
6. Zamknięcie podglądu kończy subskrypcję; po zakończeniu ostatniej subskrypcji agent zatrzymuje należący do niego proces przechwytywania.

Droga obrazu: **Simulator na Macu → lokalny serve-sim → OpenLens Remote → tunel → OpenLens na iPhonie/iPadzie**.

Komputer musi być dostępny i nie może spać. W pierwszej wersji uruchomienie symulatora i aplikacji pozostaje po stronie Maca lub zwykłego procesu pracy z agentem. MVP nie wymaga zdalnego budowania projektu.

## Dlaczego natywny podgląd

| Wariant | Ocena dla tego repozytorium |
| --- | --- |
| Gotowa strona serve-sim w WKWebView | Przydatna do próby zgodności i porównania. Wymaga udostępnienia HTTP oraz poprawnego uwierzytelnienia strony, wszystkich żądań i WebSocketów. Samo ustawienie nagłówków pierwszego żądania nie załatwia pozostałych połączeń. Zwykły publiczny proxy HTTPS nie zachowuje HPKE używanego obecnie przez OpenLens. |
| Natywny odbiornik JPEG/MJPEG przez szyfrowany kanał | Rekomendowany MVP. Niezależne obrazy upraszczają wznowienie i pomijanie klatek; można zachować parowanie, dostęp dla zaufanych urządzeń i prywatność obecnego Remote. Koszt: większy transfer niż H.264. |
| Natywny odbiornik H.264 | Następny krok, gdy pomiary JPEG wykażą zbyt duży transfer lub potrzebna będzie większa płynność. Wymaga parsera AVCC, konfiguracji dekodera, znaczników czasu oraz prawidłowego wznowienia od klatki kluczowej. |

Aktualny serve-sim udostępnia wideo przez długie żądania HTTP; WebSocket służy m.in. do konfiguracji i sterowania. Nie należy opierać implementacji na założeniu, że istnieje gotowy WebSocket wideo. Źródła i szczegóły kontraktu są w aneksie.

## Dopasowanie do istniejącego kodu

| Obszar | Zmiana |
| --- | --- |
| [RemoteAgentStore.swift](../../Tools/openlens-qr-menubar/RemoteSources/RemoteAgentStore.swift), [RemoteAgentLifecycle.swift](../../Tools/openlens-qr-menubar/RemoteSources/RemoteAgentLifecycle.swift) | Dodać właściciela procesu serve-sim, wykrywanie zależności, stan udostępniania, listę dozwolonych UDID i sprzątanie po rozłączeniu/wyłączeniu Remote. |
| [Gateway.swift](../../Tools/openlens-qr-menubar/RemoteSources/Gateway.swift) | Obsłużyć negocjację podglądu oraz dodatkowy kanał obrazu, zachowując kontrolę Access JWT, identyfikację urządzenia, limity i wspólne cofanie dostępu. |
| [OpenLensRemoteCore](../../OpenLensRemoteCore/) | Dodać uzgodniony kontrakt podglądu, metadane i limity klatek oraz odrębne konteksty szyfrowania dla kanału obrazu. |
| [OpenCodeTransport.swift](../Services/OpenCodeTransport.swift), [ConnectionManager.swift](../Services/ConnectionManager.swift) | Udostępnić wynik negocjacji funkcji i spiąć lifecycle podglądu z bieżącym profilem połączenia. Wspólną obsługę uwierzytelnienia wydzielić tylko w zakresie rzeczywiście używanym przez oba kanały. |
| Nowy `SimulatorService` i lokalny odbiornik obrazu | Mały interfejs do katalogu, otwarcia i zamknięcia podglądu; wewnątrz transport, anulowanie, wznowienie i limity. |
| [WorkspaceRootView.swift](../Views/Workspace/WorkspaceRootView.swift), [RouterDestination.swift](../Navigation/RouterDestination.swift), [ConnectedRootView.swift](../Views/ConnectedRootView.swift) | Dodać wejście, wybór symulatora i cel nawigacji. Uwzględnić obecny układ iPada. |
| [OpenLensApp.swift](../OpenLensApp.swift), [EnvironmentKeys.swift](../Protocols/EnvironmentKeys.swift) | Utworzyć usługę w composition root i wstrzyknąć ją przez `@Environment`. |
| [OpenLensTests](../../OpenLensTests/), [RemoteTests](../../Tools/openlens-qr-menubar/RemoteTests/) | Testy kontraktu, lifecycle, autoryzacji, backpressure i zgodności starych klientów. |

Kierować się regułami [AGENTS.md](../../AGENTS.md): logika w `@Observable`, stan prezentacji w `@State`, bez ViewModel/VM/Presenter. Dekodowanie obrazu poza głównym aktorem. Renderer powinien aktualizować wyłącznie powierzchnię podglądu, bez odświeżania całego drzewa SwiftUI przy każdej klatce.

Nie przenosić modyfikatora ukrywającego tab bar z `ConnectedRootView.tabNavigationView(for:)`. Podgląd nie wymaga nowej zakładki ani zmiany działania Chat.

## Kontrakt i zachowanie transportu

- Rozszerzyć `RemoteSessionWelcome` o opcjonalną listę obsługiwanych funkcji, np. `simulator.preview.v1`. Brak pola oznacza brak obsługi. Starsza aplikacja musi nadal współpracować z nowym agentem, a nowa aplikacja ze starszym agentem ma pokazywać informację o niedostępnym podglądzie.
- Kanał OpenCode zachowuje protokół v1. Kanał obrazu otrzymuje osobny subprotocol, np. `openlens-simulator-v1`, oraz świeży handshake uwierzytelniony istniejącymi kluczami sparowanego urządzenia.
- Cel kanału musi być związany z uwierzytelnionym handshake i kontekstem HPKE. Osobne identyfikatory sesji, kierunki i liczniki; nie współdzielić stanu encryptor/decryptor z kanałem OpenCode.
- Obecny `Gateway.activateDeviceSession` zamyka poprzednie połączenie tego samego urządzenia. Zmienić regułę na jedno połączenie danego rodzaju na urządzenie, np. `(deviceID, purpose)`; w przeciwnym razie otwarcie podglądu rozłączy czat. Revoke/Stop Remote musi zamknąć oba.
- Zdefiniować komunikaty: katalog, otwarcie wybranego UDID, potwierdzenie z konfiguracją ekranu, klatka, zmiana konfiguracji, zamknięcie i błąd. Nazwy te są propozycją kontraktu OpenLens, a nie endpointami serve-sim.
- Transport obrazu powinien używać binarnego payloadu; nie przepuszczać JPEG przez zagnieżdżone pola `Data` w JSON, które zwiększają rozmiar przez Base64. Handshake może korzystać z dotychczasowego kodowania.
- Klatka zawiera wersję, identyfikator subskrypcji/generację, numer klatki, czas przechwycenia, rozmiary i JPEG. Metadane są szyfrowane lub uwierzytelnione jako associated data. Dane z poprzedniej subskrypcji nie mogą trafić na nowy podgląd.
- Ustalić osobne limity dla katalogu, konfiguracji i obrazu. Startowy profil do pomiarów: 10 FPS, maksymalnie 1600 pikseli na dłuższym boku, JPEG quality ok. 0,65, limit pojedynczego JPEG 1 MiB. Te parametry realizuje adapter OpenLens; upstream nie ma gotowych ustawień FPS/quality/downscale.
- Po stronie Maca przechowywać najwyżej jedną klatkę w wysyłaniu i jedną najnowszą oczekującą. Wyrzucać obrazy **przed szyfrowaniem**. Obecny `RemoteDecryptor` wymaga kolejnych numerów wiadomości; pomijanie już zaszyfrowanych wiadomości złamałoby jego licznik.
- Odbiorca najpierw uwierzytelnia każdą otrzymaną wiadomość w kolejności, potem może pominąć niepotrzebne renderowanie. Ograniczyć kolejkę dekodowania. Zastosować potwierdzanie odbioru/okno wysyłki oraz timeout dla powolnego klienta, ponieważ samo przekazanie danych do gniazda nie gwarantuje ich odebrania.
- Parser lokalnego MJPEG musi działać przy dowolnym podziale danych HTTP i czytać tylko kompletne, ograniczone rozmiarem klatki. Sprawdzić zarówno limit bajtów, jak i rozmiary dekodowanego obrazu.
- Autoryzować każdy wybór UDID po stronie Maca. Klient nie podaje dowolnego URL, portu, ścieżki pliku ani komendy shell. Lokalny adapter dociera wyłącznie do należącego do niego procesu.
- Stream wznowić ze świeżą sesją i licznikami po zmianie Wi-Fi/komórkowej lub restarcie tunelu. Zastosować heartbeat i ograniczone ponowienia z narastającym odstępem; utrata obrazu nie powinna przerywać czatu.

## Etapy realizacji

### 0. Próba techniczna i decyzja o parametrach — 1–2 dni

Przypiąć zbadany pakiet serve-sim 0.1.47 i sprawdzić go z rzeczywiście używanym Xcode/runtime. Zainstalowane zależności i procesy w tej próbie są elementem przyszłej implementacji, nie zostały uruchomione podczas przygotowania planu.

Sprawdzić odbiór MJPEG bez sterowania, odczyt konfiguracji, zmianę orientacji, stabilność urządzeń, uruchamianie bez otwierania przeglądarki i całkowite zatrzymanie capture. Zmierzyć rozmiary klatek, CPU Maca, opóźnienie, pamięć i transfer z telefonu przez sieć komórkową. WKWebView można wykorzystać jako punkt porównania z gotową stroną.

Zweryfikować warunki używanego tunelu dla ciągłego obrazu. Cloudflare technicznie wspiera WebSockety, ale warunki CDN dotyczą także wideo i dużych plików; nie zakładać, że szyfrowanie lub format WSS automatycznie wyłącza te ograniczenia. Źródło nie rozstrzyga samo w sobie kwalifikacji tego konkretnego kanału. Jeżeli wybrana konfiguracja nie obejmuje takiego użycia, wybrać zatwierdzony transport obrazu lub prywatną trasę przed dalszym wdrożeniem. [WebSockets](https://developers.cloudflare.com/network/websockets/), [warunki usług — CDN](https://www.cloudflare.com/service-specific-terms-application-services/#content-delivery-network-free-pro-or-business).

**Kryterium:** działający odbiór z rzeczywistego Maca, potwierdzony lifecycle i dopuszczalna droga zdalna. Wyniki określają budżet obrazu i ewentualną potrzebę wcześniejszego H.264.

### 1. Obsługa serve-sim na Macu — około 2 dni

Dodać menedżer procesu na wzór obecnego `OpenCodeProcess`: wykrywanie Xcode, runtime, wspieranego Node LTS i zgodnej wersji serve-sim; argumenty przez `Process`; kontrolowany port, katalog stanu i identyfikacja własnego procesu. Przygotować diagnostykę „brak zależności / brak symulatora / capture niedostępne”.

Na etapie developerskim użyć pakietu zainstalowanego raz w przypiętej wersji. Przed wydaniem ustalić i zweryfikować dostarczenie zależności wraz z podpisywanym/notaryzowanym agentem lub jednoznaczny proces instalacji wymaganej wersji. Otwarcie podglądu nie powinno pobierać npm `latest`.

Dodać lokalny przełącznik udostępniania, listę UDID i podgląd aktywnych odbiorców. Preferować uruchomione urządzenia; samo wyświetlenie listy nie może bootować symulatorów. Lokalna strona serve-sim nie potrzebuje publicznej trasy. Użyć jawnego loopback i kontrolowanego portu; sprawdzić, że cały proces w przypiętej wersji zachowuje tę konfigurację.

**Kryterium:** agent zwraca tylko dozwolone urządzenia i uruchamia/zatrzymuje własny capture. Wyłączenie Remote lub cofnięcie uprawnienia zamyka transmisję. Nie kończyć obcych procesów serve-sim ani samego Simulatora.

### 2. Kanał obrazu i kontrakt — około 3–4 dni

Wprowadzić opisane negocjowanie funkcji, dodatkową sesję, kontrakt binarny, ograniczenia wysyłki i parser MJPEG. Zachować wszystkie dotychczasowe mechanizmy Access, identyfikacji urządzeń i cofania dostępu.

**Kryterium:** sparowany iPhone odbiera obraz spoza LAN; otwarcie podglądu nie zamyka SSE ani czatu. Niesparowane urządzenie, nieudostępniony UDID i przekroczone limity są odrzucane.

### 3. Natywny ekran OpenLens — około 2–3 dni

Dodać wejście w Workspace, wybór urządzenia i widok obrazu na iPhonie/iPadzie. Pokazać stany `unavailable / loading / empty / streaming / reconnecting / error`. Ostatnia klatka po utracie sieci musi mieć oznaczenie, że obraz nie jest już aktualizowany.

Spiąć zamknięcie, zmianę profilu Maca i `scenePhase` z anulowaniem subskrypcji. Powrót do aplikacji otwiera nowy stream tylko wtedy, gdy podgląd nadal jest widoczny i urządzenie nadal dozwolone.

**Kryterium:** użytkownik po dotychczasowym połączeniu otwiera podgląd bez wpisywania dodatkowych adresów, portów ani sekretów.

### 4. Weryfikacja i przygotowanie wydania — około 2–3 dni

Przeprowadzić testy poniżej, udokumentować konfigurację Maca, przypiąć zależności i zachować informacje licencyjne Apache-2.0. Dołączyć zrzuty widocznych stanów UI do opisu zmiany.

**Kryterium:** stabilny podgląd na realnym iPhonie przez sieć komórkową, poprawne zatrzymanie zasobów, zgodność starych klientów i podpisana/testowana dystrybucja agenta zgodnie z wybraną metodą dostarczania zależności.

Szacunek całego MVP: **około 2–3 tygodni pracy jednej osoby**, przy działającym obecnym Remote i zaakceptowanym transporcie. To oszacowanie planistyczne; próba techniczna może zmienić zakres, zwłaszcza przy konieczności H.264 lub innej trasy obrazu.

## Weryfikacja

Nowe testy w Swift Testing powinny sprawdzać zachowanie, nie kopiować implementację:

- nowy klient/stary agent i stary klient/nowy agent; brak funkcji podglądu nie psuje połączenia;
- dwie sesje jednego urządzenia: obraz nie wypiera OpenCode, ponowne otwarcie obrazu zastępuje tylko poprzedni obraz;
- Access/device authentication, nieudostępnione UDID, revoke zamykający oba kanały oraz replay/nieprawidłowa kolejność wiadomości;
- MJPEG rozcięty w różnych miejscach, wiele klatek w jednym fragmencie, niepoprawne nagłówki, za duże obrazy i zmiana konfiguracji;
- powolny odbiorca, ograniczone buforowanie, spadek FPS, poprawne liczniki HPKE przy pomijaniu klatek;
- zamknięcie widoku, tło, zmiana połączenia, wyłączenie udostępniania, zakończenie Simulatora, awaria capture i ponowne otwarcie;
- długie oglądanie z aktywnym czatem, zmiana Wi-Fi ↔ komórkowa, portrait/landscape i układ iPada.

Cele do potwierdzenia pomiarem: pierwsza klatka w około 3 s przy gotowym symulatorze, opóźnienie obrazu poniżej około 500 ms na dobrym połączeniu, ograniczona pamięć w 30-minutowej sesji, czytelny tekst oraz brak zauważalnego pogorszenia czatu. Mierzyć pełny transfer po szyfrowaniu i narzut protokołu; 10 FPS nie gwarantuje niskiego zużycia danych.

Po zmianach aplikacji/widgeta uruchomić wymagany przez repo check:

```sh
xcodegen generate && xcodebuild -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=iOS Simulator,id=F323E9E4-4B39-4EB6-A42B-AB9E203A3E9A' CODE_SIGNING_ALLOWED=NO test
```

Dla zmian agenta macOS uruchomić jego testy zgodnie z [README narzędzia](../../Tools/openlens-qr-menubar/README.md):

```sh
tuist generate --no-open
xcodebuild -workspace OpenLensRemote.xcworkspace -scheme OpenLensRemote -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Dwie ostatnie komendy wykonać w `Tools/openlens-qr-menubar/`. Testy iOS używają wskazanego iPhone 18 Pro. Test zdalnego obrazu wymaga też fizycznego iPhone'a/iPada.

## Kolejne rozszerzenia

Po działającym podglądzie dodać kolejno:

1. Tap i swipe, z odwzorowaniem współrzędnych przy skalowaniu/obrocie; Home i obrót urządzenia.
2. Jawne przełączanie „podgląd / sterowanie” oraz jedno aktywne urządzenie sterujące.
3. Wprowadzanie tekstu po sprawdzeniu ograniczeń klawiatury i uprawnień macOS dla właściwego Xcode.
4. H.264 i profile jakości, jeżeli uzasadnią je wyniki transferu/płynności.
5. Opcjonalny skrót z czatu do istniejącego podglądu.

Camera injection, WebKit DevTools, upload plików i komendy shell nie są potrzebne do tego zakresu.

## Stan weryfikacji planu i przygotowanie implementacji

Plan powstał na podstawie kodu OpenLens oraz odczytu źródeł serve-sim. Nie instalowano ani nie uruchamiano serve-sim, nie wykonywano pomiarów i nie zmieniono kodu aplikacji. Podane parametry i czasy są celami/propozycjami.

W tym checkoutcie nie znaleziono wskazanego przez AGENTS.md skilla `swiftui-ui-patterns` w `.opencode/skills/` ani w sprawdzonych lokalnych katalogach skills. Przed implementacją ekranów zapewnić dostęp do tego skilla; nie jest potrzebny do potwierdzenia kontraktu sieciowego i przygotowania niniejszego planu.


## Aneks: ustalenia źródłowe serve-sim — 5 października 2026


To analiza źródeł i publikowanego pakietu, bez instalowania, uruchamiania `serve-sim` ani testów na urządzeniu. Fakty poniżej opisują upstream; rekomendacje i kryteria prób są osobno oznaczone.

### Wersja i wymagania Maca

- Zbadany `main`: commit `c60d583747b88a15616eeecec56f287ef5759769`, z 2 października 2026. `package.json` repozytorium deklaruje `0.1.46`, ale rejestr npm publikuje `latest = 0.1.47`, `gitHead = 1930e6c21c2b5cb11943f52cfb0b58acad4c7663`. Porównanie obu commitów wykazało wyłącznie dodatkowy test; kod runtime jest identyczny. Do spike przypiąć **pakiet 0.1.47**, bez zależności od ruchomego `latest`. [Repo package][package], [metadane npm][npm], [commit publikacji][published].
- Licencja to Apache-2.0. Przy redystrybucji lub adaptowaniu kodu należy zachować licencję i wymagane informacje o autorze oraz oznaczyć modyfikacje. [Licencja][license].
- Aktualny addon Swift ma minimum **macOS 14**; pakiet wymaga Node `>=20`, a README zaleca utrzymywane wydanie LTS. Potrzebny jest aktywny Xcode z runtime symulatora: kod ładuje prywatne CoreSimulator/SimulatorKit z systemu i Xcode oraz używa `xcrun simctl`. Sam dostęp do command line tools nie dowodzi obecności tych komponentów. [Package.swift][swift-package], [loader frameworków][frameworks], [package][package], [README][readme].
- README nadal mówi o helperze `serve-sim-bin` i ograniczeniu do arm64. Aktualny runtime korzysta z **in-process N-API `serve-sim-native.node`**. Skrypty budowania domyślnie tworzą universal arm64+x86_64; odczyt Mach-O z opublikowanego tarballa 0.1.47 potwierdził obie architektury. To nie potwierdza działania na konkretnym Intel Macu. Apple Silicon jako pierwszy target, Intel dopiero po próbie zgodności. [Native loader][native], [architektury][arch], [publikowany tarball][tarball].
- Prywatne API symulatora pozostają w procesie **Maca**; nie są biblioteką do włączenia do aplikacji iOS. Zmiany Xcode mogą wymagać aktualizacji upstream. Klawiatura Xcode 27 ma dodatkowe wymagania Device Hub/Accessibility opisane w README; nie dotyczą samego oglądania obrazu. [Frameworks][frameworks], [README][readme].

### Proces, adres i lista symulatorów

- Standalone domyślnie nasłuchuje na `127.0.0.1`, porcie 3200. Jawny port wyłącza automatyczne przeszukiwanie kolejnych portów. `--host 0.0.0.0` jest osobnym opt-in do udostępnienia LAN. [CLI][cli], [serwer][runtime].
- Standalone uruchamia middleware z `basePath: "/"`, `proxyHelpers: true` i obsługą upgrade WebSocketów: obraz i kontrola są dostępne przez jeden port. Middleware eksportowane jako `serve-sim/middleware` pozwala wybrać `basePath`, domyślnie `/.sim`, lecz `proxyHelpers` jest domyślnie wyłączone. Przy włączeniu trzeba podłączyć `middleware.handleUpgrade` do serwera. [Standalone][cli], [middleware options][options].
- Przy proxy TLS należy zachować właściwy publiczny `Host` i przekazywać `X-Forwarded-Proto: https`: upstream generuje wtedy adresy `https`/`wss`. Bez single-port proxy może zwracać adresy osobnych helperów; do zdalnej integracji nie należy zakładać ich dostępności. [Przepisywanie URL][rewrite], [forwarded proto][proto].
- `GET <base>/grid/api` jedynie wykonuje `simctl list devices -j` i zwraca listę z UDID, nazwą, runtime, stanem i opcjonalnym helperem; ma paginację `limit`/`offset`. Lista nie bootuje urządzeń. `GET <base>/api?device=<udid>` zwraca konfigurację wybranego urządzenia lub `null`. [Lista][grid], [API][api].
- Sam start CLI **może bootować**: wybiera wskazane urządzenia, a bez argumentów jedno istniejące/booted/default i wywołuje `ensureBooted`. `POST <base>/grid/api/start` oraz `/shutdown` zmieniają stan urządzenia. W MVP wybrać już uruchomiony symulator; nie utożsamiać discovery z bootowaniem. [CLI selection][selection], [grid routes][grid-mutation].

### Obraz i opcjonalne sterowanie

| Endpoint upstream | Transport i znaczenie | Przydatność |
| --- | --- | --- |
| `<base>/helper/<udid>/stream.mjpeg` | Długie HTTP GET, `multipart/x-mixed-replace; boundary=frame`; części JPEG mają `Content-Length`. `?raw=1` zmienia zewnętrzny Content-Type na `application/octet-stream`, zachowując części. | Źródło dla prostego natywnego adaptera obrazu. |
| `<base>/helper/<udid>/stream.avcc` | Długie HTTP GET, `application/octet-stream`: H.264 AVCC z własnymi kopertami. **Wideo nie płynie przez WS.** | Potencjalny drugi etap wydajnego video. |
| `<base>/helper/<udid>/config` | HTTP JSON z `width`, `height`, `orientation`; przed pierwszą klatką wymiary mogą być 0. | Metadane i gotowość capture; zmiany rozmiaru także odczytywać z JPEG. |
| `<base>/helper/<udid>/health` | HTTP JSON `{status: "ok"}`. | Sama odpowiedź nie potwierdza, że dotarła pierwsza klatka. |
| `<base>/helper/<udid>/ws` | Binarny WS: bajt typu + JSON. Dotyk `0x03`, przyciski `0x04`, multitouch `0x05`, klawisze `0x06`, orientacja `0x07`; config server→client `0x82`. | Sterowanie, poza MVP podglądu. |

Tabela wynika z [routera helperów][helper-routes], [DeviceSession][session] i [formatu AVCC][stream-format].

- MJPEG **działa bez otwarcia** `/ws`: HTTP handler uruchamia capture, subskrybuje JPEG i wysyła klatki niezależnie od HID socketu. Natywny MVP może więc pozostać całkowicie view-only i nie wystawiać kontroli. [HTTP handler][mjpeg].
- AVCC koperta: 4 bajty big-endian długości, następnie tag i payload; długość obejmuje tag. Typy to `0x01` avcC/SPS/PPS, `0x02` IDR, `0x03` delta/P-frame, `0x04` JPEG seed. To nie MP4, HLS ani WebRTC; natywny klient wymaga demultipleksowania i dekodera. [Format][stream-format], [parser klienta][avcc-codec].
- Parametry jakości nie są publicznym API: JPEG quality jest wpisane jako `0.7`, H.264 ma założone 60 FPS i domyślnie 6 Mb/s, realtime/no frame reordering/low latency, z keyframe interval 5 s i pierwszym IDR wymuszonym dla nowego subskrybenta. Nie traktować 60 FPS jako gwarancji WAN. [JPEG encoder][capture-engine], [H264 encoder][h264].
- Brak udokumentowanej opcji upstream dla ograniczenia FPS, bitrate, JPEG quality czy downscale per klient. `setPreferredScreenSize` wybiera rzeczywistą powierzchnię framebuffer/panel, **nie resampluje** obrazu. `--fit` zmienia layout przeglądarki, nie transfer. [FrameCapture][frame-capture], [CLI][cli], [preview state][initial-state].
- Adapter na Macu musi sam: odrzucać nadmiar JPEG, utrzymywać ograniczoną kolejkę z ostatnią klatką, nakładać budżet rozmiaru/transferu i ewentualnie skalować oraz ponownie kompresować JPEG. Sam limit wysyłania zmniejszy WAN, lecz nie wyłączy kosztu upstream capture. To wniosek projektowy z dostępnego API. [MJPEG handler][mjpeg], [capture engine][capture-engine].
- Upstream stosuje backpressure i native `bufferingNewest(1)`. Zamknięcie HTTP usuwa subskrypcję klienta, ale `DeviceSession` zatrzymuje własną wspólną subskrypcję JPEG dopiero przy zamknięciu sesji; nie ma automatycznego stop capture po ostatnim viewerze. Należy rozdzielić proces uruchomiony przez OpenLens od procesu użytkownika i sprzątać wyłącznie zasoby należące do integracji. [Start/close][session-lifecycle], [HTTP cleanup][cleanup].

### Autoryzacja i wariant webowy

- Upstream nie oferuje uwierzytelniania użytkowników dla całego preview/media/HID. `/exec` jest chronione losowym `execToken`, Content-Type JSON i kontrolą Origin; `/exec-ws` wymaga tokenu w pierwszej wiadomości. Jest to ochrona konkretnego kanału wykonywania poleceń, a nie granica dostępu do podglądu. [Exec HTTP][exec], [Exec WS][exec-ws].
- Token jest wstrzykiwany do HTML **i zwracany przez `/api`**. Kto może odczytać stronę/API, może uzyskać token do wykonywania poleceń powłoki na Macu. Udostępnienie strony jako prostego publicznego tunelu nie wystarcza; kontrola dostępu musi obejmować całe HTTP i upgrade WS. Nie przekazywać `/exec`, `/exec-ws`, DevTools ani mutujących endpointów do view-only kanału OpenLens. [HTML][html], [API][api], [preview config][preview-config], [exec][exec].
- Web UI ma rzeczywiste `touchstart`/`touchmove`/`touchend`, znormalizowane współrzędne i obsługę dwóch palców. Kod pokazuje intencję działania na mobile, ale nie stanowi potwierdzenia bezbłędnej obsługi gestów na iPhonie w `WKWebView`. [Touch handlers][mobile-touch].
- WebCodecs video jest dostępne w WebKit od Safari 16.4. `VideoDecoder` wymaga secure context zgodnie ze specyfikacją; zwykły adres HTTP Maca w LAN nie gwarantuje H.264. Upstream wykrywa obecność `VideoDecoder`, a przy jego braku/błędzie przechodzi do MJPEG. Konkretny profil i realne `WKWebView` należy sprawdzić na docelowym iOS. [WebKit][webkit], [WebCodecs spec][webcodecs], [feature detection][avcc-codec], [decoder][web-decoder], [fallback][fallback].
- Dla MJPEG kod zawiera wariant `?raw=1`, ponieważ WebKit nie udostępnia multipart do czytnika `fetch`; pełny viewer używa także `<img src>` dla MJPEG. W spike należy sprawdzić renderowanie, reconnect, wskaźnik live i brak podwójnego pobierania strumienia. [MJPEG hook][mjpeg-hook], [viewer][web-viewer].
- WebSocket API przeglądarki przyjmuje URL i opcjonalne subprotocols; nie udostępnia dowolnego nagłówka `Authorization` przy `new WebSocket()`. Handshake używa credentials, więc sesja cookie tego samego origin jest naturalnym wariantem webowej bramki. Nagłówek do głównego requestu `WKWebView` nie jest rozwiązaniem autoryzacji wszystkich assetów/fetch/WS. Sposób ustanowienia oraz wygaszenia sesji webowej wymaga osobnej próby. [Standard WS][websocket-spec], [klient WS][web-viewer].

### Rekomendacja do planu i próby wymagające dowodu

**Rekomendacja dla zdalnego MVP OpenLens:** natywny viewer JPEG/MJPEG, bez sterowania, z lokalnym adapterem Maca oraz przeniesieniem obrazu przez istniejący bezpieczny model połączenia OpenLens. `WKWebView` nadaje się do szybkiego benchmarku możliwości upstream i do przyszłego wariantu webowego, lecz zwykły URL/tunel nie zachowuje sam z siebie obecnego E2E OpenLens. To decyzja projektowa, nie obietnica upstream.

Próba integracyjna powinna potwierdzić: pierwszą klatkę bez HID socketu; stan bez booted urządzeń; poprawny UDID/rozmiar/obrót; działanie po shutdown/reboot symulatora i restarcie `serve-sim`; limit klatek i transferu oraz brak rosnącej kolejki; zawieszenie po schowaniu aplikacji i powrót; równoczesny chat; utratę zasięgu; cofnięcie dostępu; oraz brak dostępu do poleceń/DevTools z kanału obrazu. Dla native H.264 w kolejnym etapie: opis dekodera, IDR, reconnect i brak zalegających delta frames. Dla webowego spike: HTTPS/WSS, `VideoDecoder`, MJPEG fallback, cookie, gesty i lifecycle na fizycznym iPhonie. Nie wykonywano tych prób podczas przygotowania planu.

[package]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/package.json
[npm]: https://registry.npmjs.org/serve-sim/0.1.47
[published]: https://github.com/EvanBacon/serve-sim/commit/1930e6c21c2b5cb11943f52cfb0b58acad4c7663
[license]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/LICENSE
[swift-package]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/Package.swift
[frameworks]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/Sources/SimNative/SimFrameworks.swift
[readme]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/README.md
[native]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/native.ts
[arch]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/serve-sim-arch.ts
[tarball]: https://registry.npmjs.org/serve-sim/-/serve-sim-0.1.47.tgz
[cli]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/index.ts#L1607
[runtime]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/runtime.ts#L143
[options]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1217
[rewrite]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L409
[proto]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1019
[grid]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1075
[api]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1690
[selection]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/index.ts#L1593
[grid-mutation]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1515
[helper-routes]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L719
[session]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/device-session.ts
[stream-format]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/Sources/SimNative/StreamFormat.swift
[mjpeg]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/device-session.ts#L358
[avcc-codec]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/client/avcc-codec.ts
[capture-engine]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/Sources/SimNative/CaptureEngine.swift
[h264]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/Sources/SimNative/H264Encoder.swift#L35
[frame-capture]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/Sources/SimNative/FrameCapture.swift#L331
[initial-state]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/preview-initial-state.ts
[session-lifecycle]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/device-session.ts#L211
[cleanup]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/device-session.ts#L797
[exec]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1892
[exec-ws]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/exec-ws.ts
[html]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L1368
[preview-config]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/middleware.ts#L851
[mobile-touch]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/client/simulator/SimulatorView.tsx#L1030
[webkit]: https://webkit.org/blog/13966/webkit-features-in-safari-16-4/
[webcodecs]: https://www.w3.org/TR/webcodecs/#videodecoder-interface
[web-decoder]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/client/simulator/use-avcc-stream.ts
[fallback]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/client/avcc-fallback.ts
[mjpeg-hook]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/client/hooks/use-mjpeg-stream.ts
[web-viewer]: https://github.com/EvanBacon/serve-sim/blob/c60d583747b88a15616eeecec56f287ef5759769/packages/serve-sim/src/client/simulator/SimulatorView.tsx
[websocket-spec]: https://websockets.spec.whatwg.org/#the-websocket-interface
