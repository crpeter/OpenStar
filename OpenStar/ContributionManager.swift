//
//  ContributionManager 2.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  ContributionManager.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
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
    private(set) var lastGFLOPS: Double?
    private(set) var bestGFLOPS: Double?
    private(set) var lastChecksum: Double?

    private(set) var currentProject: String?
    private(set) var currentWorkUnitID: UUID?

    private(set) var errorMessage: String?

    private(set) var capabilities =
        DeviceCapabilities.current()

    let nodeID: UUID

    private let coordinator: CoordinatorClient
    private let workloadRouter: WorkloadRouter?

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

        if isContributing {
            if currentWorkUnitID != nil {
                return "Computing"
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
            errorMessage =
                "Compute worker is unavailable."

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

                while !Task.isCancelled {
                    capabilities =
                        DeviceCapabilities.current()

                    guard let workUnit =
                        try await coordinator.claimWork(
                            nodeID: nodeID
                        )
                    else {
                        try await Task.sleep(
                            for: .seconds(2)
                        )

                        continue
                    }

                    currentProject =
                        workUnit.projectID

                    currentWorkUnitID =
                        workUnit.id

                    print(
                        "⭐️ [OpenStar] Claimed \(workUnit.id)"
                    )

                    do {
                        let result =
                            try await workloadRouter.execute(
                                workUnit: workUnit
                            )

                        try Task.checkCancellation()

                        unitsCompleted += 1

                        totalComputeSeconds +=
                            result.duration

                        lastWorkUnitDuration =
                            result.duration

                        lastGFLOPS =
                            result.estimatedGFLOPS

                        lastChecksum =
                            result.checksum

                        if let currentBest =
                            bestGFLOPS {
                            bestGFLOPS = max(
                                currentBest,
                                result.estimatedGFLOPS
                            )
                        } else {
                            bestGFLOPS =
                                result.estimatedGFLOPS
                        }

                        let networkResult =
                            WorkResult(
                                workUnitID:
                                    workUnit.id,
                                nodeID:
                                    nodeID,
                                status:
                                    .completed,
                                duration:
                                    result.duration,
                                estimatedGFLOPS:
                                    result
                                        .estimatedGFLOPS,
                                checksum:
                                    result.checksum,
                                verificationValue:
                                    result
                                        .verificationValue,
                                errorMessage:
                                    nil
                            )

                        let receipt =
                            try await coordinator.submit(
                                result: networkResult
                            )

                        if receipt.accepted {
                            unitsAccepted += 1
                        }

                        print(
                            """
                            ⭐️ [OpenStar] Server response: \
                            \(receipt.message)
                            """
                        )

                    } catch is CancellationError {
                        break

                    } catch {
                        let failedResult =
                            WorkResult(
                                workUnitID:
                                    workUnit.id,
                                nodeID:
                                    nodeID,
                                status:
                                    .failed,
                                duration:
                                    nil,
                                estimatedGFLOPS:
                                    nil,
                                checksum:
                                    nil,
                                verificationValue:
                                    nil,
                                errorMessage:
                                    error
                                        .localizedDescription
                            )

                        _ = try? await coordinator.submit(
                            result: failedResult
                        )

                        print(
                            """
                            ⭐️ [OpenStar] Work unit failed: \
                            \(error)
                            """
                        )
                    }

                    currentWorkUnitID = nil

                    await Task.yield()
                }

            } catch is CancellationError {
                // Expected when Stop is pressed.

            } catch {
                errorMessage =
                    error.localizedDescription

                print(
                    """
                    ⭐️ [OpenStar] Contribution error: \
                    \(error)
                    """
                )
            }

            currentWorkUnitID = nil
            currentProject = nil
            isContributing = false
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        isContributing = false
    }

    private func registerNode() async throws {
        capabilities =
            DeviceCapabilities.current()

        let response =
            try await coordinator.register(
                nodeID: nodeID,
                capabilities:
                    capabilities.networkCapabilities
            )

        guard response.accepted else {
            throw CoordinatorClientError
                .serverError(
                    statusCode: 400,
                    message: response.message
                )
        }

        isRegistered = true

        print(
            """
            ⭐️ [OpenStar] Node registered: \
            \(nodeID)
            """
        )
    }
}