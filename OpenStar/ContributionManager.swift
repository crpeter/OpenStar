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

        if projectStatus?.isComplete == true {
            return "Project complete"
        }

        if isContributing {
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
                        break
                    }

                    capabilities = DeviceCapabilities.current()

                    guard let workUnit = try await coordinator.claimWork(
                        nodeID: nodeID
                    ) else {
                        try await refreshProjectStatus()

                        if projectStatus?.isComplete == true {
                            break
                        }

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

                    do {
                        let data: Data?

                        if let datasetID = workUnit.datasetID {
                            data = try await datasetData(
                                id: datasetID
                            )
                        } else {
                            data = nil
                        }

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

                        let networkResult = WorkResult(
                            workUnitID: workUnit.id,
                            nodeID: nodeID,
                            status: .completed,
                            duration: execution.duration,
                            payload: execution.payload,
                            errorMessage: nil,
                            bestFrequency: legacy.bestFrequency,
                            bestPeriodDays: legacy.bestPeriodDays,
                            bestPower: legacy.bestPower
                        )

                        let receipt = try await coordinator.submit(
                            result: networkResult
                        )

                        if receipt.accepted {
                            unitsAccepted += 1
                        }

                        print(
                            "⭐️ [OpenStar] Server response: \(receipt.message)"
                        )
                    } catch is CancellationError {
                        break
                    } catch {
                        let failedResult = WorkResult(
                            workUnitID: workUnit.id,
                            nodeID: nodeID,
                            status: .failed,
                            duration: nil,
                            payload: nil,
                            errorMessage: error.localizedDescription,
                            bestFrequency: nil,
                            bestPeriodDays: nil,
                            bestPower: nil
                        )

                        _ = try? await coordinator.submit(
                            result: failedResult
                        )

                        print(
                            "⭐️ [OpenStar] Work unit failed: \(error)"
                        )
                    }

                    currentWorkUnitID = nil
                    currentWorkloadID = nil

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
        projectStatus =
            try await coordinator.projectStatus()

        if let projectStatus {
            currentProject =
                projectStatus.projectID
        }
    }
}
