//
//  ContributionManager.swift
//  OpenStar
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
    private(set) var bestCandidateFrequency: Double?
    private(set) var bestCandidatePeriodDays: Double?
    private(set) var bestCandidatePower: Double?

    private(set) var currentProject: String?
    private(set) var currentWorkUnitID: UUID?
    private(set) var projectStatus: ProjectStatus?

    private(set) var errorMessage: String?

    private(set) var capabilities =
        DeviceCapabilities.current()

    let nodeID: UUID

    private let coordinator: CoordinatorClient
    private let workloadRouter: WorkloadRouter?

    private var datasets: [String: AstronomyDataset] = [:]
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
            return "Science project complete"
        }

        if isContributing {
            if currentWorkUnitID != nil {
                return "Searching TESS data"
            }

            return "Waiting for work"
        }

        return "Ready"
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
                    currentWorkUnitID = workUnit.id

                    print(
                        "⭐️ [OpenStar] Claimed \(workUnit.id)"
                    )

                    do {
                        let dataset = try await dataset(
                            id: workUnit.datasetID
                        )

                        let result = try await workloadRouter.execute(
                            workUnit: workUnit,
                            dataset: dataset
                        )

                        try Task.checkCancellation()

                        unitsCompleted += 1
                        totalComputeSeconds += result.duration
                        lastWorkUnitDuration = result.duration

                        if bestCandidatePower == nil ||
                            result.bestPower > bestCandidatePower! {
                            bestCandidatePower = result.bestPower
                            bestCandidateFrequency = result.bestFrequency
                            bestCandidatePeriodDays = result.bestPeriodDays
                        }

                        let networkResult = WorkResult(
                            workUnitID: workUnit.id,
                            nodeID: nodeID,
                            status: .completed,
                            duration: result.duration,
                            bestFrequency: result.bestFrequency,
                            bestPeriodDays: result.bestPeriodDays,
                            bestPower: result.bestPower,
                            errorMessage: nil
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
                            bestFrequency: nil,
                            bestPeriodDays: nil,
                            bestPower: nil,
                            errorMessage: error.localizedDescription
                        )

                        _ = try? await coordinator.submit(
                            result: failedResult
                        )

                        print(
                            "⭐️ [OpenStar] Work unit failed: \(error)"
                        )
                    }

                    currentWorkUnitID = nil

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
            capabilities: capabilities.networkCapabilities
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
    }

    private func dataset(
        id: String
    ) async throws -> AstronomyDataset {
        if let cached = datasets[id] {
            return cached
        }

        print(
            "🔭 [OpenStar] Downloading dataset \(id)"
        )

        let downloaded = try await coordinator.dataset(
            id: id
        )

        datasets[id] = downloaded

        print(
            "🔭 [OpenStar] Dataset loaded: \(downloaded.times.count) samples"
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
