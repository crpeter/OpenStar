//
//  ContributionManager.swift
//  OpenStar
//
//  Generic worker-node runtime. It registers capabilities, claims compatible
//  work, fetches opaque datasets, routes work to the matching workload plugin,
//  and returns generic result payloads.
//

import Foundation
import Observation

nonisolated
func classifyWorkFailure(_ error: Error) -> WorkFailureKind {
    if error is CancellationError { return .environmentUnavailable }
    if let classified = error as? any WorkFailureClassifyingError {
        return classified.workFailureKind
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
             .internationalRoamingOff, .dataNotAllowed:
            return .transportUnavailable
        default: break
        }
    }
    if (error as NSError).domain == NSURLErrorDomain { return .transportUnavailable }
    return .unknown
}

@MainActor
@Observable
final class ContributionManager {
    private struct DatasetCacheKey: Hashable {
        let projectID: String
        let datasetID: String
    }

    private(set) var isContributing = false
    private(set) var isRegistered = false
    private(set) var availability: WorkerAvailability = .available

    private(set) var unitsCompleted = 0
    private(set) var unitsAccepted = 0
    private(set) var totalComputeSeconds: Double = 0

    private(set) var lastWorkUnitDuration: Double?
    private(set) var lastResultSummary: WorkloadResultSummary?

    private(set) var currentProject: String?
    private(set) var currentWorkloadID: String?
    private(set) var currentWorkUnitID: UUID?
    private(set) var projectStatus: ProjectStatus?
    private(set) var isSubmitting = false

    private(set) var errorMessage: String?

    private(set) var capabilities =
        DeviceCapabilities.current()

    let nodeID: UUID

    private let coordinator: CoordinatorClient
    private let workloadRouter: WorkloadRouter?
    private let projectStatusRefreshInterval: Duration
    private let initialEmptyClaimBackoff: Duration
    private let maximumEmptyClaimBackoff: Duration
    private let emptyClaimSleep: @Sendable (Duration) async throws -> Void
    private let backgroundSession: BackgroundContributionSessionSupporting

    private var datasets: [DatasetCacheKey: Data] = [:]
    private var datasetRecency: [DatasetCacheKey] = []
    private let datasetCacheCapacity = 4
    private var task: Task<Void, Never>?
    private var projectStatusTask: Task<Void, Never>?
    private var backgroundTask: BackgroundContributionTask?
    private var backgroundRequestIdentifier: String?
    private var backgroundSessionInitialAcceptedCount = 0

    init() {
        nodeID = NodeIdentity.id
        coordinator = CoordinatorClient()
        projectStatusRefreshInterval = .seconds(5)
        initialEmptyClaimBackoff = .milliseconds(25)
        maximumEmptyClaimBackoff = .milliseconds(500)
        emptyClaimSleep = { try await Task.sleep(for: $0) }
        backgroundSession = BackgroundContributionSession.shared

        do {
            workloadRouter = try WorkloadRouter()
        } catch {
            workloadRouter = nil
            errorMessage = error.localizedDescription
        }
    }

    init(
        nodeID: UUID = UUID(),
        coordinator: CoordinatorClient,
        workloadRouter: WorkloadRouter,
        projectStatusRefreshInterval: Duration = .seconds(5),
        initialEmptyClaimBackoff: Duration = .milliseconds(25),
        maximumEmptyClaimBackoff: Duration = .milliseconds(500),
        emptyClaimSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        backgroundSession: BackgroundContributionSessionSupporting =
            BackgroundContributionSession.shared
    ) {
        self.nodeID = nodeID
        self.coordinator = coordinator
        self.workloadRouter = workloadRouter
        self.projectStatusRefreshInterval = projectStatusRefreshInterval
        self.initialEmptyClaimBackoff = initialEmptyClaimBackoff
        self.maximumEmptyClaimBackoff = maximumEmptyClaimBackoff
        self.emptyClaimSleep = emptyClaimSleep
        self.backgroundSession = backgroundSession
    }

    var statusText: String {
        if errorMessage != nil {
            return "Error"
        }

        if isContributing {
            if availability == .temporarilyUnavailable {
                return "Waiting"
            }

            if isSubmitting {
                return "Submitting"
            }

            if currentWorkloadID != nil {
                return "Working"
            }

            return "Waiting"
        }

        return "Idle"
    }

    var supportedWorkloads: [WorkloadCapability] {
        workloadRouter?.supportedCapabilities ?? []
    }

    func start() {
        guard task == nil else {
            return
        }

        guard let workloadRouter else {
            errorMessage = "Compute worker is unavailable."
            return
        }

        errorMessage = nil
        isContributing = true
        backgroundSessionInitialAcceptedCount = unitsAccepted
        backgroundRequestIdentifier = nil

        do {
            backgroundRequestIdentifier = try backgroundSession.submit()
        } catch {
            // A continued-processing request is an optional extension of the
            // foreground session. Submission failure must not prevent work.
            print(
                "⭐️ [OpenStar] Background contribution unavailable: \(error)"
            )
        }

        task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await registerNode()
                startProjectStatusRefresh()

                var emptyClaimBackoff = initialEmptyClaimBackoff

                while !Task.isCancelled {
                    capabilities = DeviceCapabilities.current()
                    availability = WorkerEnvironment.currentAvailability()

                    // Do not claim new work when this platform cannot currently
                    // execute it. On iOS, inactive/background means Metal work
                    // must wait until the app is active again.
                    if availability != .available {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }

                    let claimed = try await coordinator.claimWork(
                        nodeID: nodeID,
                        maxWorkUnits: workloadRouter.desiredBatchCount
                    )
                    guard let first = claimed.first else {
                        try await emptyClaimSleep(emptyClaimBackoff)
                        emptyClaimBackoff = min(
                            emptyClaimBackoff * 2, maximumEmptyClaimBackoff
                        )
                        continue
                    }
                    emptyClaimBackoff = initialEmptyClaimBackoff
                    currentProject = first.projectID
                    currentWorkloadID = first.workloadID
                    currentWorkUnitID = first.id

                    availability = WorkerEnvironment.currentAvailability()
                    let members: [WorkloadBatchMember]
                    do {
                        let data: Data?
                        if let datasetID = first.datasetID {
                            do {
                                data = try await datasetData(
                                    projectID: first.projectID, datasetID: datasetID
                                )
                            } catch is CancellationError {
                                throw WorkloadCancellation()
                            } catch {
                                throw WorkloadDataUnavailable(underlying: error)
                            }
                        } else { data = nil }
                        try WorkerEnvironment.requireAvailable()
                        members = try await workloadRouter.executeBatch(
                            workUnits: claimed, datasetData: data
                        )
                    } catch is CancellationError {
                        // Cancellation releases every claimed lease without
                        // reporting a node/workload execution failure.
                        members = claimed.map {
                            .init(workUnit: $0, result: .failure(WorkloadCancellation()))
                        }
                    } catch is WorkloadCancellation {
                        members = claimed.map {
                            .init(workUnit: $0, result: .failure(WorkloadCancellation()))
                        }
                    } catch {
                        members = claimed.map {
                            .init(workUnit: $0, result: .failure(error))
                        }
                    }

                    var firstSubmissionError: (any Error)?
                    for member in members {
                        currentWorkUnitID = member.workUnit.id
                        let result: WorkResult
                        switch member.result {
                        case .success(let execution):
                            unitsCompleted += 1
                            totalComputeSeconds += execution.duration
                            lastWorkUnitDuration = execution.duration
                            lastResultSummary = execution.summary
                            let legacy = execution.legacyResultFields
                            result = WorkResult(
                                workUnitID: member.workUnit.id, nodeID: nodeID,
                                status: .completed, duration: execution.duration,
                                payload: execution.payload, errorMessage: nil,
                                failureKind: nil,
                                bestFrequency: legacy.bestFrequency,
                                bestPeriodDays: legacy.bestPeriodDays,
                                bestPower: legacy.bestPower
                            )
                        case .failure(let error):
                            result = WorkResult(
                                workUnitID: member.workUnit.id, nodeID: nodeID,
                                status: .failed, duration: nil, payload: nil,
                                errorMessage: error.localizedDescription,
                                failureKind: classifyFailure(error),
                                bestFrequency: nil, bestPeriodDays: nil,
                                bestPower: nil
                            )
                        }
                        isSubmitting = true
                        do {
                            let receipt = try await submitWithRetry(result: result)
                            if receipt.accepted {
                                unitsAccepted += 1
                                backgroundTask?.recordAcceptedWork(
                                    unitsAccepted: unitsAccepted - backgroundSessionInitialAcceptedCount
                                )
                            }
                        } catch {
                            if firstSubmissionError == nil { firstSubmissionError = error }
                        }
                        isSubmitting = false
                    }
                    if let firstSubmissionError { throw firstSubmissionError }
                    currentWorkUnitID = nil
                    currentWorkloadID = nil
                    availability = WorkerEnvironment.currentAvailability()
                    await Task.yield()
                }
            } catch is CancellationError {
                // Expected when Stop is pressed.
            } catch {
                errorMessage = error.localizedDescription

                print(
                    "⭐️ [OpenStar] Contribution error: \(error)"
                )
            }

            currentWorkUnitID = nil
            currentWorkloadID = nil
            isSubmitting = false
            isContributing = false
            projectStatusTask?.cancel()
            projectStatusTask = nil
            task = nil
            finishBackgroundTask(success: errorMessage == nil)
        }
    }

    func stop() {
        stop(userInitiated: true)
    }

    private func stop(userInitiated: Bool) {
        if userInitiated {
            backgroundContributionLog(
                "User stop caused cancellation for: "
                + (backgroundRequestIdentifier ?? "no submitted identifier")
            )
        }
        task?.cancel()
        projectStatusTask?.cancel()
        isContributing = false
        backgroundSession.cancel()
        finishBackgroundTask(success: false)
    }

    func attachBackgroundTask(_ task: BackgroundContributionTask) {
        let expectedIdentifier = backgroundRequestIdentifier
        let matchesExpected = task.identifier == expectedIdentifier
        backgroundContributionLog(
            "Task received: \(task.identifier); matches expected request "
            + "identifier: \(matchesExpected); contribution active: "
            + "\(isContributing)"
        )
        guard isContributing, matchesExpected else {
            backgroundContributionLog(
                "Task rejected: \(task.identifier)"
            )
            completeBackgroundTask(task, success: false)
            return
        }

        if let backgroundTask {
            completeBackgroundTask(backgroundTask, success: false)
        }
        backgroundTask = task
        backgroundContributionLog("Task accepted/attached: \(task.identifier)")
        task.recordAcceptedWork(
            unitsAccepted: unitsAccepted - backgroundSessionInitialAcceptedCount
        )
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task,
                      self.backgroundTask === task else { return }
                backgroundContributionLog(
                    "expirationHandler fired for \(task.identifier)"
                )
                self.stop(userInitiated: false)
            }
        }
    }

    private func finishBackgroundTask(success: Bool) {
        if let backgroundTask {
            completeBackgroundTask(backgroundTask, success: success)
        }
        backgroundTask = nil
        backgroundRequestIdentifier = nil
    }

    private func completeBackgroundTask(
        _ task: BackgroundContributionTask,
        success: Bool
    ) {
        backgroundContributionLog(
            "Background task completed: \(task.identifier); success: \(success)"
        )
        task.complete(success: success)
    }

    private func startProjectStatusRefresh() {
        projectStatusTask?.cancel()
        projectStatusTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await refreshProjectStatus()
                try? await Task.sleep(for: projectStatusRefreshInterval)
            }
        }
    }

    private func classifyFailure(
        _ error: Error
    ) -> WorkFailureKind {
        classifyWorkFailure(error)
    }

    private func submitWithRetry(
        result: WorkResult,
        maximumAttempts: Int = 3
    ) async throws -> ResultReceipt {
        precondition(maximumAttempts > 0)
        let coordinator = coordinator
        // Submission is intentionally unstructured: cancellation stops heavy
        // compute, but must not prevent completed/no-penalty child outcomes
        // from releasing every lease already claimed by this worker.
        return try await Task.detached {
            var attempt = 1
            while true {
                do {
                    return try await coordinator.submit(result: result)
                } catch {
                    let retryable: Bool
                    if classifyWorkFailure(error) == .transportUnavailable {
                        retryable = true
                    } else if let coordinatorError = error as? CoordinatorClientError,
                              case .serverError(let statusCode, _) = coordinatorError {
                        retryable = statusCode == 408 || statusCode == 429
                            || (500..<600).contains(statusCode)
                    } else {
                        retryable = false
                    }
                    guard attempt < maximumAttempts, retryable else { throw error }
                    let delay = 250 * (1 << (attempt - 1))
                    print("⭐️ [OpenStar] Result submission attempt \(attempt) failed; retrying")
                    try await Task.sleep(for: .milliseconds(delay))
                    attempt += 1
                }
            }
        }.value
    }

    private func isRetryableCoordinatorError(
        _ error: Error
    ) -> Bool {
        if classifyFailure(error) == .transportUnavailable {
            return true
        }

        guard let coordinatorError = error as? CoordinatorClientError,
              case .serverError(let statusCode, _) = coordinatorError else {
            return false
        }

        return statusCode == 408 ||
            statusCode == 429 ||
            (500..<600).contains(statusCode)
    }

    private func registerNode() async throws {
        capabilities = DeviceCapabilities.current()

        let response = try await coordinator.register(
            nodeID: nodeID,
            capabilities: capabilities.networkCapabilities(
                supportedWorkloads: supportedWorkloads
            )
        )

        guard response.accepted else {
            throw CoordinatorClientError.serverError(
                statusCode: 400,
                message: response.message
            )
        }

        isRegistered = true

        print(
            "⭐️ [OpenStar] Node registered: \(nodeID)"
        )

        for capability in supportedWorkloads {
            print(
                "⭐️ [OpenStar] Capability: \(capability.workloadID)"
            )
        }
    }

    func datasetData(
        projectID: String,
        datasetID: String
    ) async throws -> Data {
        let key = DatasetCacheKey(
            projectID: projectID,
            datasetID: datasetID
        )

        if let cached = datasets[key] {
            datasetRecency.removeAll { $0 == key }
            datasetRecency.append(key)
            return cached
        }

        print(
            "⭐️ [OpenStar] Downloading dataset \(projectID)/\(datasetID)"
        )

        let downloaded = try await coordinator.datasetData(
            projectID: projectID,
            datasetID: datasetID
        )

        if datasets.count == datasetCacheCapacity,
           let oldest = datasetRecency.first {
            datasets.removeValue(forKey: oldest)
            datasetRecency.removeFirst()
        }
        datasets[key] = downloaded
        datasetRecency.append(key)

        print(
            "⭐️ [OpenStar] Dataset loaded: \(downloaded.count) bytes"
        )

        return downloaded
    }

    private func refreshProjectStatus() async {
        do {
            let refreshed = try await coordinator.projectStatus(
                projectID: currentProject
            )

            projectStatus = refreshed
        } catch {
            // Project status is display-only. A removed project or temporary
            // status-service failure must not stop this generic worker from
            // claiming work from the shared compute pool.
            print(
                "⭐️ [OpenStar] Project status unavailable: "
                + error.localizedDescription
            )
        }
    }
}
