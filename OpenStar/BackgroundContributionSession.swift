import BackgroundTasks
import Foundation

@MainActor
protocol BackgroundContributionSessionSupporting: AnyObject {
    @discardableResult
    func register(
        launchHandler: @escaping (BackgroundContributionTask) -> Void
    ) -> Bool
    func submit() throws -> Bool
    func cancel()
}

@MainActor
protocol BackgroundContributionTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func recordAcceptedWork(unitsAccepted: Int)
    func complete(success: Bool)
}

@MainActor
final class BackgroundContributionSession:
    BackgroundContributionSessionSupporting {
    static let shared = BackgroundContributionSession()
    static let taskIdentifier = "com.openstar.OpenStar.contribution"

    private let scheduler: BGTaskScheduler
    private var registrationAttempted = false

    init(scheduler: BGTaskScheduler = .shared) {
        self.scheduler = scheduler
    }

    @discardableResult
    func register(
        launchHandler: @escaping (BackgroundContributionTask) -> Void
    ) -> Bool {
        guard !registrationAttempted else { return false }
        registrationAttempted = true

        let registered = scheduler.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                launchHandler(SystemBackgroundContributionTask(task: task))
            }
        }

        return registered
    }

    func submit() throws -> Bool {
        guard scheduler.supportedResources.contains(.gpu) else {
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Contributing to OpenStar",
            subtitle: "Processing distributed science work"
        )
        request.requiredResources = .gpu
        try scheduler.submit(request)
        return true
    }

    func cancel() {
        scheduler.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
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
