# Code Review: OpenLens

**38 plików Swift, ~6765 linii kodu** | iOS app (SwiftUI) + Live Activity widget

---

## 1. KRYTYCZNE: `ChatViewModel` — naruszenie architektury

`ChatViewModel.swift` (535 linii) to klasyczny God Object, który łamie fundamentalną zasadę z CLAUDE.md: **"NIGDY nie twórz klas `*ViewModel`"**.

Klasa zarządza jednocześnie:
- cyklem życia sesji
- ładowaniem/wysyłaniem wiadomości
- obsługą SSE eventów (delegate)
- selekcją modeli/providerów
- buforowaniem streamingu z Timer
- obsługą permissions i questions z auto-timeout
- koordynacją Live Activity

**Rekomendacja:** Rozbić na serwisy domenowe wstrzykiwane przez `@Environment`:
- `ChatState` — `@Observable` klasa trzymająca `messages`, `isLoading`, `errorMessage` (wstrzykiwana w environment)
- Logika sesji → `SessionsService` (już istnieje)
- Logika streamingu → dedykowany serwis
- SSE event handling → `SSEEventHandler` (już istnieje, ale deleguje do VM)

---

## 2. WYSOKI: Thread-safety `LiveActivityManager`

`LiveActivityManager` jest oznaczony `@unchecked Sendable`, ale **nie ma żadnego mechanizmu synchronizacji** — brak locków, dispatch queue, czy actor isolation. Cały mutowalny stan (`currentActivity`, `pendingContent`, `debounceTimer`, `previewTask`) jest niezabezpieczony.

```swift
// LiveActivityManager.swift — @unchecked Sendable bez synchronizacji
class LiveActivityManager: LiveActivityProviding, @unchecked Sendable {
    private var currentActivity: Activity<OpenLensActivityAttributes>?  // RACE
    private var pendingContent: ...  // RACE
    private var debounceTimer: Timer?  // RACE
```

**Rekomendacja:** Albo oznaczyć klasę `@MainActor`, albo przekształcić na `actor`.

---

## 3. WYSOKI: Niespójne `@MainActor` izolowanie

| Plik | Problem |
|------|---------|
| `BonjourDiscovery` | `@Observable` bez `@MainActor`, mutuje UI state przez `DispatchQueue.main.async` |
| `ConnectionManager` | `@MainActor` tylko na wybranych metodach, nie na klasie |
| `HapticController` | Opakowuje UIKit types (wymagające main thread) bez `@MainActor` |
| `SSEEventHandler` | Zakłada main-thread w komentarzu, ale nie wymusza typowo |

**Rekomendacja:** Klasy mutujące stan UI powinny mieć `@MainActor` na klasie, nie na pojedynczych metodach.

---

## 4. ŚREDNI: Hasło potencjalnie w UserDefaults

`ConnectionManager.connect()` zapisuje hasło do `ConnectionConfig`:

```swift
// ConnectionManager.swift:89
config.password = password
```

`ConnectionConfig.password` używa `KeychainService` — to jest OK. Jednak w `ConnectionManager` nie ma to wyraźnej dokumentacji, i `ConnectionConfig` łączy UserDefaults (URL, username) z Keychain (password) w jednej strukturze bez jasnej separacji.

---

## 5. ŚREDNI: Martwy kod i nieużywane protokoły

| Element | Problem |
|---------|---------|
| `ConnectionProviding` | Zdefiniowany, ale nigdzie nie używany jako typ — wszędzie jest konkretny `ConnectionManager` |
| `LiveActivityProviding` | j.w. — `LiveActivityManager` używany bezpośrednio |
| `DemoProviding` / `DemoMode` / `DemoStreamSimulator` | Usunięte (git status: `D`), ale mogą wymagać cleanup referencji |
| `ConnectionManager.onStateChange` | Pusta closure — `if case .disconnected` blok jest pusty |
| `SessionsListView.errorBanner` | `@ViewBuilder` computed property zdefiniowany ale nigdzie nie wywołany |

---

## 6. ŚREDNI: Ciche połykanie błędów

Wielokrotnie w kodzie:

```swift
let _ = try await client.abortSession(...)  // zwraca Bool — zignorowany
try? await questionService.rejectQuestion(...)  // błąd połknięty
Task { try? await ... }  // fire-and-forget bez cancellation
```

**Dotyczy:** `MessagesService`, `QuestionService`, `SessionsService`, `ChatViewModel` (6+ miejsc)

**Rekomendacja:** Przynajmniej logować błędy; dla user-facing akcji (permission, question) — pokazywać feedback.

---

## 7. ŚREDNI: Force cast w `OpenCodeClient`

```swift
// OpenCodeClient.swift:227
return EmptyResponse() as! T  // CRASH jeśli T != EmptyResponse
```

Jeśli jakikolwiek caller wywoła `postCodable` z `expect204: true` i typem innym niż `EmptyResponse`, aplikacja crashuje.

**Rekomendacja:** Zastąpić conditional castem z `throw`.

---

## 8. ŚREDNI: `ServerModels.swift` — monolityczny plik

879 linii zawierających 20+ typów z różnych domen (sesje, wiadomości, parts, tools, providery, eventy, projekty, diffy, agenty, komendy, prompty, `AnyCodable`).

**Custom `Equatable` problem:** `OCSession` i `ChatMessage` porównują się tylko po `id`, ignorując content. SwiftUI może pominąć re-render kiedy dane się zmienią, ale ID pozostanie to samo.

---

## 9. NISKI: Accessibility

Tylko `QuestionView` ma prawidłowe adnotacje accessibility (`accessibilityLabel`, `accessibilityHint`, `accessibilityAddTraits`). Reszta widoków:

- `ActivityStepRow`, `ThinkingShimmerView` — używają `.onTapGesture` zamiast `Button` (niewidoczne dla VoiceOver)
- `SessionsListView` — sesje tapowane przez `.onTapGesture`
- `ChatHeaderView`, `MessageBubbleView`, `SettingsView` — brak labeli na interaktywnych elementach
- Status indicator (zielone/szare kółko) — brak semantyki

---

## 10. NISKI: Wzorzec `ViewState` niespójnie stosowany

Tylko `SessionsListView` używa zalecanego `ViewState` enum. Inne widoki z async ładowaniem (`ConnectView`, `SettingsView`) polegają na luźnych `@State` booleanach (`isConnecting`, `isLoadingProviders`, `errorMessage`).

---

## 11. NISKI: Debug `print()` w produkcyjnym kodzie

`print()` statementy rozrzucone po: `ConnectionManager`, `OpenCodeClient`, `ProvidersService`, `SSEClient`, `SSEEventHandler`. Mogą logować wrażliwe dane (URL-e, JSON).

**Rekomendacja:** Zastąpić `os.Logger` z odpowiednim log level.

---

## Podsumowanie priorytetów

| Priorytet | Issue | Estymacja wpływu |
|-----------|-------|-----------------|
| **Krytyczny** | `ChatViewModel` God Object → rozbić na serwisy | Architektura |
| **Wysoki** | `LiveActivityManager` thread-safety | Crash/race |
| **Wysoki** | Niespójne `@MainActor` | Race conditions |
| **Średni** | Force cast w `OpenCodeClient` | Crash |
| **Średni** | Ciche połykanie błędów | UX |
| **Średni** | Martwe protokoły i kod | Maintainability |
| **Niski** | Accessibility | A11y |
| **Niski** | `ViewState` enum consistency | Code style |
| **Niski** | Debug prints | Security/noise |

---

## Co jest dobrze zrobione

- **DI przez `@Environment`** — `EnvironmentKeys.swift` to solidny setup, serwisy wstrzykiwane poprawnie
- **`SessionsListView`** — wzorcowa implementacja No-ViewModel pattern z `ViewState` enum
- **`OpenCodeClient` jako `actor`** — poprawne użycie actor isolation dla klienta HTTP
- **`ConnectionConfig`** — hasło w Keychain, nie w UserDefaults
- **Granularne komponenty** — `MessageBubbleView`, `AgentActivityCard`, `ThinkingShimmerView` to czyste presentation components
- **`MarkdownContentView`** — caching bloków przez `NSCache`, dobra architektura parsowania
- **Live Activity** — kompletna implementacja z debouncing updates i preview

---

## Szczegółowe uwagi per-plik

### Services

#### `BonjourDiscovery.swift`
- **Connection leak w `resolveService`:** `NWConnection` tworzony w line 94 jest cancelowany tylko w `.ready` case. Jeśli connection przejdzie do `.failed`/`.waiting`/`.cancelled` bez `.ready`, leakuje.
- **`DispatchWorkItem` auto-stop:** 10-sekundowy auto-stop jest funkcjonalny, ale `Task`-based approach byłby bardziej idiomatyczny.

#### `ConnectionManager.swift`
- **`self.state != nil` (line 94):** `state` jest non-optional enum — porównanie z `nil` jest zawsze `true`. Logiczny błąd.
- **Brak SSE reconnection:** Jeśli SSE rozłączy się po initial connection, `ConnectionManager.state` pozostaje `.connected` mimo że SSE nie działa.

#### `HapticController.swift`
- **Brak `@MainActor`:** Opakowuje `UIImpactFeedbackGenerator` i `UINotificationFeedbackGenerator`, które wymagają main thread.
- **Race na `hasPlayedFirstResponse`:** Mutowany bez synchronizacji.

#### `KeychainService.swift`
- **Silent failures:** `SecItemAdd` i `SecItemDelete` rezultaty są ignorowane. Caller nie wie czy operacja się udała.
- **Hardcoded string:** bundle identifier powtórzony 3 razy zamiast `static let` lub konfiguracji.

#### `LiveActivityManager.swift`
- **`previewTask?.cancel()` nie jest awaited:** W `endActivity()` task może kontynuować po zakończeniu activity.
- **`endActivity()` race z `previewLiveActivity()`:** `endActivity` dispatches a `Task` to await `activity.end(...)`, racing z tworzeniem nowej activity.

#### `OpenCodeClient.swift`
- **`appendingPathComponent` double-encodes:** Może percent-encodować slashe w `path` na niektórych wersjach OS.
- **Mieszane approach:** `JSONSerialization` (untyped) i `JSONEncoder` (typed) w tej samej klasie do body encoding.
- **Verbose logging:** `print` loguje URL każdego GET request i JSON preview decode failures.

#### `SSEClient.swift`
- **`state` property race:** Publiczne `private(set)` czytane z dowolnego thread, ale pisane na internal `queue`.
- **Retain cycle risk:** `onEvent`/`onStateChange` closures są silne. Jeśli caller zapomni `[weak self]`, memory leak.
- **SSE spec incomplete:** Ignoruje `event:` i `id:` fields — tylko `data:` jest parsowany.

#### `SSEEventHandler.swift`
- **Delegate pattern = ukryty ViewModel:** `SSEEventHandlerDelegate` z properties jak `var messages: [ChatMessage] { get set }`, `var isLoading: Bool { get set }` to de facto ViewModel interface.
- **Double serialization:** `JSONSerialization` → `Data` → `JSONDecoder` round-trip przy każdym evencie.
- **Fire-and-forget Task (line 338-340):** Odrzucanie overlapping question bez error handling.

#### `ProvidersService.swift`
- **Mieszane instance/static methods:** `loadProviders()` to instance method, `savedSelection()` to static. Dwie osobne odpowiedzialności w jednym typie.

#### `ToolLabelFormatter.swift`
- **Hardcoded tool names:** Zmiana nazw tool na serwerze cicho degraduje do fallback label.
- **`prefix(40)` tnie mid-word:** Brak word-boundary-aware truncation.

### Views

#### `ChatView.swift`
- **6 sheet presentations + alert w jednym body:** Zbyt wiele odpowiedzialności, ale CLAUDE.md mówi "rozbijaj widoki" zamiast tworzyć VM.
- **`onChange(of: scenePhase)` spawns unstructured `Task`:** Brak cancellation, potencjalnie overlapping loads.

#### `ConnectView.swift`
- **`BonjourDiscovery` jako `@State`:** Observable class jako `@State` może powodować identity issues.
- **`await MainActor.run` wewnątrz `Task` spawned z MainActor:** Redundantne.
- **Brak `ViewState` enum:** Luźne booleany zamiast ustrukturyzowanego stanu.

#### `SettingsView.swift`
- **`ConnectionConfig()` w computed property:** Tworzone na każdym re-render — I/O przy każdym display cycle.
- **`GlassCard`/`GlassIcon`/`GlassDivider` zdefiniowane lokalnie:** Reusable components powinny być wyekstrahowane.

#### `SessionsListView.swift`
- **`errorBanner` nigdy nie wywołany:** Dead code.
- **`RelativeDateTimeFormatter` alokowany per-call:** Powinien być `static let`.
- **Sesje tapowane przez `.onTapGesture`:** Niedostępne dla VoiceOver.

#### `QuestionView.swift`
- **`NavigationView` (deprecated):** Powinno być `NavigationStack`.
- **`.scaleEffect(isSelected ? 1.0 : 1.0)` — no-op** na line 241.
- **Wzorcowe accessibility** — jedyny widok z pełnymi adnotacjami.

#### `ModelPickerView.swift`
- **Coupling do `ChatViewModel.SelectableModel`:** Nested type powinien być wyekstrahowany do Models.
- **`groupedModels` to O(n²):** `models.filter` wewnątrz loop.

#### `MarkdownContentView.swift`
- **Parsing w `init` blokuje main thread** dla dużych tekstów.
- **Ordered list detection fragile:** `100. item` nie zostanie rozpoznane.

#### `MessageBubbleView.swift`
- **`markdownAttributedString` bez cache:** Wywoływane na każdym body evaluation bez caching (w przeciwieństwie do `MarkdownContentView` z `NSCache`).
- **Custom `Equatable` ignoruje cost/tokens/parts:** Po zakończeniu streamingu UI może nie zaktualizować tych pól.

### Protocols

#### `ConnectionProviding.swift`
- **Concrete type leak:** `var state: ConnectionManager.State` — protokół referencuje konkrektny typ.
- **Expose raw clients:** `var client: OpenCodeClient?` i `var sseClient: SSEClient?` to konkretne typy w abstrakcji.

#### `EnvironmentKeys.swift`
- **`nonisolated(unsafe)` na każdym default value:** Bold assertion — jeśli fallback użyty z non-main thread, data race.
- **Default values tworzą disconnected instances:** Każdy key ma swój `ConnectionManager()`.
- **Plik w `Protocols/` ale nie zawiera protokołów.**

### Models

#### `ServerModels.swift`
- **`OCPart` jako flat struct z optionalami** zamiast enum z associated values per part type.
- **Defensive decoding z silent defaults:** Brakujący `role` cicho staje się `.assistant`.

#### `ChatMessage.swift`
- **`var content: String` mutable:** VM bezpośrednio mutuje `messages[idx].content += text` podczas streamingu.

#### `AgentActivity.swift`
- **`@Observable` class jako nested model w VM:** Tworzy nested observation dependency chain.
