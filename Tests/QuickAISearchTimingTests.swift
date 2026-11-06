// QuickAISearchTimingTests — a live timing harness for Quick AI web answers.
// It drives the real `OpenAICompatibleService` and `WebSearchRouter` against
// the real providers, so it runs only when asked and asserts nothing about
// time: it writes one JSON line per question for the before/after table.
//
//   QUICK_LAUNCH_LIVE_SEARCH=1 QL_TIMING_OUT=/tmp/run.jsonl \
//   QL_TIMING_MODE=loop DEEPSEEK_API_KEY=… TAVILY_API_KEY=… \
//   BRAVE_API_KEY=… BOCHA_API_KEY=… \
//   swift test --filter QuickAISearchTimingTests
//
// Modes: `loop` (the model decides when to search), `presearch` (one
// search on the question, then one model round), `app` (search first only
// when WebSearchIntentDetector routes the question there, otherwise as
// `loop`: the Quick AI path), `backends` (each backend alone, per question).
// Optional: QL_SEARCH_PROVIDER (default automatic), QL_MODEL (default
// deepseek-flash), QL_QUESTION_INDEX (one question by index),
// QL_STALL_DEEPSEEK=1 (DeepSeek search hangs until its 5 s timeout).
// Keys come from the environment only and are never written anywhere.

import Foundation
import Testing
@testable import QuickLaunch

@Suite(
    "Quick AI search timing (live)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_LIVE_SEARCH"] == "1")
)
struct QuickAISearchTimingTests {
    static let questions = [
        "what is the latest version of Swift",
        "who won the most recent Formula 1 race",
        "latest news on the Fed interest rate decision",
        "what is Anthropic's newest Claude model",
        "USD to CNY exchange rate today",
        "what is the weather in Shanghai today",
        "latest on the Apple M5 MacBook Pro",
        "who is the current CEO of Intel",
        "what is Model Context Protocol",
        "最新的DeepSeek模型是什么",
    ]

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static func key(_ name: String) -> String? {
        let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Records how long each backend took and whether it answered.
    actor BackendLog {
        struct Entry: Codable { let backend: String; let ms: Double; let ok: Bool; var cancelled = false }
        var entries: [Entry] = []
        func add(_ entry: Entry) { entries.append(entry) }
        func drain() -> [Entry] { defer { entries = [] }; return entries }
    }

    struct Timed: WebSearchServicing {
        let name: String
        let inner: any WebSearchServicing
        let log: BackendLog
        func search(_ query: String) async throws -> String {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let result = try await inner.search(query)
                await log.add(.init(backend: name, ms: ms(clock.now - start), ok: true))
                return result
            } catch {
                // A hedge loser is cancelled, not failed.
                await log.add(.init(
                    backend: name, ms: ms(clock.now - start), ok: false,
                    cancelled: Task.isCancelled || error is CancellationError
                ))
                throw error
            }
        }
    }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }

    /// `QL_STALL_DEEPSEEK=1` makes DeepSeek search hang until its own 5 s
    /// timeout, to time the chain when its first provider stalls.
    static var stallDeepSeek: Bool { env["QL_STALL_DEEPSEEK"] == "1" }

    struct Stalled: WebSearchServicing {
        func search(_ query: String) async throws -> String {
            try await Task.sleep(for: .seconds(5))
            throw WebSearchError.timedOut
        }
    }

    static func router(log: BackendLog) -> WebSearchRouter {
        let ds = key("DEEPSEEK_API_KEY"), tv = key("TAVILY_API_KEY")
        let br = key("BRAVE_API_KEY"), bo = key("BOCHA_API_KEY"), ex = key("EXA_API_KEY")
        return WebSearchRouter(
            deepseek: Timed(name: "deepseek", inner: stallDeepSeek ? Stalled() : DeepSeekSearchService(apiKey: { ds }), log: log),
            tavily: Timed(name: "tavily", inner: TavilySearchService(apiKey: { tv }), log: log),
            brave: Timed(name: "brave", inner: BraveSearchService(apiKey: { br }), log: log),
            bocha: Timed(name: "bocha", inner: BochaSearchService(apiKey: { bo }), log: log),
            exa: Timed(name: "exa", inner: ExaSearchService(apiKey: { ex }), log: log),
            hasDeepSeekKey: { ds != nil },
            hasTavilyKey: { tv != nil },
            hasBraveKey: { br != nil },
            hasBochaKey: { bo != nil },
            hasExaKey: { ex != nil }
        )
    }

    /// A memory backend that finds nothing, so the request offers the same
    /// tool set as a default Quick AI (memory, tasks, skills, web).
    struct EmptyMemory: MemoryRecalling {
        func search(_ query: String) async throws -> MemorySearchResult { throw WebSearchError.empty }
        func today() async throws -> MemoryToday { throw WebSearchError.empty }
        func openTasks() async throws -> RecalledTaskList { throw WebSearchError.empty }
    }

    static func service(
        router: WebSearchRouter,
        rounds: RoundLog
    ) -> OpenAICompatibleService {
        let provider = WebSearchProvider(rawValue: env["QL_SEARCH_PROVIDER"] ?? "automatic") ?? .automatic
        return OpenAICompatibleService(
            baseURL: URL(string: "https://api.deepseek.com")!,
            modelName: env["QL_MODEL"] ?? "deepseek-flash",
            apiKey: key("DEEPSEEK_API_KEY"),
            systemPrompt: ChatContextGate.systemInstruction(
                surfacePrompt: QuickSettings.defaultSystemPrompt,
                grounded: false,
                lane: .model
            ),
            webSearch: { query in try await router.search(query, provider: provider) },
            tools: ChatToolbox(enabled: [.memory, .tasks, .web], memory: EmptyMemory(), skills: SkillLibrary()),
            reasoningEffort: .modelDefault,
            thinkingSupported: true,
            beforeRequest: { round in await rounds.mark(round.round, bytes: round.body.count) }
        )
    }

    static func routesToSearch(_ question: String) -> Bool {
        WebSearchIntentDetector.shouldSearch(question, plainQuestion: true)
    }

    actor RoundLog {
        let clock = ContinuousClock()
        let start: ContinuousClock.Instant
        var marks: [[String: Double]] = []
        init() { start = ContinuousClock().now }
        func mark(_ round: Int, bytes: Int) {
            marks.append(["round": Double(round), "atMs": QuickAISearchTimingTests.ms(clock.now - start), "bodyBytes": Double(bytes)])
        }
    }

    struct Row: Codable {
        let mode: String
        let question: String
        var firstTokenMs: Double?
        var totalMs: Double
        var modelRequests: Int
        var toolCalls: [String]
        var toolRoundMs: [Double]
        var backends: [BackendLog.Entry]
        var roundStartsMs: [Double]
        var bodyBytes: [Double]
        var answerChars: Int
        var error: String?
    }

    static func write(_ row: Row) throws {
        guard let path = env["QL_TIMING_OUT"] else { return }
        var data = try JSONEncoder().encode(row)
        data.append(0x0A)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try handle.close()
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func timeEveryQuestion() async throws {
        let mode = Self.env["QL_TIMING_MODE"] ?? "loop"
        let log = BackendLog()
        let router = Self.router(log: log)
        let only = Self.env["QL_QUESTION_INDEX"].flatMap(Int.init)
        for (index, question) in Self.questions.enumerated() where only == nil || only == index {
            if mode == "backends" {
                for (name, provider) in [("deepseek", WebSearchProvider.deepseek), ("tavily", .tavily), ("brave", .brave), ("bocha", .bocha)] {
                    let clock = ContinuousClock()
                    let start = clock.now
                    var failure: String?
                    var chars = 0
                    do { chars = try await router.search(question, provider: provider).count } catch { failure = "\(error)" }
                    _ = await log.drain()
                    try Self.write(Row(
                        mode: "backend:\(name)", question: question, firstTokenMs: nil,
                        totalMs: Self.ms(clock.now - start), modelRequests: 0, toolCalls: [],
                        toolRoundMs: [], backends: [], roundStartsMs: [], bodyBytes: [],
                        answerChars: chars, error: failure
                    ))
                }
                continue
            }
            let rounds = RoundLog()
            let service = Self.service(router: router, rounds: rounds)
            let clock = ContinuousClock()
            let start = clock.now
            var row = Row(mode: mode, question: question, firstTokenMs: nil, totalMs: 0, modelRequests: 0,
                          toolCalls: [], toolRoundMs: [], backends: [], roundStartsMs: [], bodyBytes: [],
                          answerChars: 0, error: nil)
            var messages = [QuickMessage(role: .user, content: question)]
            // `app` routes as Quick AI does: search first when the detector
            // says so, otherwise the model decides.
            let searchFirst = mode == "presearch" || (mode == "app" && Self.routesToSearch(question))
            if searchFirst {
                do {
                    let bundle = try await router.search(question, provider: .automatic)
                    messages = [QuickMessage(role: .user, content: await QuickViewModel.webAnswerPrompt(question: question, searchBundle: bundle))]
                } catch {
                    row.error = "presearch: \(error)"
                }
            }
            do {
                for try await delta in service.send(messages: messages) {
                    if let text = delta.text, !text.isEmpty {
                        if row.firstTokenMs == nil { row.firstTokenMs = Self.ms(clock.now - start) }
                        row.answerChars += text.count
                    }
                    if let round = delta.toolRound {
                        row.toolCalls += round.calls.map { $0.name ?? "?" }
                        row.toolRoundMs.append((round.durationSeconds ?? 0) * 1_000)
                    }
                }
            } catch {
                row.error = "\(error)"
            }
            row.totalMs = Self.ms(clock.now - start)
            let marks = await rounds.marks
            row.modelRequests = marks.count
            row.roundStartsMs = marks.compactMap { $0["atMs"] }
            row.bodyBytes = marks.compactMap { $0["bodyBytes"] }
            row.backends = await log.drain()
            try Self.write(row)
        }
    }
}
