//
//  WorkloadCatalog.swift
//  OpenStar
//
//  Foundation-owned composition root for generic Apple worker workloads.
//


import Foundation

nonisolated
enum WorkloadCatalog {
    static func handlers() throws -> [any OpenStarWorkloadHandler] {
        var handlers: [any OpenStarWorkloadHandler] = [
            try LombScargleWorker(preparedDatasetCacheCapacity: 32),
            BoxPeriodSearchWorker()
        ]

        handlers.append(contentsOf: try CurveGridWorkloadModule.handlers())
        handlers.append(contentsOf: try SignalCorrelationWorkloadModule.handlers())
        handlers.append(contentsOf: try SeasonalChangePointWorkloadModule.handlers())
        handlers.append(contentsOf: try HarmonicGridWorkloadModule.handlers())
        return handlers
    }
}
