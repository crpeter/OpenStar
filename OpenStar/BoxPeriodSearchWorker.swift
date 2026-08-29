//
//  BoxPeriodSearchWorker.swift
//  OpenStar
//
//  Generic CPU periodic-box scoring. This workload contains no domain-specific
//  interpretation; it returns only the best numerical window on an assigned grid.
//

import Foundation

nonisolated
enum BoxPeriodSearchError: LocalizedError, WorkFailureClassifyingError {
    case missingDataset
    case invalidDataset
    case invalidPayload(String)
    case noValidWindow

    var errorDescription: String? {
        switch self {
        case .missingDataset: "Periodic-box work requires a dataset."
        case .invalidDataset: "Dataset arrays must be matching, finite, and nonempty."
        case .invalidPayload(let message): "Invalid periodic-box payload: \(message)"
        case .noValidWindow: "No periodic-box window satisfied the sample-count gates."
        }
    }

    var workFailureKind: WorkFailureKind { .invalidInput }
}

nonisolated
struct BoxPeriodSearchPayload: Sendable {
    let startFrequency: Float
    let frequencyStep: Float
    let frequencyCount: Int
    let frequencyStartIndex: Int
    let phaseBinCount: Int
    let durationFractions: [Float]
    let minimumInBoxSamples: Int
    let minimumOutOfBoxSamples: Int

    init(_ value: JSONValue?) throws {
        guard let object = value?.objectValue else {
            throw BoxPeriodSearchError.invalidPayload("missing object")
        }
        func number(_ key: String) throws -> Double {
            guard let result = object[key]?.doubleValue, result.isFinite else {
                throw BoxPeriodSearchError.invalidPayload("missing finite \(key)")
            }
            return result
        }
        func integer(_ key: String, default defaultValue: Int? = nil) throws -> Int {
            if let result = object[key]?.intValue { return result }
            if let defaultValue, object[key] == nil { return defaultValue }
            throw BoxPeriodSearchError.invalidPayload("missing integer \(key)")
        }
        guard case .array(let durationValues)? = object["durationFractions"] else {
            throw BoxPeriodSearchError.invalidPayload("missing durationFractions")
        }
        startFrequency = Float(try number("startFrequency"))
        frequencyStep = Float(try number("frequencyStep"))
        frequencyCount = try integer("frequencyCount")
        frequencyStartIndex = try integer("frequencyStartIndex", default: 0)
        phaseBinCount = try integer("phaseBinCount")
        durationFractions = try durationValues.map { value in
            guard let result = value.doubleValue, result.isFinite else {
                throw BoxPeriodSearchError.invalidPayload("non-numeric duration fraction")
            }
            return Float(result)
        }
        minimumInBoxSamples = try integer("minimumInBoxSamples")
        minimumOutOfBoxSamples = try integer("minimumOutOfBoxSamples")
        guard startFrequency.isFinite, startFrequency > 0,
              frequencyStep.isFinite, frequencyStep > 0,
              frequencyCount > 0, phaseBinCount >= 2,
              !durationFractions.isEmpty,
              durationFractions.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
              minimumInBoxSamples > 0, minimumOutOfBoxSamples > 0 else {
            throw BoxPeriodSearchError.invalidPayload("contract bounds are not satisfied")
        }
        let last = startFrequency + Float(frequencyCount - 1) * frequencyStep
        guard last.isFinite, last > 0 else {
            throw BoxPeriodSearchError.invalidPayload("frequency grid overflows")
        }
    }
}

nonisolated
struct BoxPeriodSearchDataset: Decodable, Sendable {
    let coordinates: [Float]?
    let values: [Float]?
    let times: [Float]?
    let flux: [Float]?

    var series: ([Float], [Float])? {
        if let coordinates, let values { return (coordinates, values) }
        if let times, let flux { return (times, flux) }
        return nil
    }
}

nonisolated
struct BoxPeriodSearchResult: Sendable, Equatable {
    let bestFrequency: Float
    let bestScore: Float
    let bestPhase: Float
    let bestDurationFraction: Float
    let bestFrequencyIndex: Int
    let bestDurationIndex: Int
    let bestPhaseBin: Int
    let inBoxSamples: Int
    let outOfBoxSamples: Int
}

nonisolated
final class BoxPeriodSearchWorker: OpenStarBatchWorkloadHandler, @unchecked Sendable {
    static let workloadID = "openstar.box-period-search.v1"
    let workloadIDs = [BoxPeriodSearchWorker.workloadID]
    let capabilities = [WorkloadCapability(
        workloadID: BoxPeriodSearchWorker.workloadID,
        executionBackends: [.cpu], validatorID: nil
    )]
    let desiredBatchCount = 8

    func execute(workUnit: WorkUnit, datasetData: Data?) async throws -> WorkloadExecution {
        guard let datasetData else { throw BoxPeriodSearchError.missingDataset }
        let dataset = try JSONDecoder().decode(BoxPeriodSearchDataset.self, from: datasetData)
        return try executePrepared(workUnit: workUnit, dataset: dataset)
    }

    func executeBatch(
        workUnits: [WorkUnit], datasetData: Data?
    ) async throws -> [WorkloadBatchMember] {
        guard let datasetData else { throw BoxPeriodSearchError.missingDataset }
        let dataset = try JSONDecoder().decode(BoxPeriodSearchDataset.self, from: datasetData)
        return workUnits.map { workUnit in
            do {
                return WorkloadBatchMember(
                    workUnit: workUnit,
                    result: .success(try executePrepared(workUnit: workUnit, dataset: dataset))
                )
            } catch {
                return WorkloadBatchMember(workUnit: workUnit, result: .failure(error))
            }
        }
    }

    private func executePrepared(
        workUnit: WorkUnit, dataset: BoxPeriodSearchDataset
    ) throws -> WorkloadExecution {
        let started = Date()
        let payload = try BoxPeriodSearchPayload(workUnit.payload)
        let result = try Self.score(dataset: dataset, payload: payload)
        let duration = Date().timeIntervalSince(started)
        return WorkloadExecution(
            duration: duration,
            payload: .object([
                "bestFrequency": .number(Double(result.bestFrequency)),
                "bestScore": .number(Double(result.bestScore)),
                "bestPhase": .number(Double(result.bestPhase)),
                "bestDurationFraction": .number(Double(result.bestDurationFraction)),
                "bestFrequencyIndex": .number(Double(result.bestFrequencyIndex)),
                "bestDurationIndex": .number(Double(result.bestDurationIndex)),
                "bestPhaseBin": .number(Double(result.bestPhaseBin)),
                "inBoxSamples": .number(Double(result.inBoxSamples)),
                "outOfBoxSamples": .number(Double(result.outOfBoxSamples)),
                "cpuDurationSeconds": .number(duration),
                "totalWorkloadDurationSeconds": .number(duration),
            ]),
            summary: WorkloadResultSummary(title: "Periodic Box Result", fields: [
                .init(id: "frequency", label: "Frequency", value: String(format: "%.6f", result.bestFrequency)),
                .init(id: "score", label: "Box Score", value: String(format: "%.6f", result.bestScore)),
            ]),
            legacyResultFields: .none
        )
    }

    static func score(
        dataset: BoxPeriodSearchDataset, payload: BoxPeriodSearchPayload
    ) throws -> BoxPeriodSearchResult {
        guard let (coordinates, values) = dataset.series,
              !coordinates.isEmpty, coordinates.count == values.count,
              coordinates.allSatisfy(\.isFinite), values.allSatisfy(\.isFinite) else {
            throw BoxPeriodSearchError.invalidDataset
        }
        guard payload.minimumInBoxSamples + payload.minimumOutOfBoxSamples <= coordinates.count else {
            throw BoxPeriodSearchError.invalidPayload("sample-count gates exceed dataset size")
        }
        struct Candidate {
            let score: Float
            let frequencyIndex: Int
            let durationIndex: Int
            let phaseBin: Int
            let durationBins: Int
            let inCount: Int
            let outCount: Int
        }
        func better(_ candidate: Candidate, than current: Candidate?) -> Bool {
            guard let current else { return true }
            if candidate.score != current.score { return candidate.score > current.score }
            if candidate.frequencyIndex != current.frequencyIndex {
                return candidate.frequencyIndex < current.frequencyIndex
            }
            if candidate.durationIndex != current.durationIndex {
                return candidate.durationIndex < current.durationIndex
            }
            return candidate.phaseBin < current.phaseBin
        }
        var best: Candidate?
        for frequencyIndex in 0..<payload.frequencyCount {
            if Task.isCancelled {
                throw WorkloadCancellation()
            }
            let frequency = payload.startFrequency + Float(frequencyIndex) * payload.frequencyStep
            var sums = [Float](repeating: 0, count: payload.phaseBinCount)
            var counts = [Int](repeating: 0, count: payload.phaseBinCount)
            var totalSum: Float = 0
            for index in coordinates.indices {
                let cycles = coordinates[index] * frequency
                let phase = cycles - cycles.rounded(.down)
                let bin = min(Int(phase * Float(payload.phaseBinCount)), payload.phaseBinCount - 1)
                sums[bin] += values[index]
                counts[bin] += 1
                totalSum += values[index]
            }
            for (durationIndex, duration) in payload.durationFractions.enumerated() {
                let durationBins = min(
                    payload.phaseBinCount - 1,
                    max(1, Int((duration * Float(payload.phaseBinCount) + 0.5).rounded(.down)))
                )
                var insideSum = sums[..<durationBins].reduce(0, +)
                var insideCount = counts[..<durationBins].reduce(0, +)
                for phaseBin in 0..<payload.phaseBinCount {
                    let outsideCount = coordinates.count - insideCount
                    if insideCount >= payload.minimumInBoxSamples,
                       outsideCount >= payload.minimumOutOfBoxSamples {
                        let outsideSum = totalSum - insideSum
                        let contrast = outsideSum / Float(outsideCount) - insideSum / Float(insideCount)
                        let weight = (
                            Float(insideCount * outsideCount) / Float(coordinates.count)
                        ).squareRoot()
                        let score = contrast * weight
                        if score.isFinite {
                            let candidate = Candidate(
                                score: score, frequencyIndex: frequencyIndex,
                                durationIndex: durationIndex, phaseBin: phaseBin,
                                durationBins: durationBins, inCount: insideCount,
                                outCount: outsideCount
                            )
                            if better(candidate, than: best) { best = candidate }
                        }
                    }
                    let leaving = phaseBin
                    let entering = (phaseBin + durationBins) % payload.phaseBinCount
                    insideSum += sums[entering] - sums[leaving]
                    insideCount += counts[entering] - counts[leaving]
                }
            }
        }
        guard let best else { throw BoxPeriodSearchError.noValidWindow }
        let frequency = payload.startFrequency + Float(best.frequencyIndex) * payload.frequencyStep
        return BoxPeriodSearchResult(
            bestFrequency: frequency, bestScore: best.score,
            bestPhase: Float(best.phaseBin) / Float(payload.phaseBinCount),
            bestDurationFraction: Float(best.durationBins) / Float(payload.phaseBinCount),
            bestFrequencyIndex: payload.frequencyStartIndex + best.frequencyIndex,
            bestDurationIndex: best.durationIndex, bestPhaseBin: best.phaseBin,
            inBoxSamples: best.inCount, outOfBoxSamples: best.outCount
        )
    }
}
