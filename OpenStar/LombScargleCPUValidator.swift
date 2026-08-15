//
//  LombScargleCPUValidator.swift
//  OpenStar
//
//  Workload-owned execution-integrity validator for
//  openstar.lomb-scargle.v1 / legacy openstar.tess-period-search.v1.
//
//  This intentionally does NOT implement Astropy. It recomputes the exact
//  mathematical formula used by OpenStarKernels.metal in Float64 at the GPU
//  winner and its immediate neighboring grid points. Its job is to detect a
//  broken execution, not to decide astrophysical/scientific correctness.
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

nonisolated
enum LombScargleCPUValidator {
    private static let absolutePowerTolerance = 5.0e-5
    private static let relativePowerTolerance = 0.01
    private static let localMaximumRelativeTolerance = 0.01

    static func validate(
        coordinates: [Float],
        values: [Float],
        metalBestIndex: Int,
        metalBestPower: Double,
        startFrequency: Float,
        frequencyStep: Float,
        frequencyCount: Int
    ) throws -> LombScargleValidation {
        guard !coordinates.isEmpty else {
            throw LombScargleValidationError.invalidInput(
                "dataset is empty"
            )
        }

        guard coordinates.count == values.count else {
            throw LombScargleValidationError.invalidInput(
                "coordinate/value sample counts differ"
            )
        }

        guard frequencyCount > 0,
              frequencyStep.isFinite,
              frequencyStep > 0,
              startFrequency.isFinite,
              startFrequency > 0 else {
            throw LombScargleValidationError.invalidInput(
                "frequency grid is invalid"
            )
        }

        guard metalBestIndex >= 0,
              metalBestIndex < frequencyCount else {
            throw LombScargleValidationError.invalidInput(
                "GPU winner index is outside the work unit"
            )
        }

        guard metalBestPower.isFinite else {
            throw LombScargleValidationError.invalidInput(
                "GPU winner power is not finite"
            )
        }

        let candidateIndices = [
            metalBestIndex - 1,
            metalBestIndex,
            metalBestIndex + 1
        ]
        .filter {
            $0 >= 0 && $0 < frequencyCount
        }

        var localPowers: [(index: Int, power: Double)] = []
        localPowers.reserveCapacity(candidateIndices.count)

        for index in candidateIndices {
            let frequency =
                Double(startFrequency) +
                Double(index) * Double(frequencyStep)

            let power = try powerMatchingMetalFormula(
                coordinates: coordinates,
                values: values,
                frequency: frequency
            )

            localPowers.append(
                (index: index, power: power)
            )
        }

        guard let cpuWinner = localPowers.max(
            by: { $0.power < $1.power }
        ),
        let winnerPower = localPowers.first(
            where: { $0.index == metalBestIndex }
        )?.power else {
            throw LombScargleValidationError.invalidInput(
                "CPU validator produced no finite local result"
            )
        }

        let absolutePowerError = abs(
            metalBestPower - winnerPower
        )

        let allowedPowerError = max(
            absolutePowerTolerance,
            abs(winnerPower) * relativePowerTolerance
        )

        let localMaximumTolerance = max(
            absolutePowerTolerance,
            abs(cpuWinner.power) * localMaximumRelativeTolerance
        )

        let powerMatches =
            absolutePowerError <= allowedPowerError

        let locallyConsistent =
            winnerPower >= cpuWinner.power - localMaximumTolerance

        let passed = powerMatches && locallyConsistent

        let reason: String

        if !powerMatches {
            reason = String(
                format: (
                    "Local Float64 integrity check failed: GPU power %.8f, " +
                    "CPU same-formula power %.8f, error %.8f, allowed %.8f."
                ),
                metalBestPower,
                winnerPower,
                absolutePowerError,
                allowedPowerError
            )
        } else if !locallyConsistent {
            reason = String(
                format: (
                    "Local Float64 integrity check failed: GPU winner bin %d " +
                    "is not a local maximum; CPU local winner is bin %d."
                ),
                metalBestIndex,
                cpuWinner.index
            )
        } else {
            reason = "Local Float64 integrity check passed."
        }

        return LombScargleValidation(
            passed: passed,
            reason: reason,
            metalBestIndex: metalBestIndex,
            cpuBestLocalIndex: cpuWinner.index,
            metalBestPower: metalBestPower,
            cpuPowerAtMetalWinner: winnerPower,
            absolutePowerError: absolutePowerError,
            allowedPowerError: allowedPowerError
        )
    }

    private static func powerMatchingMetalFormula(
        coordinates: [Float],
        values: [Float],
        frequency: Double
    ) throws -> Double {
        guard frequency.isFinite,
              frequency > 0 else {
            throw LombScargleValidationError.invalidInput(
                "candidate frequency is invalid"
            )
        }

        let twoPi = 2.0 * Double.pi
        let omega = twoPi * frequency

        var sumSin2 = 0.0
        var sumCos2 = 0.0

        for coordinateFloat in coordinates {
            let coordinate = Double(coordinateFloat)

            guard coordinate.isFinite else {
                throw LombScargleValidationError.invalidInput(
                    "coordinate sample is not finite"
                )
            }

            let angle = 2.0 * omega * coordinate
            sumSin2 += sin(angle)
            sumCos2 += cos(angle)
        }

        let tau = atan2(
            sumSin2,
            sumCos2
        ) / (2.0 * omega)

        var sumYCos = 0.0
        var sumYSin = 0.0
        var sumCosSquared = 0.0
        var sumSinSquared = 0.0
        var totalValueSquared = 0.0

        for index in coordinates.indices {
            let coordinate = Double(coordinates[index])
            let value = Double(values[index])

            guard value.isFinite else {
                throw LombScargleValidationError.invalidInput(
                    "value sample is not finite"
                )
            }

            let shiftedCoordinate = coordinate - tau
            let angle = omega * shiftedCoordinate
            let cosine = cos(angle)
            let sine = sin(angle)

            sumYCos += value * cosine
            sumYSin += value * sine

            sumCosSquared += cosine * cosine
            sumSinSquared += sine * sine
            totalValueSquared += value * value
        }

        guard sumCosSquared > 0,
              sumSinSquared > 0,
              totalValueSquared > 0 else {
            throw LombScargleValidationError.invalidInput(
                "degenerate Lomb-Scargle normalization"
            )
        }

        let cosinePower =
            (sumYCos * sumYCos) /
            sumCosSquared

        let sinePower =
            (sumYSin * sumYSin) /
            sumSinSquared

        let power =
            (cosinePower + sinePower) /
            totalValueSquared

        guard power.isFinite else {
            throw LombScargleValidationError.invalidInput(
                "CPU validator power is not finite"
            )
        }

        return power
    }
}
