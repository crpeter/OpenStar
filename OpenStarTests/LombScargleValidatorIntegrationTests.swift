import Foundation
import Testing
@testable import OpenStar

@Suite(.serialized)
struct LombScargleValidatorIntegrationTests {
    private struct EncodedDataset: Encodable {
        let coordinates: [Float]
        let values: [Float]
    }

    @Test
    func optimizedValidatorMatchesOriginalScalarEndToEndThroughRealMetalBatch() async throws {
        let worker = try LombScargleWorker()

        // Deterministic, nontrivial light curve: enough samples to exercise the
        // vectorized validator on a realistic-sized dataset, with a dominant
        // injected signal and a weaker secondary component.
        let coordinates: [Float] = (0..<769).map { index in
            Float(index) * 0.031 + Float(index % 7) * 0.000_13
        }
        let injectedFrequency = 0.73
        let values: [Float] = coordinates.enumerated().map { index, coordinate in
            let time = Double(coordinate)
            let primary = sin(2.0 * Double.pi * injectedFrequency * time)
            let secondary = 0.17 * cos(2.0 * Double.pi * 1.21 * time)
            let deterministicNoise = 0.025 * sin(Double(index) * 0.173)
            return Float(primary + secondary + deterministicNoise)
        }
        let datasetData = try JSONEncoder().encode(
            EncodedDataset(coordinates: coordinates, values: values)
        )

        // Four contiguous children force the normal fused Metal execution path.
        // Validation still occurs independently per child, exactly as in fleet use.
        let baseFrequency: Float = 0.45
        let frequencyStep: Float = 0.005
        let counts = [80, 80, 80, 80]
        var nextStartIndex = 0
        var grids: [(startIndex: Int, startFrequency: Float, count: Int)] = []
        let units: [WorkUnit] = counts.map { count in
            let startIndex = nextStartIndex
            nextStartIndex += count
            let startFrequency = baseFrequency + Float(startIndex) * frequencyStep
            grids.append((startIndex, startFrequency, count))
            return WorkUnit(
                id: UUID(),
                projectID: "validator-integration",
                workloadID: LombScargleWorker.workloadID,
                datasetID: "deterministic-signal",
                payload: .object([
                    "frequencyStartIndex": .number(Double(startIndex)),
                    "startFrequency": .number(Double(startFrequency)),
                    "frequencyStep": .number(Double(frequencyStep)),
                    "frequencyCount": .number(Double(count))
                ]),
                frequencyStartIndex: nil,
                startFrequency: nil,
                frequencyStep: nil,
                frequencyCount: nil
            )
        }

        let members = try await worker.executeBatch(
            workUnits: units,
            datasetData: datasetData
        )
        #expect(members.count == units.count)
        let executions = try members.map { try $0.result.get() }

        let valuesDouble = values.map(Double.init)
        let referenceDataset = LombScargleValidationDataset(
            coordinates: coordinates.map(Double.init),
            values: valuesDouble,
            totalValueSquared: valuesDouble.reduce(0) { $0 + $1 * $1 }
        )

        for ((execution, grid), unit) in zip(zip(executions, grids), units) {
            let result = try #require(execution.payload.objectValue)
            let validation = try #require(result["validation"]?.objectValue)

            let validatorIDValue = try #require(validation["validatorID"])
            if case .string(let validatorID) = validatorIDValue {
                #expect(validatorID == LombScargleValidation.validatorID)
            } else {
                Issue.record("Expected validatorID string in worker result")
            }

            let passedValue = try #require(validation["passed"])
            if case .bool(let passed) = passedValue {
                #expect(passed)
            } else {
                Issue.record("Expected validation passed boolean in worker result")
            }

            let globalBestIndex = Int(try #require(
                result["bestFrequencyIndex"]?.doubleValue
            ))
            let localBestIndex = globalBestIndex - grid.startIndex
            #expect((0..<grid.count).contains(localBestIndex))
            let legacyBestPower = try #require(
                execution.legacyResultFields.bestPower
            )

            // This is the untouched straight-line validator implementation from
            // the first version. Feed it the real GPU-selected winner from the
            // end-to-end worker result and require the production worker path to
            // agree with it before and after optimization.
            let scalarReference = try LombScargleCPUValidator.validateScalarReference(
                dataset: referenceDataset,
                metalBestIndex: localBestIndex,
                metalBestPower: legacyBestPower,
                startFrequency: grid.startFrequency,
                frequencyStep: frequencyStep,
                frequencyCount: grid.count
            )
            #expect(scalarReference.passed)

            let productionCPUPower = try #require(
                validation["cpuPowerAtMetalWinner"]?.doubleValue
            )
            let productionLocalWinner = Int(try #require(
                validation["cpuBestLocalIndex"]?.doubleValue
            ))
            let absolutePowerError = try #require(
                validation["absolutePowerError"]?.doubleValue
            )
            let allowedPowerError = try #require(
                validation["allowedPowerError"]?.doubleValue
            )
            let validationDuration = try #require(
                validation["durationSeconds"]?.doubleValue
            )

            #expect(abs(
                productionCPUPower - scalarReference.cpuPowerAtMetalWinner
            ) < 2e-11)
            #expect(productionLocalWinner == scalarReference.cpuBestLocalIndex)
            #expect(abs(
                allowedPowerError - scalarReference.allowedPowerError
            ) < 2e-13)
            #expect(absolutePowerError <= allowedPowerError)
            #expect(validationDuration >= 0)

            // Preserve the per-child identity/result association through fusion.
            #expect(members.first(where: { $0.workUnit.id == unit.id }) != nil)
        }

        // The complete worker result should still recover the dominant injected
        // signal from the full fused search range.
        let scoredExecutions = try executions.map { execution in
            (
                execution: execution,
                power: try #require(execution.legacyResultFields.bestPower)
            )
        }
        let strongest = try #require(
            scoredExecutions.max { $0.power < $1.power }
        ).execution
        let strongestFrequency = try #require(
            strongest.legacyResultFields.bestFrequency
        )
        #expect(abs(
            strongestFrequency - injectedFrequency
        ) <= Double(frequencyStep) * 2.0)

        let cache = worker.preparedDatasetDebugState(
            projectID: "validator-integration",
            datasetID: "deterministic-signal"
        )
        #expect(cache.validationDataset != nil)
        #expect(cache.preparations == 1)
    }
}
