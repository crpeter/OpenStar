import Foundation

#if os(iOS)
import BackgroundTasks
#endif

func backgroundContributionLog(_ message: String) {
    print("⭐️ [OpenStar BG] \(message)")
}

enum BackgroundContributionIdentifiers {
    static let base = "com.openstar.OpenStar.contribution"
    static let permitted = "\(base).*"

    static func session(_ id: UUID) -> String {
        "\(base).\(id.uuidString)"
    }
}

@MainActor
protocol BackgroundContributionSessionSupporting: AnyObject {
    @discardableResult
    func register(
        launchHandler: @escaping (BackgroundContributionTask) -> Void
    ) -> Bool
    func submit() throws -> String?
    func cancel()
}

@MainActor
protocol BackgroundContributionTask: AnyObject {
    var identifier: String { get }
    var expirationHandler: (() -> Void)? { get set }
    func recordAcceptedWork(unitsAccepted: Int)
    func complete(success: Bool)
}

#if os(iOS)
@MainActor
final class BackgroundContributionSession:
    BackgroundContributionSessionSupporting {
    static let shared = BackgroundContributionSession()

    private let scheduler: BGTaskScheduler
    private var registrationAttempted = false
    private var launchHandler: ((BackgroundContributionTask) -> Void)?
    private var submittedIdentifier: String?

    init(scheduler: BGTaskScheduler = .shared) {
        self.scheduler = scheduler
    }

    @discardableResult
    func register(
        launchHandler: @escaping (BackgroundContributionTask) -> Void
    ) -> Bool {
        guard !registrationAttempted else {
            backgroundContributionLog("Duplicate registration attempt ignored")
            return false
        }
        registrationAttempted = true
        self.launchHandler = launchHandler
        backgroundContributionLog("Launch handler configured")
        return true
    }

    func submit() throws -> String? {
        let supportsGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        backgroundContributionLog(
            "supportedResources contains .gpu: \(supportsGPU)"
        )
        guard supportsGPU, let launchHandler else {
            return nil
        }

        let identifier = BackgroundContributionIdentifiers.session(UUID())
        backgroundContributionLog("Generated task identifier: \(identifier)")
        let registered = scheduler.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            backgroundContributionLog(
                "Concrete task delivered by iOS for: \(identifier)"
            )
            backgroundContributionLog(
                "Actual delivered task identifier: \(task.identifier)"
            )
            guard let task = task as? BGContinuedProcessingTask else {
                backgroundContributionLog(
                    "Unexpected task type for \(task.identifier): "
                    + String(reflecting: type(of: task))
                )
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                launchHandler(SystemBackgroundContributionTask(task: task))
            }
        }
        backgroundContributionLog(
            "scheduler.register result for \(identifier): \(registered)"
        )

        guard registered else {
            return nil
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Contributing to OpenStar",
            subtitle: "Processing distributed science work"
        )
        request.requiredResources = .gpu
        backgroundContributionLog(
            "request.requiredResources = .gpu for \(identifier)"
        )
        do {
            try scheduler.submit(request)
            backgroundContributionLog(
                "scheduler.submit succeeded for \(identifier)"
            )
        } catch {
            let nsError = error as NSError
            backgroundContributionLog(
                "scheduler.submit error for \(identifier): type="
                + String(reflecting: type(of: error))
                + " code=\(nsError.domain)/\(nsError.code)"
                + " message=\(nsError.localizedDescription)"
            )
            throw error
        }
        submittedIdentifier = identifier
        return identifier
    }

    func cancel() {
        guard let submittedIdentifier else { return }
        backgroundContributionLog(
            "Scheduler request cancellation with identifier: "
            + submittedIdentifier
        )
        scheduler.cancel(taskRequestWithIdentifier: submittedIdentifier)
        self.submittedIdentifier = nil
    }
}

@MainActor
private final class SystemBackgroundContributionTask:
    BackgroundContributionTask {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = -1
    }

    var identifier: String { task.identifier }

    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }

    func recordAcceptedWork(unitsAccepted: Int) {
        task.progress.completedUnitCount = Int64(unitsAccepted)
    }

    func complete(success: Bool) {
        expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
#else
@MainActor
final class BackgroundContributionSession:
    BackgroundContributionSessionSupporting {
    static let shared = BackgroundContributionSession()

    @discardableResult
    func register(
        launchHandler: @escaping (BackgroundContributionTask) -> Void
    ) -> Bool {
        false
    }

    func submit() throws -> String? { nil }
    func cancel() {}
}
#endif
