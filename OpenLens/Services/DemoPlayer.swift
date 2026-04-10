import Foundation

// MARK: - Demo Script Model

/// A single event in a demo script timeline.
enum DemoEvent {
    /// Show a user message instantly.
    case userMessage(String)

    /// Begin an assistant response (creates pendingAssistantMessage).
    case assistantStart

    /// Stream text in chunks with per-chunk delay.
    /// `chunkSize` controls how many characters are flushed per tick.
    case streamText(String, chunkSize: Int = 3, delay: TimeInterval = 0.02)

    /// Show a tool call activity step (shimmer + completed step).
    case toolCall(name: String, detail: String, category: ToolCategory, duration: TimeInterval = 0.8)

    /// Update the "Thinking..." shimmer label.
    case thinking(String)

    /// Finish the assistant turn (commits pending message, clears activity).
    case finish

    /// Pause for a duration (seconds).
    case pause(TimeInterval)
}

/// A complete demo script: a sequence of events to replay.
struct DemoScript {
    let sessionTitle: String
    let events: [DemoEvent]
}

// MARK: - Demo Player

/// Replays a `DemoScript` on a `ChatClient`, simulating the SSE event flow.
/// Drives pendingAssistantMessage, streaming buffer, activity steps, and finish
/// through the same code paths as real server communication.
final class DemoPlayer {

    private weak var chatClient: ChatClient?
    private var playTask: Task<Void, Never>?

    init(chatClient: ChatClient) {
        self.chatClient = chatClient
    }

    /// Start playing a script. Cancels any in-progress playback.
    func play(_ script: DemoScript) {
        playTask?.cancel()
        playTask = Task { [weak self] in
            await self?.run(script)
        }
    }

    /// Cancel current playback.
    func stop() {
        playTask?.cancel()
        playTask = nil
    }

    private func run(_ script: DemoScript) async {
        guard let client = chatClient else { return }

        for event in script.events {
            guard !Task.isCancelled else { return }

            switch event {
            case .userMessage(let text):
                let msg = ChatMessage(role: .user, content: text)
                client.messages.append(msg)
                client.scrollAnchor &+= 1

            case .assistantStart:
                let msg = ChatMessage(
                    id: UUID().uuidString,
                    role: .assistant,
                    content: "",
                    isStreaming: true,
                    modelID: "claude-sonnet-4-20250514",
                    providerID: "anthropic"
                )
                client.pendingAssistantMessage = msg
                client.isLoading = true
                client.currentActivity = AgentActivity()
                client.currentActivity?.currentLabel = "Thinking..."
                client.scrollAnchor &+= 1

            case .streamText(let text, let chunkSize, let delay):
                guard let pending = client.pendingAssistantMessage else { continue }
                // Stream character chunks through the same buffer path
                var index = text.startIndex
                while index < text.endIndex {
                    guard !Task.isCancelled else { return }
                    let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                    let chunk = String(text[index..<end])
                    client.appendStreamingText(messageID: pending.id, text: chunk)
                    index = end
                    try? await Task.sleep(for: .seconds(delay))
                }

            case .toolCall(let name, let detail, let category, let duration):
                guard let activity = client.currentActivity else { continue }
                let label = "\(name): \(detail)"
                activity.currentLabel = label
                activity.steps.append(ActivityStep(
                    type: .toolCall,
                    label: label,
                    detail: detail,
                    toolCategory: category
                ))
                client.scrollAnchor &+= 1

                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }

                // Complete the step
                if let idx = activity.steps.lastIndex(where: { $0.label == label }) {
                    activity.steps[idx].isCompleted = true
                }
                activity.currentLabel = "Thinking..."

            case .thinking(let label):
                client.currentActivity?.currentLabel = label

            case .finish:
                client.finishLoading()

            case .pause(let duration):
                try? await Task.sleep(for: .seconds(duration))
            }
        }
    }
}

// MARK: - Built-in Demo Scripts

extension DemoScript {

    /// A showcase script demonstrating streaming, tool calls, markdown, and code blocks.
    static let showcase = DemoScript(
        sessionTitle: "Demo: OpenLens Tour",
        events: [
            // --- Turn 1: User asks a question ---
            .userMessage("What files are in this project and how is it structured?"),
            .pause(0.4),

            .assistantStart,
            .thinking("Thinking..."),
            .pause(0.3),

            // Tool calls
            .toolCall(name: "Read", detail: "package.json", category: .read, duration: 0.6),
            .toolCall(name: "Glob", detail: "src/**/*.ts", category: .search, duration: 0.5),
            .toolCall(name: "Read", detail: "src/index.ts", category: .read, duration: 0.4),

            // Streaming response with markdown
            .streamText("""
            Here's an overview of the project structure:

            ## Project Layout

            The project is a **TypeScript** application with the following structure:

            ```
            src/
            ├── index.ts          # Entry point
            ├── server/
            │   ├── app.ts        # Express server setup
            │   ├── routes/       # API route handlers
            │   └── middleware/    # Auth & logging middleware
            ├── services/
            │   ├── database.ts   # Database connection
            │   └── cache.ts      # Redis cache layer
            └── utils/
                ├── logger.ts     # Structured logging
                └── config.ts     # Environment config
            ```

            ### Key observations:

            1. **Express-based REST API** with route handlers in `src/server/routes/`
            2. Uses **Redis** for caching and **PostgreSQL** for persistence
            3. Middleware handles authentication via JWT tokens
            4. Structured logging with `pino` for production observability

            The entry point `src/index.ts` bootstraps the server and connects to both databases on startup.
            """, chunkSize: 2, delay: 0.012),

            .finish,
            .pause(1.0),

            // --- Turn 2: User asks for a code change ---
            .userMessage("Add a health check endpoint to the server"),
            .pause(0.4),

            .assistantStart,
            .thinking("Thinking..."),
            .pause(0.3),

            .toolCall(name: "Read", detail: "src/server/app.ts", category: .read, duration: 0.5),
            .toolCall(name: "Read", detail: "src/server/routes/index.ts", category: .read, duration: 0.4),

            .streamText("""
            I'll add a health check endpoint that reports the status of all service dependencies.

            """, chunkSize: 2, delay: 0.015),

            .toolCall(name: "Edit", detail: "src/server/routes/health.ts", category: .edit, duration: 0.7),
            .toolCall(name: "Edit", detail: "src/server/app.ts", category: .edit, duration: 0.5),

            .streamText("""
            I've created a new health check endpoint at `GET /health`. Here's what it does:

            ```typescript
            router.get('/health', async (req, res) => {
              const checks = {
                database: await checkDatabase(),
                cache: await checkRedis(),
                uptime: process.uptime(),
                timestamp: new Date().toISOString()
              };

              const healthy = checks.database && checks.cache;
              res.status(healthy ? 200 : 503).json({
                status: healthy ? 'ok' : 'degraded',
                ...checks
              });
            });
            ```

            ### Changes made:
            - **Created** `src/server/routes/health.ts` — new health check route
            - **Updated** `src/server/app.ts` — registered the `/health` route

            The endpoint returns `200 OK` when all services are healthy, or `503 Service Unavailable` with details about which check failed.
            """, chunkSize: 2, delay: 0.012),

            .finish,
            .pause(1.0),

            // --- Turn 3: Run tests ---
            .userMessage("Run the tests to make sure nothing is broken"),
            .pause(0.4),

            .assistantStart,
            .thinking("Thinking..."),
            .pause(0.2),

            .toolCall(name: "Bash", detail: "npm test", category: .bash, duration: 2.0),

            .streamText("""
            All tests pass:

            ```
            PASS  src/server/__tests__/health.test.ts
            PASS  src/server/__tests__/routes.test.ts
            PASS  src/services/__tests__/database.test.ts

            Test Suites: 3 passed, 3 total
            Tests:       12 passed, 12 total
            Time:        1.847s
            ```

            Everything looks good — the health check endpoint is working correctly and existing tests still pass.
            """, chunkSize: 3, delay: 0.012),

            .finish,
        ]
    )
}
