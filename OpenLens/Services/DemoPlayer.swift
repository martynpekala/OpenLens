import Foundation

// MARK: - Demo Script Model

/// A single event in a demo script timeline.
enum DemoEvent {
    /// Show a user message instantly.
    case userMessage(String)

    /// Begin an assistant response (creates pendingAssistantMessage).
    case assistantStart

    /// Add a reasoning part to the pending assistant message.
    case reasoning(String)

    /// Stream a reasoning part in chunks through the same buffered projection
    /// path used by live SSE deltas.
    case streamReasoning(String, chunkSize: Int = 3, delay: TimeInterval = 0.02)

    /// Stream text in chunks with per-chunk delay.
    /// `chunkSize` controls how many characters are flushed per tick.
    case streamText(String, chunkSize: Int = 3, delay: TimeInterval = 0.02)

    /// Stream text while injecting a second user message into the transcript.
    /// This deliberately exercises the chat list while the first assistant
    /// response is still live; it does not require a second network stream.
    case streamTextWithConcurrentSend(
        String,
        chunkSize: Int = 3,
        delay: TimeInterval = 0.02,
        userMessage: String,
        after: TimeInterval
    )

    /// Seed a large local transcript in one structural update before streaming.
    case seedHistory(messageCount: Int)

    /// Show a tool call activity step (shimmer + completed step).
    case toolCall(name: String, detail: String, category: ToolCategory, duration: TimeInterval = 0.8)

    /// Show a persisted tool call inside the message bubble and the activity card.
    case toolCallPart(
        name: String,
        detail: String,
        category: ToolCategory,
        output: String? = nil,
        duration: TimeInterval = 0.8
    )

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

        for (eventIndex, event) in script.events.enumerated() {
            guard !Task.isCancelled else { return }
#if DEBUG
            print("CHAT_STRESS_EVENT_BEGIN \(eventIndex)")
#endif

            switch event {
            case .userMessage(let text):
                let msg = ChatMessage(role: .user, content: text)
                client.messages.append(msg)
                client.scrollAnchor &+= 1

            case .seedHistory(let messageCount):
                let history = makeStressHistory(
                    messageCount: max(0, messageCount),
                    sessionID: currentSessionID(for: client)
                )
                client.messages.append(contentsOf: history)
                // Keep enough rows live to exercise scrolling while retaining
                // pagination for the remainder of the seeded transcript.
                client.displayLimit = min(60, max(client.displayLimit, history.count))
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
                client.responseState = .generating
                client.currentActivity = AgentActivity()
                client.currentActivity?.currentLabel = "Thinking..."
                client.scrollAnchor &+= 1

            case .reasoning(let text):
                guard let pending = client.pendingAssistantMessage else { continue }
                let reasoningPart = OCPart(
                    id: UUID().uuidString,
                    sessionID: currentSessionID(for: client),
                    messageID: pending.id,
                    type: .reasoning,
                    text: text
                )
                upsertPart(reasoningPart, on: pending)
                client.currentActivity?.thinkingText = text
                client.messageLayoutDidChange()
                client.scrollAnchor &+= 1

            case .streamReasoning(let text, let chunkSize, let delay):
                guard let pending = client.pendingAssistantMessage else { continue }
                let partID = UUID().uuidString
                upsertPart(
                    OCPart(
                        id: partID,
                        sessionID: currentSessionID(for: client),
                        messageID: pending.id,
                        type: .reasoning,
                        text: ""
                    ),
                    on: pending
                )
                client.messageLayoutDidChange()

                var index = text.startIndex
                while index < text.endIndex {
                    guard !Task.isCancelled else { return }
                    let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
                    let chunk = String(text[index..<end])
                    client.appendStreamingReasoning(
                        messageID: pending.id,
                        partID: partID,
                        text: chunk,
                        chunks: [chunk]
                    )
                    index = end
                    guard await client.waitForStreamingRenderCapacity() else { return }
                    try? await Task.sleep(for: .seconds(delay))
                }

            case .streamText(let text, let chunkSize, let delay):
                await streamText(text, chunkSize: chunkSize, delay: delay, on: client)

            case .streamTextWithConcurrentSend(
                let text,
                let chunkSize,
                let delay,
                let userMessage,
                let after
            ):
                let injectionTask = Task { @MainActor [weak client] in
                    do {
                        try await Task.sleep(for: .seconds(max(0, after)))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, let client else { return }
                    client.messages.append(
                        ChatMessage(
                            role: .user,
                            content: userMessage,
                            createdAt: Date()
                        )
                    )
                    client.scrollAnchor &+= 1
                }
                await streamText(text, chunkSize: chunkSize, delay: delay, on: client)
                injectionTask.cancel()

            case .toolCall(let name, let detail, let category, let duration):
                await runActivityToolCall(
                    name: name,
                    detail: detail,
                    category: category,
                    duration: duration,
                    on: client
                )

            case .toolCallPart(let name, let detail, let category, let output, let duration):
                guard let pending = client.pendingAssistantMessage else { continue }
                let partID = UUID().uuidString
                let toolName = name.lowercased()
                let input: AnyCodable?
                if toolName == "task" {
                    input = AnyCodable([
                        "subagent_type": "explore",
                        "description": detail
                    ])
                } else {
                    input = toolInput(for: category, detail: detail)
                }

                upsertPart(
                    OCPart(
                        id: partID,
                        sessionID: currentSessionID(for: client),
                        messageID: pending.id,
                        type: .tool,
                        callID: partID,
                        tool: toolName,
                        state: OCToolState(status: .running, input: input)
                    ),
                    on: pending
                )
                client.messageLayoutDidChange()

                await runActivityToolCall(
                    name: name,
                    detail: detail,
                    category: category,
                    duration: duration,
                    on: client
                )

                guard !Task.isCancelled else { return }
                upsertPart(
                    OCPart(
                        id: partID,
                        sessionID: currentSessionID(for: client),
                        messageID: pending.id,
                        type: .tool,
                        callID: partID,
                        tool: toolName,
                        state: OCToolState(status: .completed, input: input, output: output)
                    ),
                    on: pending
                )
                client.messageLayoutDidChange()

            case .thinking(let label):
                client.currentActivity?.currentLabel = label

            case .finish:
                client.finishLoading()

            case .pause(let duration):
                try? await Task.sleep(for: .seconds(duration))
            }
#if DEBUG
            print(
                "CHAT_STRESS_EVENT_END \(eventIndex) messages=\(client.messages.count) "
                    + "displayed=\(client.displayedMessages.count) timeline=\(client.timelineVersion) "
                    + "content=\(client.contentVersion)"
            )
#endif
        }
    }

    private func currentSessionID(for client: ChatClient) -> String {
        client.currentSession?.id ?? "demo-session"
    }

    @MainActor
    private func streamText(
        _ text: String,
        chunkSize: Int,
        delay: TimeInterval,
        on client: ChatClient
    ) async {
        guard let pending = client.pendingAssistantMessage else { return }
        let safeChunkSize = max(1, chunkSize)

        // Stream character chunks through the same bounded buffer path used by
        // live SSE and recorded replay producers.
        var index = text.startIndex
        while index < text.endIndex {
            guard !Task.isCancelled else { return }
            let end = text.index(index, offsetBy: safeChunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            client.appendStreamingText(messageID: pending.id, text: chunk)
            index = end
            guard await client.waitForStreamingRenderCapacity() else { return }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    @MainActor
    private func makeStressHistory(messageCount: Int, sessionID: String) -> [ChatMessage] {
        guard messageCount > 0 else { return [] }

        var history: [ChatMessage] = []
        history.reserveCapacity(messageCount * 2)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<messageCount {
            let createdAt = baseDate.addingTimeInterval(TimeInterval(index * 2))
            history.append(
                ChatMessage(
                    id: "stress-user-\(index)",
                    role: .user,
                    content: "Inspect workspace checkpoint \(index): keep the stream responsive while older messages remain scrollable.",
                    createdAt: createdAt
                )
            )

            history.append(
                ChatMessage(
                    id: "stress-assistant-\(index)",
                    role: .assistant,
                    content: "Checkpoint \(index) completed. The transcript keeps stable row identity and bounded rendering while OpenCode continues working.",
                    parts: [
                        OCPart(
                            id: "stress-part-\(index)",
                            sessionID: sessionID,
                            messageID: "stress-assistant-\(index)",
                            type: .text,
                            text: "Checkpoint \(index) completed. The transcript keeps stable row identity and bounded rendering while OpenCode continues working."
                        )
                    ],
                    createdAt: createdAt.addingTimeInterval(1)
                )
            )
        }

        return history
    }

    private func upsertPart(_ part: OCPart, on message: ChatMessage) {
        if let existingIndex = message.parts.firstIndex(where: { $0.id == part.id }) {
            message.parts[existingIndex] = part
        } else {
            message.parts.append(part)
        }
    }

    private func toolInput(for category: ToolCategory, detail: String) -> AnyCodable? {
        switch category {
        case .read, .write, .edit:
            return AnyCodable(["path": detail])
        case .search:
            return AnyCodable(["pattern": detail])
        case .bash:
            return AnyCodable(["command": detail])
        default:
            return detail.isEmpty ? nil : AnyCodable(["path": detail])
        }
    }

    private func runActivityToolCall(
        name: String,
        detail: String,
        category: ToolCategory,
        duration: TimeInterval,
        on client: ChatClient
    ) async {
        guard let activity = client.currentActivity else { return }

        let label = "\(name): \(detail)"
        activity.currentLabel = label
        _ = activity.recordToolCallIfNeeded(
            label: label,
            detail: detail,
            toolCategory: category
        )
        client.scrollAnchor &+= 1

        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }

        activity.completeStep(labeled: label)
        activity.currentLabel = "Thinking..."
    }
}

// MARK: - Built-in Demo Scripts

extension DemoScript {

    private static let debugBaselineLongParagraph = Array(
        repeating: "The chat should keep feeling continuous even while new deltas arrive, the message bubble grows, tool rows appear, and the renderer eventually swaps the lightweight streaming text for a fully parsed markdown view.",
        count: 6
    ).joined(separator: " ")

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

    /// A deterministic stress script for comparing chat behavior before and after rendering changes.
    static let debugBaseline = DemoScript(
        sessionTitle: "Debug: Chat Baseline",
        events: [
            .userMessage("Stress-test the chat so I can compare the current behavior with an improved build."),
            .pause(0.25),

            .assistantStart,
            .thinking("Inspecting stream cadence..."),
            .reasoning("""
            1. Watching how fast deltas land in the pending message.
            2. Checking whether tool rows shift layout while the answer is still streaming.
            3. Comparing plain streaming text with the final markdown render handoff.
            """),
            .pause(0.15),

            .toolCallPart(name: "Read", detail: "OpenLens/Views/ChatView.swift", category: .read, duration: 0.35),
            .toolCallPart(name: "Read", detail: "OpenLens/Views/Components/MarkdownContentView.swift", category: .read, duration: 0.28),
            .toolCallPart(
                name: "Bash",
                detail: "instruments trace --focus chat-stream",
                category: .bash,
                output: "Collected 4 samples; main-thread spikes line up with scroll and markdown handoff.",
                duration: 0.45
            ),
            .toolCallPart(
                name: "Task",
                detail: "Explore the rendering path for active subagent work",
                category: .search,
                duration: 10.0
            ),

            .streamText("""
            Here's a deliberately heavy baseline response for visual comparison.

            ## What this scenario is stressing

            - **Long streaming text** so you can watch the cadence of incoming deltas.
            - **Reasoning content** so the bubble contains auxiliary sections before the answer finishes.
            - **Tool call rows** so layout changes happen while the stream is still active.
            - **Markdown handoff** so the final render includes headings, lists, and code blocks.

            ### Observations

            \(debugBaselineLongParagraph)

            \(debugBaselineLongParagraph)

            ```swift
            struct ChatStreamSample {
                let flushInterval: Double
                let scrollThrottle: Double
                let usesMarkdownAfterFinish: Bool
            }

            let baseline = ChatStreamSample(
                flushInterval: 0.04,
                scrollThrottle: 0.18,
                usesMarkdownAfterFinish: true
            )
            ```

            ### Why this helps

            1. If the stream looks smooth here, buffering and scroll cadence are probably healthy.
            2. If it stalls near the end, the markdown handoff is likely the most visible hitch.
            3. If it keeps dragging you back to the bottom while you scroll up, follow-latest logic needs attention.
            4. If tool rows pop in with jumps, message part updates are doing too much work during rendering.

            Final note: this response is intentionally long, formatted, and streamed in tiny chunks so it behaves like a repeatable stress test for the current chat UI.
            """, chunkSize: 1, delay: 0.005),
            .finish,
        ]
    )

    /// Debug profile exposed from Connect. It starts with a large local
    /// transcript, keeps a paginated window visible, and then streams the same
    /// heavy reasoning/answer workload used by the stress launch argument.
    static let heavyLoad = DemoScript(
        sessionTitle: "Debug: Heavy Chat Load",
        events: [
            .seedHistory(messageCount: 180),
            .userMessage("Stress the chat while older messages remain available."),
            .assistantStart,
            .thinking("Streaming against a heavy transcript…"),
            .streamReasoning(streamStressReasoning, chunkSize: 960, delay: 0.012),
        ] + streamStressTools + [
            .streamText(streamStressAnswer, chunkSize: 960, delay: 0.012),
            .finish,
        ]
    )

    /// Debug profile that inserts a second user message while the first
    /// response is still streaming. This stresses layout invalidation,
    /// auto-follow and the scroll-to-latest affordance at the same time.
    static let concurrentSend = DemoScript(
        sessionTitle: "Debug: Send During Stream",
        events: [
            .seedHistory(messageCount: 90),
            .userMessage("Start a response, then send another message while it is still streaming."),
            .assistantStart,
            .thinking("The next message will arrive during this response…"),
            .streamTextWithConcurrentSend(
                streamStressAnswer,
                chunkSize: 720,
                delay: 0.012,
                userMessage: "Second message sent while the first response is still streaming.",
                after: 0.9
            ),
            .finish,
        ]
    )

    /// Debug-only workload used with the `CHAT_STREAM_STRESS_MODE` launch
    /// argument. It exercises the production chat projection with roughly
    /// 100 KB each of reasoning and answer text plus many persisted tool rows.
    private static let streamStressReasoning = Array(
        repeating: "Reasoning pass: inspect event order, preserve the latest suffix, and keep the interface responsive while the thought transcript grows.",
        count: 900
    ).joined(separator: "\n")

    private static let streamStressAnswer = Array(
        repeating: """
        ## Streaming checkpoint

        - The response is intentionally long enough to cross many stable text chunks.
        - Tool rows above must retain their identity while the visible tail changes.
        - The final Markdown handoff should remain incremental and responsive.
        """,
        count: 550
    ).joined(separator: "\n\n")

    private static let streamStressTools: [DemoEvent] = (1...24).map { index in
        let category: ToolCategory = switch index % 4 {
        case 0: .read
        case 1: .search
        case 2: .bash
        default: .edit
        }
        let name: String = switch category {
        case .read: "Read"
        case .search: "Glob"
        case .bash: "Bash"
        case .edit: "Edit"
        default: "Tool"
        }
        return .toolCallPart(
            name: name,
            detail: "stress-fixture/step-\(index)",
            category: category,
            output: index.isMultiple(of: 3) ? "Completed stress step \(index)." : nil,
            duration: 0.015
        )
    }

    static let streamStress = DemoScript(
        sessionTitle: "Debug: 100 KB Stream Stress",
        events: [
            // Let the debug-only root finish its cold SwiftUI construction before
            // the first measured stream event in a real-device profiler run.
            .pause(15),
            .userMessage("Run the full chat streaming stress fixture."),
            .assistantStart,
            .thinking("Starting 100 KB reasoning stream…"),
            .streamReasoning(streamStressReasoning, chunkSize: 960, delay: 0.012),
        ] + streamStressTools + [
            .thinking("Streaming 100 KB Markdown answer…"),
            .streamText(streamStressAnswer, chunkSize: 960, delay: 0.012),
            .finish,
        ]
    )
}
