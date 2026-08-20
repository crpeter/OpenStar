//
//  LombScargleCPUValidator.swift
//  OpenStar
//
//  Float64 execution-integrity validation for the Lomb-Scargle workload.
//


import Foundation

nonisolated
struct LombScargleValidation: Sendable {
    static let validatorID = "openstar.lomb-scargle.local-double.v1"

    let passed: Bool
    let reason: String
    let metalBestIndex: Int
    let cpuBestLocalIndex: Int
    let metalBestPower: Double
    let cpuPowerAtMetalWinner: Double
    let absolutePowerError: Double
    let allowedPowerError: Double
}

nonisolated
enum LombScargleValidationError: LocalizedError {
    case invalidInput(String)
    case failed(LombScargleValidation)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return "Lomb-Scargle validation input is invalid: \(message)"
        case .failed(let validation):
            return validation.reason
        }
    }
}

/// Immutable, validation-ready representation of a prepared dataset.
nonisolated
final class LombScargleValidationDataset: @unchecked Sendable {
    let coordinates: [Double]
    let values: [Double]
    let totalValueSquared: Double

    init(coordinates: [Double], values: [Double], totalValueSquared: Double) {
        self.coordinates = coordinates
        self.values = values
        self.totalValueSquared = totalValueSquared
    }
}

nonisolated
struct LombScargleValidationRequest: Sendable {
    let metalBestIndex: Int
    let metalBestPower: Double
    let startFrequency: Float
    let frequencyStep: Float
    let frequencyCount: Int
}

nonisolated
enum LombScargleCPUValidator {
    private static let absolutePowerTolerance = 5.0e-5
    private static let relativePowerTolerance = 0.01
    private static let localMaximumRelativeTolerance = 0.01
    /// Bounds accumulator storage while still amortizing dataset traversal.
    private static let candidateTileSize = 24

    static func validate(
        coordinates: [Float], values: [Float], metalBestIndex: Int,
        metalBestPower: Double, startFrequency: Float,
        frequencyStep: Float, frequencyCount: Int
    ) throws -> LombScargleValidation {
        let valuesDouble = values.map(Double.init)
        return try validate(
            dataset: .init(
                coordinates: coordinates.map(Double.init), values: valuesDouble,
                totalValueSquared: valuesDouble.reduce(0) { $0 + $1 * $1 }
            ), metalBestIndex: metalBestIndex, metalBestPower: metalBestPower,
            startFrequency: startFrequency, frequencyStep: frequencyStep,
            frequencyCount: frequencyCount
        )
    }

    static func validate(
        dataset: LombScargleValidationDataset, metalBestIndex: Int,
        metalBestPower: Double, startFrequency: Float,
        frequencyStep: Float, frequencyCount: Int
    ) throws -> LombScargleValidation {
        let result = validateBatch(dataset: dataset, requests: [.init(
            metalBestIndex: metalBestIndex, metalBestPower: metalBestPower,
            startFrequency: startFrequency, frequencyStep: frequencyStep,
            frequencyCount: frequencyCount
        )])[0]
        return try result.get()
    }

    /// Validates every request independently, while traversing the shared
    /// dataset once per bounded tile of candidate frequencies.
    static func validateBatch(
        dataset: LombScargleValidationDataset,
        requests: [LombScargleValidationRequest]
    ) -> [Result<LombScargleValidation, any Error>] {
        guard !requests.isEmpty else { return [] }

        if let error = datasetError(dataset) {
            return requests.map { _ in .failure(error) }
        }

        struct Candidate {
            let request: Int
            let index: Int
            let omega: Double
        }
        var candidates: [Candidate] = []
        var errors: [Int: any Error] = [:]

        for (requestIndex, request) in requests.enumerated() {
            if let error = requestError(request) {
                errors[requestIndex] = error
                continue
            }
            for index in max(0, request.metalBestIndex - 1)...min(
                request.frequencyCount - 1, request.metalBestIndex + 1
            ) {
                let frequency = Double(request.startFrequency)
                    + Double(index) * Double(request.frequencyStep)
                guard frequency.isFinite, frequency > 0 else {
                    errors[requestIndex] = LombScargleValidationError.invalidInput(
                        "candidate frequency is invalid"
                    )
                    break
                }
                candidates.append(.init(
                    request: requestIndex, index: index,
                    omega: 2.0 * Double.pi * frequency
                ))
            }
        }

        var powers = Array<Double?>(repeating: nil, count: candidates.count)
        var tileStart = 0
        while tileStart < candidates.count {
            let tileEnd = min(tileStart + candidateTileSize, candidates.count)
            let count = tileEnd - tileStart
            var sumSin2 = Array(repeating: 0.0, count: count)
            var sumCos2 = Array(repeating: 0.0, count: count)

            for coordinate in dataset.coordinates {
                for local in 0..<count {
                    let angle = 2.0 * candidates[tileStart + local].omega * coordinate
                    sumSin2[local] += sin(angle)
                    sumCos2[local] += cos(angle)
                }
            }

            var taus = Array(repeating: 0.0, count: count)
            for local in 0..<count {
                let omega = candidates[tileStart + local].omega
                taus[local] = atan2(sumSin2[local], sumCos2[local]) / (2.0 * omega)
            }

            var sumYCos = Array(repeating: 0.0, count: count)
            var sumYSin = Array(repeating: 0.0, count: count)
            var sumCosSquared = Array(repeating: 0.0, count: count)
            var sumSinSquared = Array(repeating: 0.0, count: count)
            for sample in dataset.coordinates.indices {
                let coordinate = dataset.coordinates[sample]
                let value = dataset.values[sample]
                for local in 0..<count {
                    let angle = candidates[tileStart + local].omega
                        * (coordinate - taus[local])
                    let cosine = cos(angle)
                    let sine = sin(angle)
                    sumYCos[local] += value * cosine
                    sumYSin[local] += value * sine
                    sumCosSquared[local] += cosine * cosine
                    sumSinSquared[local] += sine * sine
                }
            }

            for local in 0..<count {
                let candidate = candidates[tileStart + local]
                guard sumCosSquared[local] > 0, sumSinSquared[local] > 0 else {
                    errors[candidate.request] = LombScargleValidationError.invalidInput(
                        "degenerate Lomb-Scargle normalization"
                    )
                    continue
                }
                let power = (
                    sumYCos[local] * sumYCos[local] / sumCosSquared[local]
                    + sumYSin[local] * sumYSin[local] / sumSinSquared[local]
                ) / dataset.totalValueSquared
                if power.isFinite {
                    powers[tileStart + local] = power
                } else {
                    errors[candidate.request] = LombScargleValidationError.invalidInput(
                        "CPU validator power is not finite"
                    )
                }
            }
            tileStart = tileEnd
        }

        return requests.enumerated().map { requestIndex, request in
            if let error = errors[requestIndex] { return .failure(error) }
            let local = candidates.indices.compactMap { candidateIndex
                -> (index: Int, power: Double)? in
                let candidate = candidates[candidateIndex]
                guard candidate.request == requestIndex,
                      let power = powers[candidateIndex] else { return nil }
                return (candidate.index, power)
            }
            guard let cpuWinner = local.max(by: { $0.power < $1.power }),
                  let winnerPower = local.first(where: {
                      $0.index == request.metalBestIndex
                  })?.power else {
                return .failure(LombScargleValidationError.invalidInput(
                    "CPU validator produced no finite local result"
                ))
            }
            return .success(makeValidation(
                request: request, cpuWinner: cpuWinner,
                winnerPower: winnerPower
            ))
        }
    }

    private static func datasetError(
        _ dataset: LombScargleValidationDataset
    ) -> (any Error)? {
        guard !dataset.coordinates.isEmpty else {
            return LombScargleValidationError.invalidInput("dataset is empty")
        }
        guard dataset.coordinates.count == dataset.values.count else {
            return LombScargleValidationError.invalidInput(
                "coordinate/value sample counts differ"
            )
        }
        guard dataset.coordinates.allSatisfy(\.isFinite) else {
            return LombScargleValidationError.invalidInput(
                "coordinate sample is not finite"
            )
        }
        guard dataset.values.allSatisfy(\.isFinite) else {
            return LombScargleValidationError.invalidInput("value sample is not finite")
        }
        guard dataset.totalValueSquared.isFinite,
              dataset.totalValueSquared > 0 else {
            return LombScargleValidationError.invalidInput(
                "degenerate Lomb-Scargle normalization"
            )
        }
        return nil
    }

    private static func requestError(
        _ request: LombScargleValidationRequest
    ) -> (any Error)? {
        guard request.frequencyCount > 0, request.frequencyStep.isFinite,
              request.frequencyStep > 0, request.startFrequency.isFinite,
              request.startFrequency > 0 else {
            return LombScargleValidationError.invalidInput("frequency grid is invalid")
        }
        guard request.metalBestIndex >= 0,
              request.metalBestIndex < request.frequencyCount else {
            return LombScargleValidationError.invalidInput(
                "GPU winner index is outside the work unit"
            )
        }
        guard request.metalBestPower.isFinite else {
            return LombScargleValidationError.invalidInput(
                "GPU winner power is not finite"
            )
        }
        return nil
    }

    private static func makeValidation(
        request: LombScargleValidationRequest,
        cpuWinner: (index: Int, power: Double), winnerPower: Double
    ) -> LombScargleValidation {
        let absolutePowerError = abs(request.metalBestPower - winnerPower)
        let allowedPowerError = max(
            absolutePowerTolerance, abs(winnerPower) * relativePowerTolerance
        )
        let localMaximumTolerance = max(
            absolutePowerTolerance,
            abs(cpuWinner.power) * localMaximumRelativeTolerance
        )
        let powerMatches = absolutePowerError <= allowedPowerError
        let locallyConsistent = winnerPower >= cpuWinner.power - localMaximumTolerance
        let reason: String
        if !powerMatches {
            reason = String(format: (
                "Local Float64 integrity check failed: GPU power %.8f, "
                + "CPU same-formula power %.8f, error %.8f, allowed %.8f."
            ), request.metalBestPower, winnerPower, absolutePowerError, allowedPowerError)
        } else if !locallyConsistent {
            reason = String(format: (
                "Local Float64 integrity check failed: GPU winner bin %d "
                + "is not a local maximum; CPU local winner is bin %d."
            ), request.metalBestIndex, cpuWinner.index)
        } else {
            reason = "Local Float64 integrity check passed."
        }
        return LombScargleValidation(
            passed: powerMatches && locallyConsistent, reason: reason,
            metalBestIndex: request.metalBestIndex,
            cpuBestLocalIndex: cpuWinner.index,
            metalBestPower: request.metalBestPower,
            cpuPowerAtMetalWinner: winnerPower,
            absolutePowerError: absolutePowerError,
            allowedPowerError: allowedPowerError
        )
    }
}
