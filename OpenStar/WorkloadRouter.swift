//
//  WorkloadRouter.swift
//  OpenStar
//
//  Generic workload registry for the OpenStar worker runtime.
//  The runtime routes opaque work/dataset data to workload plugins and does
//  not contain domain-specific science logic.
//

import Foundation

nonisolated
struct WorkloadResultField: Sendable, Identifiable {
    let id: String
    let label: String
    let value: String
}

nonisolated
struct WorkloadResultSummary: Sendable {
    let title: String
    let fields: [WorkloadResultField]
}

nonisolated
struct LegacyResultFields: Sendable {
    let bestFrequency: Double?
    let bestPeriodDays: Double?
    let bestPower: Double?

    static let none = LegacyResultFields(
        bestFrequency: nil,
        bestPeriodDays: nil,
        bestPower: nil
    )
}

nonisolated
struct WorkloadExecution: Sendable {
    let duration: Double
    let payload: JSONValue
    let summary: WorkloadResultSummary?

    // Transitional bridge for the current v18 coordinator only.
    let legacyResultFields: LegacyResultFields
}

nonisolated
protocol OpenStarWorkloadHandler: Sendable {
    var workloadIDs: [String] { get }
    var capabilities: [WorkloadCapability] { get }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution
}

nonisolated
struct WorkloadBatchMember: @unchecked Sendable {
    let workUnit: WorkUnit
    let result: Result<WorkloadExecution, any Error>
}

nonisolated
protocol OpenStarBatchWorkloadHandler: OpenStarWorkloadHandler {
    var desiredBatchCount: Int { get }
    func executeBatch(
        workUnits: [WorkUnit],
        datasetData: Data?
    ) async throws -> [WorkloadBatchMember]
}

/// A claimed lease that was not executed because the worker was cancelled.
/// The server's existing environment-unavailable handling returns the lease to
/// recoverable work without charging an execution failure to either party.
nonisolated
struct WorkloadCancellation: LocalizedError, WorkFailureClassifyingError {
    var errorDescription: String? { "Work was cancelled before execution completed." }
    var workFailureKind: WorkFailureKind { .environmentUnavailable }
}

nonisolated
struct WorkloadDataUnavailable: LocalizedError, WorkFailureClassifyingError {
    let underlying: any Error
    var errorDescription: String? {
        "Dataset acquisition failed: \(underlying.localizedDescription)"
    }
    var workFailureKind: WorkFailureKind { .transportUnavailable }
}

nonisolated
enum WorkloadRouterError: LocalizedError, WorkFailureClassifyingError {
    case unsupportedWorkload(String)
    case duplicateWorkload(String)
    case invalidCapabilities(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedWorkload(let workloadID):
            return "Unsupported workload: \(workloadID)"
        case .duplicateWorkload(let workloadID):
            return "Multiple workload handlers registered for: \(workloadID)"
        case .invalidCapabilities(let message):
            return "Invalid workload capabilities: \(message)"
        }
    }

    var workFailureKind: WorkFailureKind {
        switch self {
        case .unsupportedWorkload:
            return .unsupportedWorkload
        case .duplicateWorkload,
             .invalidCapabilities:
            return .execution
        }
    }
}

nonisolated
final class WorkloadRouter: @unchecked Sendable {
    private let handlersByWorkloadID: [String: any OpenStarWorkloadHandler]

    let supportedCapabilities: [WorkloadCapability]

    var desiredBatchCount: Int {
        // The current claim API chooses the workload after seeing this value.
        // Therefore it is only safe to request a batch when every registered
        // handler can consume one. Use the most conservative handler request.
        let handlers = Array(handlersByWorkloadID.values)
        guard !handlers.isEmpty,
              handlers.allSatisfy({ $0 is any OpenStarBatchWorkloadHandler }) else {
            return 1
        }
        return handlers.compactMap {
            ($0 as? any OpenStarBatchWorkloadHandler)?.desiredBatchCount
        }.map { min(max($0, 1), 128) }.min() ?? 1
    }

    convenience init() throws {
        try self.init(handlers: [
            try LombScargleWorker()
        ])
    }

    init(handlers: [any OpenStarWorkloadHandler]) throws {
        var routed: [String: any OpenStarWorkloadHandler] = [:]
        var capabilities: [WorkloadCapability] = []

        for handler in handlers {
            let routedIDs = Set(handler.workloadIDs)
            let capabilityIDs = Set(handler.capabilities.map(\.workloadID))

            guard routedIDs == capabilityIDs else {
                throw WorkloadRouterError.invalidCapabilities(
                    "routed and advertised workload IDs differ"
                )
            }

            for workloadID in handler.workloadIDs {
                guard routed[workloadID] == nil else {
                    throw WorkloadRouterError.duplicateWorkload(workloadID)
                }
                routed[workloadID] = handler
            }

            capabilities.append(contentsOf: handler.capabilities)
        }

        handlersByWorkloadID = routed
        supportedCapabilities = capabilities
    }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        guard let handler = handlersByWorkloadID[workUnit.workloadID] else {
            throw WorkloadRouterError.unsupportedWorkload(
                workUnit.workloadID
            )
        }

        return try await handler.execute(
            workUnit: workUnit,
            datasetData: datasetData
        )
    }


    func executeBatch(
        workUnits: [WorkUnit],
        datasetData: Data?
    ) async throws -> [WorkloadBatchMember] {
        guard let first = workUnits.first else { return [] }
        guard let handler = handlersByWorkloadID[first.workloadID] else {
            throw WorkloadRouterError.unsupportedWorkload(first.workloadID)
        }
        guard let batching = handler as? any OpenStarBatchWorkloadHandler else {
            var results: [WorkloadBatchMember] = []
            for unit in workUnits {
                do {
                    let execution = try await handler.execute(
                        workUnit: unit, datasetData: datasetData
                    )
                    results.append(.init(workUnit: unit, result: .success(execution)))
                } catch {
                    results.append(.init(workUnit: unit, result: .failure(error)))
                }
            }
            return results
        }
        // A batch-capable handler must never receive another plugin's unit.
        guard workUnits.allSatisfy({ batching.workloadIDs.contains($0.workloadID) }) else {
            return await executeIndividually(workUnits: workUnits, datasetData: datasetData)
        }
        let returned = try await batching.executeBatch(
            workUnits: workUnits, datasetData: datasetData
        )
        let byID = Dictionary(returned.map { ($0.workUnit.id, $0.result) },
                              uniquingKeysWith: { first, _ in first })
        return workUnits.map { unit in
            WorkloadBatchMember(
                workUnit: unit,
                result: byID[unit.id] ?? .failure(WorkloadCancellation())
            )
        }
    }

    private func executeIndividually(
        workUnits: [WorkUnit], datasetData: Data?
    ) async -> [WorkloadBatchMember] {
        var results: [WorkloadBatchMember] = []
        for unit in workUnits {
            do {
                results.append(.init(workUnit: unit, result: .success(
                    try await execute(workUnit: unit, datasetData: datasetData)
                )))
            } catch {
                results.append(.init(workUnit: unit, result: .failure(error)))
            }
        }
        return results
    }
}
