//
//  WorkloadRouterError.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  WorkloadRouter.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
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
    private let metalWorker: MetalComputeWorker

    init() throws {
        metalWorker = try MetalComputeWorker()
    }

    func execute(
        workUnit: WorkUnit
    ) async throws -> MetalBenchmarkResult {
        switch workUnit.workloadID {
        case MetalComputeWorker.workloadID:
            return try await metalWorker.run(
                workUnit: workUnit
            )

        default:
            throw WorkloadRouterError
                .unsupportedWorkload(
                    workUnit.workloadID
                )
        }
    }
}
