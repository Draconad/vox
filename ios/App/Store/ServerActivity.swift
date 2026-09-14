import Combine
import Foundation

/// Tells you when the server has gone quiet because it's loading a model.
///
/// audio.cpp announces nothing: a request against a model that isn't resident simply
/// takes much longer, because the load happens inside it. With `lazy_load` on, and
/// `max_loaded_models` evicting whatever was least recently used, that's the first
/// request after a gap — and from the phone an eight-second load looks exactly like a
/// hang. So this infers it: any request still unanswered after a couple of seconds is
/// reported as a load, named, with a running clock.
@MainActor
final class ServerActivity: ObservableObject {

    static let shared = ServerActivity()

    /// The model the server is believed to be loading, once a request has been slow
    /// enough to say so. Nil when nothing is outstanding or everything is prompt.
    @Published private(set) var loadingModel: String?
    @Published private(set) var loadingKind: String?
    @Published private(set) var seconds: Int = 0

    /// A request that returns faster than this was almost certainly served by a model
    /// already in memory, and saying "loading" about it would be noise.
    private let threshold: TimeInterval = 2.0

    private struct Job {
        var model: String
        var kind: String
        var started: Date
    }

    private var jobs: [UUID: Job] = [:]
    private var ticker: Task<Void, Never>?

    private init() {}

    /// Models seen to answer promptly at least once, so a second slow request against
    /// one is reported as a reload rather than a first load.
    private var warm: Set<String> = []

    func begin(model: String, kind: String) -> UUID {
        let id = UUID()
        jobs[id] = Job(model: model, kind: kind, started: Date())
        startTicking()
        return id
    }

    func end(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        if Date().timeIntervalSince(job.started) < threshold {
            warm.insert(job.model)
        }
        if jobs.isEmpty {
            ticker?.cancel()
            ticker = nil
            loadingModel = nil
            loadingKind = nil
            seconds = 0
        }
    }

    /// True once a model has answered quickly, so the wording can say "reloading".
    func hasBeenWarm(_ model: String) -> Bool { warm.contains(model) }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                self.evaluate()
                if self.jobs.isEmpty { return }
            }
        }
    }

    private func evaluate() {
        // The oldest outstanding request is the one holding everything up.
        guard let oldest = jobs.values.min(by: { $0.started < $1.started }) else {
            loadingModel = nil
            loadingKind = nil
            seconds = 0
            return
        }
        let elapsed = Date().timeIntervalSince(oldest.started)
        // Only publish on a real change: @Published fires objectWillChange whether or
        // not the value moved, and every screen observing this would redraw 4x a second
        // for the whole of every request.
        if elapsed >= threshold {
            let whole = Int(elapsed)
            if loadingModel != oldest.model { loadingModel = oldest.model }
            if loadingKind != oldest.kind { loadingKind = oldest.kind }
            if seconds != whole { seconds = whole }
        } else if loadingModel != nil {
            loadingModel = nil
            loadingKind = nil
            seconds = 0
        }
    }

    /// One line for the UI: "Loading tts-higgs… 6s".
    var label: String? {
        guard let loadingModel else { return nil }
        let verb = hasBeenWarm(loadingModel) ? "Reloading" : "Loading"
        return "\(verb) \(loadingModel)… \(seconds)s"
    }
}
