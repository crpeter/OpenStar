//
//  WorkloadRouter.swift
//  OpenStar
//

import Foundation

nonisolated
enum WorkloadRouterError: LocalizedError {
    case unsupportedWorkload(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedWorkload(let workloadID):
            return "Unsupported workload: \(workloadID)"
        }
    }
}

nonisolated
final class WorkloadRouter: @unchecked Sendable {
    private let tessPeriodSearchWorker: TESSPeriodSearchWorker

    init() throws {
        tessPeriodSearchWorker = try TESSPeriodSearchWorker()
    }

    func execute(
        workUnit: WorkUnit,
        dataset: AstronomyDataset
    ) async throws -> PeriodSearchResult {
        switch workUnit.workloadID {
        case TESSPeriodSearchWorker.workloadID:
            return try await tessPeriodSearchWorker.run(
                workUnit: workUnit,
                dataset: dataset
            )

        default:
            throw WorkloadRouterError.unsupportedWorkload(
                workUnit.workloadID
            )
        }
    }
}
