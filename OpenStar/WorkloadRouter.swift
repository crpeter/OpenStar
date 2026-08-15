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

    init() throws {
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
}
