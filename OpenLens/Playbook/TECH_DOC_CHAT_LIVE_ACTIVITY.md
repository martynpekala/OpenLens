# Dokumentacja techniczna: Chat + Live Activity (OpenLens)

Ten dokument opisuje, jak dziala czat i Live Activity w projekcie OpenLens: skad biora sie dane, co jest wyswietlane oraz jakie zdarzenia to uruchamiaja. Punkty odnosza sie do konkretnych plikow z repozytorium.

## Przeglad przeplywu danych

1) Uzytkownik wysyla wiadomosc w UI.
2) `ChatClient` dodaje lokalna wiadomosc uzytkownika, tworzy placeholder dla odpowiedzi asystenta i startuje Live Activity.
3) Serwer odpowiada zdarzeniami SSE (streaming), a `SSEEventHandler` aktualizuje stan UI.
4) UI czatu reaguje na zmiany stanu i wyswietla tresc, postepy narzedzi oraz shimmer.
5) Gdy sesja wraca do `idle`, `ChatClient.finishLoading()` konczy Live Activity i zamyka streaming.

## Diagramy

### Diagram sekwencji (Send -> odpowiedz -> koniec)

```text
Uzytkownik -> ChatView: tap Send
ChatView -> ChatClient.send(): walidacja + optimistic UI
ChatClient.send() -> ChatClient.messages: append user message
ChatClient.send() -> ChatClient.messages: append assistant placeholder
ChatClient.send() -> LiveActivityTracker.start()
ChatClient.send() -> MessagesService.sendPromptAsync()
MessagesService.sendPromptAsync() -> OpenCodeClient: POST /session/:id/prompt_async

SSEClient -> SSEEventHandler: session.status = busy
SSEEventHandler -> ChatClient: isLoading = true, currentActivity = AgentActivity
SSEEventHandler -> LiveActivityTracker.start() [jesli zewn. trigger]

SSEClient -> SSEEventHandler: message.part.delta (text)
SSEEventHandler -> ChatClient.appendStreamingText()
ChatClient -> ChatMessage.content: flush z bufora (co 1s)

SSEClient -> SSEEventHandler: message.part.updated (tool)
SSEEventHandler -> AgentActivity.steps: add/update
SSEEventHandler -> LiveActivityTracker.pushIntent()

SSEClient -> SSEEventHandler: session.status = idle
SSEEventHandler -> ChatClient.finishLoading()
ChatClient.finishLoading() -> LiveActivityTracker.end()
```

### Diagram stanow (sesja -> UI)

```text
  [idle]
     | session.status=busy
     v
  [busy] --(tool updates)-> [busy]
     | session.status=idle
     v
  [idle]

Stan UI powiazany:
- idle: brak shimmer, isLoading=false
- busy: shimmer widoczny, isLoading=true, Live Activity aktywne
```

Pliki kluczowe:
- UI: `OpenLens/Views/ChatView.swift`, `OpenLens/Views/Components/MessageBubbleView.swift`, `OpenLens/Views/Components/MarkdownContentView.swift`, `OpenLens/Views/Components/ThinkingShimmerView.swift`, `OpenLens/Views/Components/ActivityStepRow.swift`
- Logika: `OpenLens/Services/ChatClient.swift`, `OpenLens/Services/SSEEventHandler.swift`, `OpenLens/Services/MessagesService.swift`
- Live Activity: `OpenLens/Services/LiveActivityManager.swift`, `OpenLens/Services/LiveActivityTracker.swift`, `OpenLensActivityWidget/OpenLensLiveActivity.swift`, `OpenLens/Models/OpenLensActivityAttributes.swift`

## Czat: co jest wyswietlane i dlaczego

### 1) Lista wiadomosci

Zrodlo danych:
- `ChatClient.messages` (kanoniczna lista), z niej liczona jest `ChatClient.displayedMessages` przez `displayLimit` (paginacja, domyslnie 15).

Wyswietlanie:
- `ChatMessagesListView` w `OpenLens/Views/ChatView.swift` renderuje `ForEach(chatClient.displayedMessages)`.
- Dostepne sa dwa layouty: `List` lub `ScrollView` (przełączane przez `@AppStorage("useListLayout")`).

Przyczyna wyswietlenia:
- Zmiana `ChatClient.messages` lub `displayLimit` powoduje przebudowe `displayedMessages`.
- Zdarzenia SSE typu `message.updated`, `message.part.updated`, `message.part.delta`, `message.removed` mutuja `messages` lub pojedyncze obiekty `ChatMessage`.

Powiazane pliki:
- `OpenLens/Services/ChatClient.swift`
- `OpenLens/Views/ChatView.swift`

### 2) Pojedyncza wiadomosc

Model:
- `ChatMessage` jest `@Observable` klasa. To znaczy, zmiana `content` lub `parts` powoduje rerender tylko tego jednego bąbelka, a nie calej listy.

Wyswietlanie:
- Docelowo `MessageBubbleView` (w kodzie widac komentarz, ze czasem zastepowany jest zwyklym `Text` w `ScrollView`, aby uniknac przyciec przy dismissowaniu sheeta).
- Uzytkownik: zwykly `Text`, tlo bąbla.
- Asystent: `MarkdownContentView`, czyli render markdown (code blocki, listy, naglowki itd.).

Przyczyna wyswietlenia:
- Uzytkownik: `ChatClient.send()` od razu dodaje lokalna wiadomosc (optimistic UI).
- Asystent: `ChatClient.send()` dodaje placeholder z `isStreaming = true`, a tresc doplywa przez SSE.

Powiazane pliki:
- `OpenLens/Models/ChatMessage.swift`
- `OpenLens/Views/Components/MessageBubbleView.swift`
- `OpenLens/Views/Components/MarkdownContentView.swift`

### 3) Streaming tekstu (odpowiedz asystenta)

Mechanizm:
- SSE wysyla `message.part.delta` (delta tekstu). `SSEEventHandler` przekazuje to do `ChatClient.appendStreamingText()`.
- `ChatClient` buforuje teksty w `streamingBuffer` i co 1s (Timer) flushuje je do odpowiednich `ChatMessage.content`.

Przyczyna wyswietlenia:
- Aktualizacja `ChatMessage.content` (bez ruszania tablicy) powoduje natychmiastowy rerender bąbla asystenta.

Powiazane pliki:
- `OpenLens/Services/SSEEventHandler.swift` (handlePartDelta)
- `OpenLens/Services/ChatClient.swift` (streamingBuffer + flush)

### 4) Aktualizacja wiadomosci asystenta i metadanych

SSE `message.updated`:
- Dla `assistant` aktualizuje koszt, model, provider, finish.
- Jesli placeholder asystenta mial lokalny UUID, zostaje zastapiony nowym obiektem z prawdziwym `messageID` z serwera (zmiana identyfikatora wymaga wymiany obiektu w tablicy).

Powiazane pliki:
- `OpenLens/Services/SSEEventHandler.swift` (handleMessageUpdated)

### 5) Wyswietlanie narzedzi (tool calls) w czacie

Zrodlo danych:
- `ChatMessage.parts` zawiera `OCPart` typu `.tool` oraz `OCToolState` (pending/running/completed/error).

Wyswietlanie:
- `MessageBubbleView` pokazuje streszczenie zakonczonych narzedzi (max 5 + "more").

Przyczyna wyswietlenia:
- SSE `message.part.updated` aktualizuje lub dopisuje `parts` do wiadomosci.

Powiazane pliki:
- `OpenLens/Views/Components/MessageBubbleView.swift`
- `OpenLens/Services/SSEEventHandler.swift` (handlePartUpdated)

### 6) Shimmer + kroki aktywnosci w czacie

Zrodlo danych:
- `ChatClient.currentActivity` (typ `AgentActivity`).
- Wypelniane przez `SSEEventHandler.handleToolPartUpdate()` na podstawie `OCPart` typu `.tool`.

Wyswietlanie:
- `ThinkingShimmerView` pokazuje aktualna etykiete (np. "Thinking..." lub nazwa narzedzia).
- `ActivityStepRow` pokazuje zakonczone kroki.

Przyczyna wyswietlenia:
- SSE `message.part.updated` (tool) dodaje kroki lub oznacza je jako zakonczone.
- SSE `session.status` z `busy` ustawia shimmer (start aktywnosci), `idle` konczy.

Powiazane pliki:
- `OpenLens/Models/AgentActivity.swift`
- `OpenLens/Views/Components/ThinkingShimmerView.swift`
- `OpenLens/Views/Components/ActivityStepRow.swift`
- `OpenLens/Services/SSEEventHandler.swift`

## Live Activity: kiedy startuje, co pokazuje i dlaczego

### 1) Start Live Activity

Kto startuje:
- `ChatClient.send()` przy wyslaniu wiadomosci przez uzytkownika.
- `SSEEventHandler.handleSessionStatus()` gdy `session.status` przechodzi na `busy` (np. gdy wiadomosc przyszla z desktopa).

Co trafia do startu:
- `agentName`: tytul sesji lub "OpenCode".
- `userTask`: pierwsze 80 znakow wiadomosci uzytkownika.

Powiazane pliki:
- `OpenLens/Services/ChatClient.swift` (send)
- `OpenLens/Services/SSEEventHandler.swift` (handleSessionStatus)
- `OpenLens/Services/LiveActivityTracker.swift` (start)
- `OpenLens/Services/LiveActivityManager.swift` (startActivity)

### 2) Aktualizacje Live Activity

Zrodlo aktualizacji:
- Zdarzenia tool calls (pending/running/completed) -> `LiveActivityTracker.pushIntent()`.
- Reasoning text -> `LiveActivityTracker.updateSubject()` (pierwsza linia reasoning jako "subject").
- Koszt -> `LiveActivityTracker.updateCost()`.

Co jest pokazywane:
- Biezacy intent (narzedzie / etap pracy), historia poprzednich intentow (2 kroki).
- Licznik krokow.
- Subject (nazwa sesji lub pierwsza linia reasoning).
- Koszt jezeli dostepny.

Przyczyna wyswietlenia:
- `SSEEventHandler.handleToolPartUpdate()` przeklada `OCToolState` na label i kategorie, dodaje step i aktualizuje Live Activity.
- `SSEEventHandler.handlePartUpdated()` dla typu `reasoning` ustawia subject.
- `SSEEventHandler.handleMessageUpdated()` moze zaktualizowac koszt.

Powiazane pliki:
- `OpenLens/Services/SSEEventHandler.swift`
- `OpenLens/Services/ToolLabelFormatter.swift`
- `OpenLens/Services/LiveActivityTracker.swift`
- `OpenLens/Services/LiveActivityManager.swift`

### 3) Koniec Live Activity

Kiedy:
- Gdy `session.status` zmieni sie na `idle`, `SSEEventHandler` wywoluje `delegate.finishLoading()`.
- `ChatClient.finishLoading()` konczy Live Activity przez `liveActivityTracker.end()`.

Co pokazuje koncowy stan:
- Intent = "Complete".
- Subject = completionSummary (domyslnie ostatni `subject`).
- Dismissal policy: po 8 sekundach.

Powiazane pliki:
- `OpenLens/Services/ChatClient.swift`
- `OpenLens/Services/LiveActivityTracker.swift`
- `OpenLens/Services/LiveActivityManager.swift`

### 4) Widoki Live Activity (Lock Screen / Dynamic Island)

Miejsce:
- `OpenLensActivityWidget/OpenLensLiveActivity.swift`.

Co jest wyswietlane:
- Lock Screen: header z agent name / subject, badge z kosztem, karta intentow, footer z aktualnym intentem + timer.
- Dynamic Island: minimalny/compact stan (kolko + intent), expanded stan z agentem i biezacym intentem.

Skad dane:
- `OpenLensActivityAttributes.ContentState` (aktualizowany przez `LiveActivityManager.update(...)`).

Powiazane pliki:
- `OpenLensActivityWidget/OpenLensLiveActivity.swift`
- `OpenLens/Models/OpenLensActivityAttributes.swift`

## SSE: zdarzenia i mapowanie na UI

Najwazniejsze typy zdarzen:
- `session.status`: start/stop generacji, shimmer, start/stop Live Activity.
- `message.updated`: metadane wiadomosci asystenta (cost, model, finish).
- `message.part.delta`: streaming tekstu.
- `message.part.updated`: tworzenie/aktualizacja czesci (text/tool/reasoning/step).
- `message.removed`: usuniecie wiadomosci z listy.
- `permission.asked`, `question.asked`: wyswietlenie alertu / sheeta z pytaniem.

Dokladny katalog zdarzen:
- `OpenLens/API_ENDPOINTS.md` (sekcja SSE)
- `OpenLens/Services/SSEEventHandler.swift`

## Dlaczego UI nie "mieli" listy wiadomosci

Kluczowe optymalizacje:
- `ChatMessage` to `@Observable` klasa. Zmiana `content` i `parts` nie powoduje `didSet` na tablicy `messages`.
- Streaming tekstu jest buforowany i flushowany co 1s, zeby nie zalewac renderowania.
- `MarkdownContentView` cache'uje rozbite bloki i AttributedString w `NSCache`.

Pliki:
- `OpenLens/Models/ChatMessage.swift`
- `OpenLens/Services/ChatClient.swift`
- `OpenLens/Views/Components/MarkdownContentView.swift`

## Szybki scenariusz "co i kiedy"

1) Uzytkownik naciska Send.
   - `ChatClient.send()` dodaje wiadomosc uzytkownika, placeholder asystenta, startuje Live Activity.
2) SSE `session.status` -> `busy`.
   - `SSEEventHandler` ustawia `isLoading = true`, `currentActivity = AgentActivity()`.
3) SSE `message.part.delta`.
   - Tekst doplywa do `ChatClient.appendStreamingText()` i jest flushowany do bąbla.
4) SSE `message.part.updated` dla tool.
   - Dodaje step do aktywnosci, shimmer aktualizuje etykiete, Live Activity dostaje nowy intent.
5) SSE `session.status` -> `idle`.
   - `ChatClient.finishLoading()` konczy Live Activity, zamyka streaming i shimmer.

## Debugging (logi, breakpointy, typowe problemy)

### Szybkie punkty kontrolne

- `OpenLens/Services/ChatClient.swift`:
  - `send()` (czy tworzy placeholder asystenta i startuje Live Activity).
  - `appendStreamingText()` + `flushStreamingBuffer()` (czy delty trafiaja do UI).
  - `finishLoading()` (czy zamyka shimmer i Live Activity).

- `OpenLens/Services/SSEEventHandler.swift`:
  - `handleSessionStatus()` (czy jest `busy`/`idle` i czy startuje aktywnosc).
  - `handleMessageUpdated()` (czy podmienia placeholder z prawdziwym messageID).
  - `handlePartDelta()` (czy przychodzi streaming tekstu).
  - `handlePartUpdated()` (czy part type = tool/reasoning/text).

- `OpenLens/Services/LiveActivityManager.swift`:
  - `startActivity()` / `update()` / `endActivity()` (czy ActivityKit jest w ogole uruchamiane).

### Logi

- `Logger.chat` i `Logger.sseHandler` widoczne sa w:
  - `OpenLens/Services/ChatClient.swift`
  - `OpenLens/Services/SSEEventHandler.swift`
- `Logger.liveActivity` w:
  - `OpenLens/Services/LiveActivityManager.swift`

Przydatne sygnaly:
- brak `server.heartbeat` lub `server.connected` -> spojrz na `ConnectionManager`.
- `session.status` nie zmienia sie na `busy` -> brak aktywnosci (shimmer i Live Activity nie wystartuja).
- `message.part.delta` brak -> brak streamingu (asystent moze wyslac tylko `message.part.updated` z calym tekstem).

### Typowe problemy i przyczyny

1) Brak Live Activity na lock screen
   - `ActivityAuthorizationInfo().areActivitiesEnabled` zwraca false.
   - Aplikacja nie ma uprawnien lub Live Activities sa wylaczone systemowo.
   - Sprawdz `LiveActivityManager.startActivity()` czy w ogole jest wywolywany.

2) Shimmer nie znika po odpowiedzi
   - Brak `session.status = idle` z SSE.
   - `finishLoading()` nie jest wywolany (sprawdz `handleSessionStatus`).

3) Tekst asystenta sie nie streamuje
   - `message.part.delta` nie przychodzi (server moze wyslac tylko finalne `message.part.updated`).
   - Timer flush (`flushTimer`) nie jest uruchomiony (sprawdz `ensureFlushTimer()`).

4) Wiadomosc asystenta znika lub duplikuje sie
   - Zmiana `messageID` (placeholder -> server) wymaga podmiany obiektu w tablicy.
   - Sprawdz `handleMessageUpdated()` i warunek `existingMsg.id != messageID`.

5) Tool steps nie pojawiaja sie w czacie
   - `OCPart` typu `.tool` nie dociera lub `state` jest nil.
   - Sprawdz `handlePartUpdated()` i `handleToolPartUpdate()`.

### Minimalne sledzenie problemu (kroki)

1) Czy SSE jest polaczone i przychodza zdarzenia?
   - Breakpoint w `SSEEventHandler.handleEvent(_:)`.
2) Czy `session.status` przechodzi na busy/idle?
   - Breakpoint w `handleSessionStatus()`.
3) Czy `message.part.delta` przychodzi?
   - Breakpoint w `handlePartDelta()`.
4) Czy `flushStreamingBuffer()` faktycznie dopisuje tekst do `ChatMessage`?
   - Breakpoint w `flushStreamingBuffer()`.
5) Czy Live Activity startuje i konczy sie?
   - Breakpointy w `startActivity()` i `endActivity()`.
