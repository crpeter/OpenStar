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

@MainActor
@Observable
final class ContributionManager {
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

    private(set) var errorMessage: String?

    private(set) var capabilities =
        DeviceCapabilities.current()

    let nodeID: UUID

    private let coordinator: CoordinatorClient
    private let workloadRouter: WorkloadRouter?

    private var datasets: [String: Data] = [:]
    private var task: Task<Void, Never>?

    init() {
        nodeID = NodeIdentity.id
        coordinator = CoordinatorClient()

        do {
            workloadRouter = try WorkloadRouter()
        } catch {
            workloadRouter = nil
            errorMessage = error.localizedDescription
        }
    }

    var statusText: String {
        if let errorMessage {
            return errorMessage
        }

        if isContributing, projectStatus?.isComplete == true {
            return "Waiting for next project"
        }

        if isContributing {
            if availability == .temporarilyUnavailable {
                return "Paused while device environment is unavailable"
            }

            if let currentWorkloadID {
                return "Computing \(currentWorkloadID)"
            }

            return "Waiting for compatible work"
        }

        return "Ready"
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

        task = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await registerNode()
                try await refreshProjectStatus()

                while !Task.isCancelled {
                    if projectStatus?.isComplete == true {
                        try await Task.sleep(for: .seconds(1))
                        try await refreshProjectStatus()
                        continue
                    }

                    capabilities = DeviceCapabilities.current()
                    availability = WorkerEnvironment.currentAvailability()

                    // Do not claim new work when this platform cannot currently
                    // execute it. On iOS, inactive/background means Metal work
                    // must wait until the app is active again.
                    if availability != .available {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }

                    guard let workUnit = try await coordinator.claimWork(
                        nodeID: nodeID
                    ) else {
                        try await refreshProjectStatus()
                        try await Task.sleep(
                            for: .seconds(1)
                        )
                        continue
                    }

                    currentProject = workUnit.projectID
                    currentWorkloadID = workUnit.workloadID
                    currentWorkUnitID = workUnit.id

                    print(
                        "⭐️ [OpenStar] Claimed \(workUnit.id) · \(workUnit.workloadID)"
                    )

                    let result: WorkResult

                    do {
                        // Availability may change between claim and execution.
                        // Returning environment-unavailable releases this lease
                        // without penalizing the node.
                        availability = WorkerEnvironment.currentAvailability()
                        try WorkerEnvironment.requireAvailable()

                        let data: Data?

                        if let datasetID = workUnit.datasetID {
                            data = try await datasetData(
                                id: datasetID
                            )
                        } else {
                            data = nil
                        }

                        // Dataset download may race a foreground transition.
                        availability = WorkerEnvironment.currentAvailability()
                        try WorkerEnvironment.requireAvailable()

                        let execution = try await workloadRouter.execute(
                            workUnit: workUnit,
                            datasetData: data
                        )

                        try Task.checkCancellation()

                        unitsCompleted += 1
                        totalComputeSeconds += execution.duration
                        lastWorkUnitDuration = execution.duration
                        lastResultSummary = execution.summary

                        let legacy = execution.legacyResultFields

                        result = WorkResult(
                            workUnitID: workUnit.id,
                            nodeID: nodeID,
                            status: .completed,
                            duration: execution.duration,
                            payload: execution.payload,
                            errorMessage: nil,
                            failureKind: nil,
                            bestFrequency: legacy.bestFrequency,
                            bestPeriodDays: legacy.bestPeriodDays,
                            bestPower: legacy.bestPower
                        )

                    } catch is CancellationError {
                        break
                    } catch {
                        let failureKind =
                            classifyFailure(error)

                        result = WorkResult(
                            workUnitID: workUnit.id,
                            nodeID: nodeID,
                            status: .failed,
                            duration: nil,
                            payload: nil,
                            errorMessage: error.localizedDescription,
                            failureKind: failureKind,
                            bestFrequency: nil,
                            bestPeriodDays: nil,
                            bestPower: nil
                        )

                        print(
                            "⭐️ [OpenStar] Work unit failed "
                            + "[\(failureKind.rawValue)]: "
                            + error.localizedDescription
                        )
                    }

                    // A computed result must not be replaced by a failed result
                    // merely because its first submission hit a transient
                    // network error. Retry the exact same work-unit
                    // result before this worker claims anything else.
                    let receipt = try await submitWithRetry(
                        result: result
                    )

                    if receipt.accepted {
                        unitsAccepted += 1
                    }

                    print(
                        "⭐️ [OpenStar] Server response: \(receipt.message)"
                    )

                    currentWorkUnitID = nil
                    currentWorkloadID = nil
                    availability = WorkerEnvironment.currentAvailability()

                    try await refreshProjectStatus()

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
            isContributing = false
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        isContributing = false
    }

    private func classifyFailure(
        _ error: Error
    ) -> WorkFailureKind {
        if let classified =
            error as? any WorkFailureClassifyingError {
            return classified.workFailureKind
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .dataNotAllowed:
                return .transportUnavailable

            default:
                break
            }
        }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            return .transportUnavailable
        }

        return .unknown
    }

    private func submitWithRetry(
        result: WorkResult,
        maximumAttempts: Int = 3
    ) async throws -> ResultReceipt {
        precondition(maximumAttempts > 0)

        var attempt = 1

        while true {
            do {
                return try await coordinator.submit(
                    result: result
                )
            } catch {
                guard attempt < maximumAttempts,
                      isRetryableCoordinatorError(error) else {
                    throw error
                }

                let delay = 250 * (1 << (attempt - 1))

                print(
                    "⭐️ [OpenStar] Result submission attempt \(attempt) failed; retrying"
                )

                try await Task.sleep(
                    for: .milliseconds(delay)
                )
                attempt += 1
            }
        }
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

    private func datasetData(
        id: String
    ) async throws -> Data {
        if let cached = datasets[id] {
            return cached
        }

        print(
            "⭐️ [OpenStar] Downloading dataset \(id)"
        )

        let downloaded = try await coordinator.datasetData(
            id: id
        )

        datasets[id] = downloaded

        print(
            "⭐️ [OpenStar] Dataset loaded: \(downloaded.count) bytes"
        )

        return downloaded
    }

    private func refreshProjectStatus() async throws {
        let refreshed =
            try await coordinator.projectStatus()

        let newProject = refreshed.projectID.isEmpty
            ? nil
            : refreshed.projectID

        if newProject != currentProject {
            // Dataset IDs are project-scoped. Never carry opaque dataset bytes
            // into a newly activated workflow project even if an ID is reused.
            datasets.removeAll(keepingCapacity: false)
            currentWorkUnitID = nil
            currentWorkloadID = nil
            lastResultSummary = nil
        }

        projectStatus = refreshed
        currentProject = newProject
    }
}
