import Foundation
import Observation

extension HFHubClient.DatasetSummary {
    /// Fixtures and previews (the API shape comes through `Decodable`).
    public init(id: String, isPrivate: Bool = true, tags: [String] = [], lastModified: String? = nil) {
        var o: [String: JSONValue] = ["id": .string(id), "private": .bool(isPrivate), "tags": .array(tags.map(JSONValue.string))]
        if let lastModified { o["lastModified"] = .string(lastModified) }
        self = try! JSONDecoder().decode(Self.self, from: Data(JSONValue.object(o).compact.utf8))
    }
}

/// Drives one training run from the app: puts the bundled script into the user's dataset repo, creates the HF Job,
/// polls status + logs, and exposes `TrainingProgress` for the UI. Pure HFHubClient calls underneath (injectable
/// transport → testable with a replay transport). One session = one job.
@MainActor @Observable
public final class TrainingSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing(String)        // "Uploading script…", "Creating job…"
        case running(jobId: String)
        case finished(jobId: String, output: TrainingOutput)
        case failed(jobId: String?, reason: String)
        case cancelled(jobId: String)

        public var jobId: String? {
            switch self { case .running(let j), .cancelled(let j): j; case .finished(let j, _): j; case .failed(let j, _): j; default: nil }
        }
        public var isActive: Bool { if case .preparing = self { return true }; if case .running = self { return true }; return false }
    }

    public let plan: TrainingPlan
    public let user: String
    public private(set) var phase: Phase = .idle
    public private(set) var progress = TrainingProgress()
    public private(set) var job: HFHubClient.Job?
    public private(set) var logTail: [String] = []
    public private(set) var startedAt: Date?
    public private(set) var scriptVersion: String?

    private let client: HFHubClient
    private let script: Data
    private let pollInterval: Duration
    private var poller: Task<Void, Never>?

    /// - Parameters:
    ///   - client: a token-bound `HFHubClient` (`HFAccount.shared.client()`); the token also becomes the job's `HF_TOKEN` secret.
    ///   - script: the bytes of the bundled `train/loopl_sft.py`.
    public init(plan: TrainingPlan, user: String, client: HFHubClient, script: Data, pollInterval: Duration = .seconds(5)) {
        self.plan = plan; self.user = user; self.client = client; self.script = script; self.pollInterval = pollInterval
        self.scriptVersion = TrainingLaunch.scriptVersion(in: String(decoding: script, as: UTF8.self))
    }

    public var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    public var jobURL: URL? { phase.jobId.flatMap { URL(string: "\(client.host)/jobs/\(user)/\($0)") } }
    /// Billed so far, from the flavor's hourly price (HF bills per minute).
    public var spentUSD: Double { elapsed / 3600 * plan.flavor.usdPerHour }

    /// Step 1+2 of the launch contract: script into `<dataset>/train/loopl_sft.py` (skipped when the same version is already there),
    /// then `POST /api/jobs/<user>`. Returns the job id. Errors leave `phase == .failed`.
    @discardableResult
    public func launch(now: Date = Date()) async throws -> String {
        guard let token = client.token, !token.isEmpty else { phase = .failed(jobId: nil, reason: HFHubError.noToken.errorDescription ?? "no token"); throw HFHubError.noToken }
        do {
            phase = .preparing("Uploading training script")
            try await ensureScript()
            phase = .preparing("Creating job on Hugging Face")
            var spec = TrainingLaunch.jobSpec(plan: plan, user: user, token: token, now: now)
            spec.environment["LOOPL_JOB_NAME"] = TrainingPlan.jobName(outputName: plan.outputName, now: now)
            let created = try await client.createJob(namespace: user, spec)
            job = created
            startedAt = now
            progress = TrainingProgress()
            phase = .running(jobId: created.id)
            startPolling(id: created.id)
            return created.id
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            phase = .failed(jobId: nil, reason: reason)
            throw error
        }
    }

    /// Re-attach to a job that is already running (app relaunch).
    public func attach(jobId: String, startedAt: Date? = nil) {
        self.startedAt = startedAt ?? Date()
        phase = .running(jobId: jobId)
        startPolling(id: jobId)
    }

    public func cancel() async {
        guard case .running(let id) = phase else { return }
        poller?.cancel()
        do { try await client.cancelJob(namespace: user, id: id) } catch { /* a finished job cannot be cancelled; the next poll says so */ }
        phase = .cancelled(jobId: id)
    }

    /// One poll: job status + the log buffer. Public so tests can drive it without the timer.
    public func poll(id: String) async {
        do {
            let j = try await client.job(namespace: user, id: id)
            job = j
            let lines = try await client.jobLogs(namespace: user, id: id, timeout: 8)
            if !lines.isEmpty {
                progress = TrainingProgress()                       // the endpoint returns the whole buffer; re-parse idempotently
                progress.ingest(lines.map(\.text))
                logTail = Array(lines.suffix(60).map(\.text))
            }
            if j.isDone {
                poller?.cancel()
                if let out = progress.output, j.succeeded {
                    phase = .finished(jobId: id, output: out)
                } else if j.stage == "CANCELED" {
                    phase = .cancelled(jobId: id)
                } else {
                    // the last log line usually names the real cause ("CUDA out of memory"); HF's status message is "exit code 1"
                    progress.markFailed(progress.lastLine == nil ? j.status.message : nil)
                    phase = .failed(jobId: id, reason: progress.error ?? j.status.message ?? "job \(j.stage.lowercased())")
                }
            }
        } catch is CancellationError {
        } catch {
            // transient network errors keep the session running; the next tick retries
            logTail.append("[loopl-app] poll error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    private func startPolling(id: String) {
        poller?.cancel()
        poller = Task { [weak self, pollInterval] in
            while let self, !Task.isCancelled {
                await self.poll(id: id)
                if !self.phase.isActive { break }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// A session with pre-baked state and no network — design fixtures, previews, UI tests.
    public static func preview(plan: TrainingPlan, user: String, logLines: [String], jobId: String = "6ac4711f404719ba3765bbc4",
                               finished: Bool = false, failed: String? = nil, startedAt: Date = Date().addingTimeInterval(-317)) -> TrainingSession {
        let s = TrainingSession(plan: plan, user: user, client: HFHubClient(token: nil), script: Data("SCRIPT_VERSION = \"1.0.2\"".utf8))
        s.progress.ingest(logLines)
        s.logTail = Array(logLines.suffix(60))
        s.startedAt = startedAt
        if let failed { s.progress.markFailed(failed); s.phase = .failed(jobId: jobId, reason: failed) }
        else if finished, let out = s.progress.output { s.phase = .finished(jobId: jobId, output: out) }
        else { s.phase = .running(jobId: jobId) }
        return s
    }

    /// Commits the bundled script when the repo has none or an older `SCRIPT_VERSION`.
    func ensureScript() async throws {
        let repo = plan.dataset
        if let existing = try? await client.fileData(repo: repo, type: .dataset, path: TrainingLaunch.scriptPath),
           TrainingLaunch.scriptVersion(in: String(decoding: existing, as: UTF8.self)) == scriptVersion {
            return
        }
        _ = try await client.commit(repo: repo, type: .dataset, summary: "loopl: training script \(scriptVersion ?? "")",
                                    files: [HFHubClient.FileOp(path: TrainingLaunch.scriptPath, data: script)])
    }
}
