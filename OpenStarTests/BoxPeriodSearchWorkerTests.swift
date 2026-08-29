//
//  BoxPeriodSearchWorkerTests.swift
//  OpenStarTests
//

import Testing
@testable import OpenStar

struct BoxPeriodSearchWorkerTests {
    private func fixture() throws -> (BoxPeriodSearchDataset, BoxPeriodSearchPayload) {
        let coordinates = (0..<80).map { Float($0) * 0.25 }
        let values = coordinates.map { time -> Float in
            let cycles = time * 0.5
            let phase = cycles - cycles.rounded(.down)
            return phase < 0.15 ? -2.0 : 0.25
        }
        let dataset = BoxPeriodSearchDataset(
            coordinates: coordinates, values: values, times: nil, flux: nil
        )
        let payload = try BoxPeriodSearchPayload(.object([
            "startFrequency": .number(0.4),
            "frequencyStep": .number(0.05),
            "frequencyCount": .number(5),
            "frequencyStartIndex": .number(20),
            "phaseBinCount": .number(20),
            "durationFractions": .array([.number(0.1), .number(0.15)]),
            "minimumInBoxSamples": .number(4),
            "minimumOutOfBoxSamples": .number(20),
        ]))
        return (dataset, payload)
    }

    @Test
    func crossLanguageGoldenVector() throws {
        let (dataset, payload) = try fixture()
        let result = try BoxPeriodSearchWorker.score(dataset: dataset, payload: payload)

        #expect(result.bestFrequencyIndex == 22)
        #expect(abs(result.bestFrequency - 0.5) < 1e-7)
        #expect(result.bestDurationIndex == 1)
        #expect(result.bestPhaseBin == 0)
        #expect(abs(result.bestPhase) < 1e-7)
        #expect(abs(result.bestDurationFraction - 0.15) < 1e-7)
        #expect(result.inBoxSamples == 20)
        #expect(result.outOfBoxSamples == 60)
        #expect(abs(result.bestScore - 8.714213) < 1e-5)
    }

    @Test
    func capabilityIsGenericAndCPUOnly() {
        let worker = BoxPeriodSearchWorker()
        #expect(worker.workloadIDs == ["openstar.box-period-search.v1"])
        #expect(worker.capabilities == [
            WorkloadCapability(
                workloadID: "openstar.box-period-search.v1",
                executionBackends: [.cpu],
                validatorID: nil
            )
        ])
    }

    @Test
    func invalidPhaseBinCountIsRejected() {
        #expect(throws: BoxPeriodSearchError.self) {
            _ = try BoxPeriodSearchPayload(.object([
                "startFrequency": .number(0.4),
                "frequencyStep": .number(0.05),
                "frequencyCount": .number(5),
                "phaseBinCount": .number(1),
                "durationFractions": .array([.number(0.1)]),
                "minimumInBoxSamples": .number(4),
                "minimumOutOfBoxSamples": .number(20),
            ]))
        }
    }
}

