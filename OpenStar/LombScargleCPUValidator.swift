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
import Accelerate

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
enum LombScargleCPUValidator {
    private static let absolutePowerTolerance = 5.0e-5
    private static let relativePowerTolerance = 0.01
    private static let localMaximumRelativeTolerance = 0.01

    /// Per-validation scratch is deliberately local: validation requests may run
    /// concurrently, while the three candidates in one request reuse these
    /// buffers without allocating in the hot candidate loop.
    private struct Scratch {
        var angles: [Double]
        var sines: [Double]
        var cosines: [Double]

        init(count: Int) {
            angles = .init(repeating: 0, count: count)
            sines = .init(repeating: 0, count: count)
            cosines = .init(repeating: 0, count: count)
        }
    }

    /// Compatibility entry point for standalone validator callers. Worker hot
    /// paths use the validation-ready dataset overload below.
    static func validate(
        coordinates: [Float],
        values: [Float],
        metalBestIndex: Int,
        metalBestPower: Double,
        startFrequency: Float,
        frequencyStep: Float,
        frequencyCount: Int
    ) throws -> LombScargleValidation {
        let valuesDouble = values.map(Double.init)
        return try validate(
            dataset: LombScargleValidationDataset(
                coordinates: coordinates.map(Double.init),
                values: valuesDouble,
                totalValueSquared: valuesDouble.reduce(0) { $0 + $1 * $1 }
            ),
            metalBestIndex: metalBestIndex,
            metalBestPower: metalBestPower,
            startFrequency: startFrequency,
            frequencyStep: frequencyStep,
            frequencyCount: frequencyCount
        )
    }

    /// Test-only reference entry point. Validation policy remains shared with
    /// production; only calculation of an individual candidate power differs.
    static func validateScalarReference(
        dataset: LombScargleValidationDataset,
        metalBestIndex: Int,
        metalBestPower: Double,
        startFrequency: Float,
        frequencyStep: Float,
        frequencyCount: Int
    ) throws -> LombScargleValidation {
        try validate(
            dataset: dataset,
            metalBestIndex: metalBestIndex,
            metalBestPower: metalBestPower,
            startFrequency: startFrequency,
            frequencyStep: frequencyStep,
            frequencyCount: frequencyCount,
            useScalarReference: true
        )
    }

    static func validate(
        dataset: LombScargleValidationDataset,
        metalBestIndex: Int,
        metalBestPower: Double,
        startFrequency: Float,
        frequencyStep: Float,
        frequencyCount: Int
    ) throws -> LombScargleValidation {
        try validate(
            dataset: dataset,
            metalBestIndex: metalBestIndex,
            metalBestPower: metalBestPower,
            startFrequency: startFrequency,
            frequencyStep: frequencyStep,
            frequencyCount: frequencyCount,
            useScalarReference: false
        )
    }

    private static func validate(
        dataset: LombScargleValidationDataset,
        metalBestIndex: Int,
        metalBestPower: Double,
        startFrequency: Float,
        frequencyStep: Float,
        frequencyCount: Int,
        useScalarReference: Bool
    ) throws -> LombScargleValidation {
        guard !dataset.coordinates.isEmpty else {
            throw LombScargleValidationError.invalidInput(
                "dataset is empty"
            )
        }

        guard dataset.coordinates.count == dataset.values.count else {
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

        guard dataset.coordinates.allSatisfy(\.isFinite) else {
            throw LombScargleValidationError.invalidInput(
                "coordinate sample is not finite"
            )
        }

        guard dataset.values.allSatisfy(\.isFinite) else {
            throw LombScargleValidationError.invalidInput(
                "value sample is not finite"
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
        var scratch = Scratch(count: dataset.coordinates.count)

        for index in candidateIndices {
            let frequency =
                Double(startFrequency) +
                Double(index) * Double(frequencyStep)

            let power = try useScalarReference
                ? scalarPowerMatchingMetalFormula(dataset: dataset, frequency: frequency)
                : powerMatchingMetalFormula(
                    dataset: dataset, frequency: frequency, scratch: &scratch
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
        dataset: LombScargleValidationDataset,
        frequency: Double,
        scratch: inout Scratch
    ) throws -> Double {
        guard frequency.isFinite,
              frequency > 0 else {
            throw LombScargleValidationError.invalidInput(
                "candidate frequency is invalid"
            )
        }

        let twoPi = 2.0 * Double.pi
        let omega = twoPi * frequency

        let count = vDSP_Length(dataset.coordinates.count)
        var trigCount = Int32(dataset.coordinates.count)
        var angleScale = 2.0 * omega
        vDSP_vsmulD(dataset.coordinates, 1, &angleScale, &scratch.angles, 1, count)
        vvsincos(&scratch.sines, &scratch.cosines, scratch.angles, &trigCount)

        var sumSin2 = 0.0
        var sumCos2 = 0.0
        vDSP_sveD(scratch.sines, 1, &sumSin2, count)
        vDSP_sveD(scratch.cosines, 1, &sumCos2, count)

        let tau = atan2(
            sumSin2,
            sumCos2
        ) / (2.0 * omega)

        angleScale = omega
        var angleOffset = -omega * tau
        vDSP_vsmulD(dataset.coordinates, 1, &angleScale, &scratch.angles, 1, count)
        vDSP_vsaddD(scratch.angles, 1, &angleOffset, &scratch.angles, 1, count)
        vvsincos(&scratch.sines, &scratch.cosines, scratch.angles, &trigCount)

        var sumYCos = 0.0
        var sumYSin = 0.0
        var sumCosSquared = 0.0
        var sumSinSquared = 0.0
        vDSP_dotprD(dataset.values, 1, scratch.cosines, 1, &sumYCos, count)
        vDSP_dotprD(dataset.values, 1, scratch.sines, 1, &sumYSin, count)
        vDSP_svesqD(scratch.cosines, 1, &sumCosSquared, count)
        vDSP_svesqD(scratch.sines, 1, &sumSinSquared, count)

        guard sumCosSquared > 0,
              sumSinSquared > 0,
              dataset.totalValueSquared.isFinite,
              dataset.totalValueSquared > 0 else {
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
            dataset.totalValueSquared

        guard power.isFinite else {
            throw LombScargleValidationError.invalidInput(
                "CPU validator power is not finite"
            )
        }

        return power
    }

    /// Straight-line implementation retained as the numerical oracle in tests.
    private static func scalarPowerMatchingMetalFormula(
        dataset: LombScargleValidationDataset,
        frequency: Double
    ) throws -> Double {
        guard frequency.isFinite, frequency > 0 else {
            throw LombScargleValidationError.invalidInput("candidate frequency is invalid")
        }
        let omega = 2.0 * Double.pi * frequency
        var sumSin2 = 0.0
        var sumCos2 = 0.0
        for coordinate in dataset.coordinates {
            sumSin2 += sin(2.0 * omega * coordinate)
            sumCos2 += cos(2.0 * omega * coordinate)
        }
        let tau = atan2(sumSin2, sumCos2) / (2.0 * omega)
        var sumYCos = 0.0
        var sumYSin = 0.0
        var sumCosSquared = 0.0
        var sumSinSquared = 0.0
        for index in dataset.coordinates.indices {
            let angle = omega * (dataset.coordinates[index] - tau)
            let cosine = cos(angle)
            let sine = sin(angle)
            sumYCos += dataset.values[index] * cosine
            sumYSin += dataset.values[index] * sine
            sumCosSquared += cosine * cosine
            sumSinSquared += sine * sine
        }
        guard sumCosSquared > 0, sumSinSquared > 0,
              dataset.totalValueSquared.isFinite, dataset.totalValueSquared > 0 else {
            throw LombScargleValidationError.invalidInput(
                "degenerate Lomb-Scargle normalization"
            )
        }
        let power = ((sumYCos * sumYCos) / sumCosSquared
            + (sumYSin * sumYSin) / sumSinSquared) / dataset.totalValueSquared
        guard power.isFinite else {
            throw LombScargleValidationError.invalidInput(
                "CPU validator power is not finite"
            )
        }
        return power
    }
}
