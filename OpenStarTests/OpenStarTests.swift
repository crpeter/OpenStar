import Foundation
import Testing
@testable import OpenStar

@Suite(.serialized)
struct OpenStarTests {
    private let workID = UUID()

    @Test func adaptiveBatchControllerLearnsWithHysteresisAndBounds() {
        let controller = AdaptiveBatchController()
        #expect(controller.desiredBatchCount == 1)
        #expect(controller.observe(metalDuration: 0.005) == 2)
        #expect(controller.observe(metalDuration: 0.005) == 4)
        #expect(controller.observe(metalDuration: 0.005) == 8)
        for _ in 0..<10 { _ = controller.observe(metalDuration: 0.045) }
        let stable = controller.desiredBatchCount
        _ = controller.observe(metalDuration: 0.050)
        #expect(controller.desiredBatchCount == stable)
        let beforeOverlong = controller.desiredBatchCount
        _ = controller.observe(metalDuration: 1.0)
        #expect(controller.desiredBatchCount == max(beforeOverlong / 2, 1))
        for _ in 0..<20 { _ = controller.observe(metalDuration: 0) }
        #expect(controller.desiredBatchCount == 128)
    }

    @Test func adaptiveBatchControllerHoldsAtA19TargetObservation() {
        let controller = AdaptiveBatchController()
        let observations = [0.0158, 0.0090, 0.0154, 0.0337, 0.0492]
        let counts = observations.map { controller.observe(metalDuration: $0) }
        #expect(counts == [2, 4, 8, 16, 16])
        #expect(controller.desiredBatchCount == 16)
    }

    @Test func adaptiveBatchControllerIgnoresIsolatedOverrun() {
        let controller = AdaptiveBatchController()
        for _ in 0..<3 { _ = controller.observe(metalDuration: 0.005) }

        let counts = [0.054, 0.063, 0.055].map {
            controller.observe(metalDuration: $0)
        }

        #expect(counts == [8, 8, 8])
    }

    @Test func adaptiveBatchControllerShrinksAfterConsecutiveOverruns() {
        let controller = AdaptiveBatchController()
        for _ in 0..<3 { _ = controller.observe(metalDuration: 0.005) }

        let counts = [0.063, 0.064].map {
            controller.observe(metalDuration: $0)
        }

        #expect(counts == [8, 4])
    }

    @Test func adaptiveBatchControllerShrinksImmediatelyForSevereOverrun() {
        let controller = AdaptiveBatchController()
        for _ in 0..<3 { _ = controller.observe(metalDuration: 0.005) }

        #expect(controller.observe(metalDuration: 0.080) == 4)
    }

    @Test func adaptiveBatchControllerCanGrowAgainAfterShrink() {
        let controller = AdaptiveBatchController()
        for _ in 0..<3 { _ = controller.observe(metalDuration: 0.005) }
        #expect(controller.observe(metalDuration: 0.080) == 4)

        for _ in 0..<10 { _ = controller.observe(metalDuration: 0.005) }

        #expect(controller.desiredBatchCount > 4)
    }

    @Test func adaptiveBatchControllerTargetBandIgnoresStaleSlowEWMA() {
        let controller = AdaptiveBatchController()
        for _ in 0..<5 { _ = controller.observe(metalDuration: 0) }
        #expect(controller.desiredBatchCount == 32)

        #expect(controller.observe(metalDuration: 0.080) == 16)
        #expect(controller.observe(metalDuration: 0.049) == 16)

        var observations = 0
        while controller.desiredBatchCount == 16, observations < 20 {
            _ = controller.observe(metalDuration: 0.010)
            observations += 1
        }
        #expect(observations > 1)
        #expect(controller.desiredBatchCount == 32)
    }

    @Test func fusedTimingIsAllocatedOnceIncludingPartialTail() {
        let allocated = LombScargleWorker.allocatedDurations(
            total: 0.046, frequencyCounts: [10, 10, 3]
        )
        #expect(allocated.count == 3)
        #expect(abs(allocated.reduce(0, +) - 0.046) < 1e-15)
        #expect(abs(allocated[0] - 0.020) < 1e-15)
        #expect(abs(allocated[1] - 0.020) < 1e-15)
        #expect(abs(allocated[2] - 0.006) < 1e-15)

        let totalDurations = LombScargleWorker.allocatedDurations(
            total: 0.092, frequencyCounts: [10, 10, 3]
        )
        let preparationDurations = LombScargleWorker.allocatedDurations(
            total: 0.023, frequencyCounts: [10, 10, 3]
        )
        #expect(abs(totalDurations.reduce(0, +) - 0.092) < 1e-15)
        #expect(abs(preparationDurations.reduce(0, +) - 0.023) < 1e-15)
        #expect(abs(preparationDurations[2] - 0.003) < 1e-15)
    }

    @Test func cancellationUsesNoPenaltyFailureClassification() {
        #expect(classifyWorkFailure(CancellationError()) == .environmentUnavailable)
        #expect(classifyWorkFailure(WorkloadCancellation()) == .environmentUnavailable)
        #expect(classifyWorkFailure(CancellationError()) != .unknown)
        #expect(classifyWorkFailure(CancellationError()) != .execution)
    }

    @Test func partialBatchKeepsCompletedSiblingAndAccountsForEveryClaim() async throws {
        let router = try WorkloadRouter(handlers: [PartialBatchHandler()])
        let units = (0..<3).map { _ in
            WorkUnit(
                id: UUID(), projectID: "p", workloadID: "batch", datasetID: nil,
                payload: nil, frequencyStartIndex: nil, startFrequency: nil,
                frequencyStep: nil, frequencyCount: nil
            )
        }
        let members = try await router.executeBatch(workUnits: units, datasetData: nil)
        #expect(members.map(\.workUnit.id) == units.map(\.id))
        #expect(members.count == units.count)
        if case .success = members[0].result {} else {
            Issue.record("completed sibling was poisoned")
        }
        for member in members.dropFirst() {
            do {
                _ = try member.result.get()
                Issue.record("unexecuted child unexpectedly completed")
            } catch {
                #expect(classifyWorkFailure(error) == .environmentUnavailable)
            }
        }
    }

    @Test func nonBatchingHandlerForcesSingleUnitClaims() throws {
        let batchOnly = try WorkloadRouter(handlers: [PartialBatchHandler()])
        #expect(batchOnly.desiredBatchCount == 16)
        let mixed = try WorkloadRouter(handlers: [
            PartialBatchHandler(), StubHandler(workloadID: "single")
        ])
        #expect(mixed.desiredBatchCount == 1)
    }

    @Test func lombScargleGroupingOnlyFusesExactContiguousCoverage() {
        let units = [0, 10, 30, 20].map { start in
            scopedWorkUnit(
                projectID: "p", datasetID: "d",
                payload: .object([
                    "frequencyStartIndex": .number(Double(start)),
                    "startFrequency": .number(1 + Double(start) * 0.1),
                    "frequencyStep": .number(0.1),
                    "frequencyCount": .number(10)
                ])
            )
        }
        let groups = LombScargleWorker.contiguousGroups(units)
        #expect(groups.count == 1)
        #expect(groups[0].units.count == 4)
        let indices = groups[0].payloads.flatMap {
            Array($0.frequencyStartIndex..<($0.frequencyStartIndex + $0.frequencyCount))
        }
        #expect(indices == Array(0..<40))

        let gap = LombScargleWorker.contiguousGroups([units[0], units[2]])
        #expect(gap.count == 2)
        let overlap = LombScargleWorker.contiguousGroups([units[0], units[0]])
        #expect(overlap.count == 2)

        let roundedStart = scopedWorkUnit(
            projectID: "p", datasetID: "d",
            payload: .object([
                "frequencyStartIndex": .number(10),
                "startFrequency": .number(Double(Float(1.0) + 10 * Float(0.1))),
                "frequencyStep": .number(0.1), "frequencyCount": .number(10)
            ])
        )
        #expect(LombScargleWorker.contiguousGroups([units[0], roundedStart]).count == 1)

        let mismatchedStep = scopedWorkUnit(
            projectID: "p", datasetID: "d",
            payload: .object([
                "frequencyStartIndex": .number(10), "startFrequency": .number(2),
                "frequencyStep": .number(0.11), "frequencyCount": .number(10)
            ])
        )
        #expect(LombScargleWorker.contiguousGroups([units[0], mismatchedStep]).count == 2)

        let smallStep = Float(0.0000100)
        let smallStart = Float(1) + Float(10) * smallStep
        let smallPrevious = scopedWorkUnit(
            projectID: "small", datasetID: "grid",
            payload: .object([
                "frequencyStartIndex": .number(0), "startFrequency": .number(1),
                "frequencyStep": .number(Double(smallStep)),
                "frequencyCount": .number(10)
            ])
        )
        let materiallyDifferentStep = scopedWorkUnit(
            projectID: "small", datasetID: "grid",
            payload: .object([
                "frequencyStartIndex": .number(10),
                "startFrequency": .number(Double(smallStart)),
                "frequencyStep": .number(0.0000105),
                "frequencyCount": .number(10)
            ])
        )
        #expect(LombScargleWorker.contiguousGroups(
            [smallPrevious, materiallyDifferentStep]
        ).count == 2)

        let roundedStep = scopedWorkUnit(
            projectID: "small", datasetID: "grid",
            payload: .object([
                "frequencyStartIndex": .number(10),
                "startFrequency": .number(Double(smallStart)),
                "frequencyStep": .number(Double(smallStep.nextUp)),
                "frequencyCount": .number(10)
            ])
        )
        #expect(LombScargleWorker.contiguousGroups(
            [smallPrevious, roundedStep]
        ).count == 1)

        let independentlyQuantizedStart = scopedWorkUnit(
            projectID: "small", datasetID: "grid",
            payload: .object([
                "frequencyStartIndex": .number(10),
                "startFrequency": .number(
                    Double(smallStart + smallStep * 0.25)
                ),
                "frequencyStep": .number(Double(smallStep)),
                "frequencyCount": .number(10)
            ])
        )
        #expect(LombScargleWorker.contiguousGroups(
            [smallPrevious, independentlyQuantizedStart]
        ).count == 1)
    }

    @Test func tessFloatQuantizationDoesNotSplitContiguousCoverage() throws {
        let minimum = 0.1
        let step = (5.0 - minimum) / 4_194_304.0
        let units = stride(from: 0, to: 4_194_304, by: 4096).map { index in
            scopedWorkUnit(
                projectID: "tess", datasetID: "full-grid",
                payload: .object([
                    "frequencyStartIndex": .number(Double(index)),
                    "startFrequency": .number(minimum + Double(index) * step),
                    "frequencyStep": .number(step),
                    "frequencyCount": .number(4096)
                ])
            )
        }
        let groups = LombScargleWorker.contiguousGroups(units)
        #expect(groups.count == 8)
        #expect(groups.allSatisfy { $0.units.count == 128 })
    }

    @Test func fusedFrequenciesPreserveEachChildFloatStart() throws {
        let step = (5.0 - 0.1) / 4_194_304.0
        let units = [0, 4096, 8192].map { index in
            scopedWorkUnit(
                projectID: "tess", datasetID: "quantized",
                payload: .object([
                    "frequencyStartIndex": .number(Double(index)),
                    "startFrequency": .number(0.1 + Double(index) * step),
                    "frequencyStep": .number(step),
                    "frequencyCount": .number(4096)
                ])
            )
        }
        let payloads = try units.map { try LombScargleWorker.workPayload(from: $0) }
        let fused = LombScargleWorker.fusedFrequencies(payloads: payloads)
        let independent = payloads.flatMap { payload in
            (0..<payload.frequencyCount).map {
                payload.startFrequency + Float($0) * payload.frequencyStep
            }
        }
        #expect(fused == independent)
        #expect(fused[4096] == payloads[1].startFrequency)
    }

    @Test func fusedFrequenciesPreserveFuseableChildStepULP() throws {
        let firstStep = Float(0.00001)
        let secondStep = firstStep.nextUp
        let units = [
            scopedWorkUnit(
                projectID: "step-ulp", datasetID: "shared",
                payload: .object([
                    "frequencyStartIndex": .number(0),
                    "startFrequency": .number(0.1),
                    "frequencyStep": .number(Double(firstStep)),
                    "frequencyCount": .number(8)
                ])
            ),
            scopedWorkUnit(
                projectID: "step-ulp", datasetID: "shared",
                payload: .object([
                    "frequencyStartIndex": .number(8),
                    "startFrequency": .number(0.2),
                    "frequencyStep": .number(Double(secondStep)),
                    "frequencyCount": .number(8)
                ])
            )
        ]
        let groups = LombScargleWorker.contiguousGroups(units)
        #expect(groups.count == 1)
        #expect(groups[0].units.count == 2)

        let payloads = groups[0].payloads
        let independent = payloads.flatMap { payload in
            (0..<payload.frequencyCount).map {
                payload.startFrequency + Float($0) * payload.frequencyStep
            }
        }
        #expect(LombScargleWorker.fusedFrequencies(payloads: payloads) == independent)
        #expect(payloads[1].frequencyStep == payloads[0].frequencyStep.nextUp)
    }

    @Test func coordinatorBatchClaimDecodesObjectArrayAndEmpty() async throws {
        let id = UUID()
        let object = Self.workData(id: id)
        let objectRecorder = RequestRecorder { _ in (object, 200) }
        let objectClient = coordinatorClient(recorder: objectRecorder)
        #expect(try await objectClient.claimWork(nodeID: UUID(), maxWorkUnits: 8).map(\.id) == [id])
        let request = try JSONDecoder().decode(
            WorkClaimRequest.self, from: try #require(objectRecorder.bodies.first)
        )
        #expect(request.maxWorkUnits == 8)

        let arrayClient = coordinatorClient(recorder: RequestRecorder { _ in
            (Data("[\(String(decoding: object, as: UTF8.self))]".utf8), 200)
        })
        #expect(try await arrayClient.claimWork(nodeID: UUID(), maxWorkUnits: 32).count == 1)

        let emptyClient = coordinatorClient(recorder: RequestRecorder { _ in
            (Data(), 204)
        })
        #expect(try await emptyClient.claimWork(nodeID: UUID(), maxWorkUnits: 4).isEmpty)
    }

    @Test func integerJSONConversionRejectsOutOfRangeNumbers() {
        #expect(JSONValue.number(4).intValue == 4)
        #expect(JSONValue.number(4.5).intValue == nil)
        #expect(JSONValue.number(Double.greatestFiniteMagnitude).intValue == nil)
    }

    @Test func lombScargleDecodesGenericScalarTimeSeriesDataset() throws {
        let data = Data(
            #"{"coordinates":[0,1,2],"values":[4,5,6]}"#.utf8
        )

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        #expect(dataset.id == nil)
        #expect(dataset.coordinates == [0, 1, 2])
        #expect(dataset.values == [4, 5, 6])
    }

    @Test func lombScargleDecodesExistingTimeFluxDataset() throws {
        let data = Data(
            #"{"id":"legacy","mission":"TESS","times":[0,1],"flux":[2,3]}"#.utf8
        )

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        #expect(dataset.id == "legacy")
        #expect(dataset.coordinates == [0, 1])
        #expect(dataset.values == [2, 3])
    }

    @Test func genericDatasetFieldsTakePrecedenceOverLegacyAliases() throws {
        let data = Data(
            #"{"coordinates":[1],"values":[2],"times":[3],"flux":[4]}"#.utf8
        )

        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        #expect(dataset.coordinates == [1])
        #expect(dataset.values == [2])
    }

    @Test func lombScargleAdvertisesGenericIDAndCompatibilityAlias() {
        #expect(LombScargleWorker.workloadID == "openstar.lomb-scargle.v1")
        #expect(
            LombScargleWorker.legacyWorkloadID ==
                "openstar.tess-period-search.v1"
        )
    }

    @Test func impactingInteractivityIsEnvironmentUnavailable() {
        let messages = [
            "Impacting Interactivity",
            "Metal command failed (kIOGPUCommandBufferCallbackErrorImpactingInteractivity)"
        ]

        for message in messages {
            #expect(
                LombScargleError.commandFailed(error(message)).workFailureKind ==
                    .environmentUnavailable
            )
        }
    }

    @Test func backgroundMetalInterruptionsRemainEnvironmentUnavailable() {
        let messages = [
            "kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted",
            "Cannot submit GPU work from background"
        ]

        for message in messages {
            #expect(
                LombScargleError.commandFailed(error(message)).workFailureKind ==
                    .environmentUnavailable
            )
        }
    }

    @Test func unrelatedMetalCommandFailureRemainsExecutionFailure() {
        #expect(
            LombScargleError.commandFailed(
                error("kIOGPUCommandBufferCallbackErrorPageFault")
            ).workFailureKind == .execution
        )
        #expect(LombScargleError.commandFailed(nil).workFailureKind == .execution)
    }

    @Test func validationAndInvalidInputClassificationsRemainUnchanged() {
        let validation = LombScargleValidation(
            passed: false,
            reason: "mismatch",
            metalBestIndex: 1,
            cpuBestLocalIndex: 2,
            metalBestPower: 0.5,
            cpuPowerAtMetalWinner: 0.4,
            absolutePowerError: 0.1,
            allowedPowerError: 0.01
        )

        #expect(
            LombScargleError.validationFailed(validation).workFailureKind ==
                .workloadValidation
        )
        #expect(LombScargleError.invalidDataset.workFailureKind == .invalidInput)
        #expect(
            LombScargleValidationError.invalidInput("bad input").workFailureKind ==
                .invalidInput
        )
        #expect(
            LombScargleValidationError.failed(validation).workFailureKind ==
                .workloadValidation
        )
    }

    @Test func lombScargleUsesGenericPayload() throws {
        let unit = workUnit(
            payload: .object([
                "frequencyStartIndex": .number(40),
                "startFrequency": .number(0.25),
                "frequencyStep": .number(0.01),
                "frequencyCount": .number(20)
            ]),
            legacyStartFrequency: 99
        )

        let payload = try LombScargleWorker.workPayload(from: unit)

        #expect(payload.frequencyStartIndex == 40)
        #expect(payload.startFrequency == 0.25)
        #expect(payload.frequencyStep == 0.01)
        #expect(payload.frequencyCount == 20)
    }

    @Test func lombScargleSupportsExistingLegacyFields() throws {
        let unit = workUnit(
            payload: nil,
            legacyStartFrequency: 0.5
        )

        let payload = try LombScargleWorker.workPayload(from: unit)

        #expect(payload.frequencyStartIndex == 12)
        #expect(payload.startFrequency == 0.5)
        #expect(payload.frequencyStep == 0.02)
        #expect(payload.frequencyCount == 30)
    }

    @Test func lombScargleRejectsMalformedGenericPayloadRatherThanUsingLegacy() {
        let unit = workUnit(
            payload: .array([]),
            legacyStartFrequency: 0.5
        )

        #expect(throws: LombScargleError.self) {
            try LombScargleWorker.workPayload(from: unit)
        }
    }

    @Test func lombScargleRejectsUnsafeGridDimensions() {
        let unit = workUnit(
            payload: .object([
                "frequencyStartIndex": .number(-1),
                "startFrequency": .number(0.25),
                "frequencyStep": .number(0.01),
                "frequencyCount": .number(20)
            ]),
            legacyStartFrequency: nil
        )

        #expect(throws: LombScargleError.self) {
            try LombScargleWorker.workPayload(from: unit)
        }
    }

    @Test
    func lombScarglePreparedDatasetCacheReusesAndEvictsByScopedID() async throws {
        let worker = try LombScargleWorker(preparedDatasetCacheCapacity: 2)
        let data = Data(
            #"{"coordinates":[0,1,2,3,4,5],"values":[0,1,0,-1,0,1]}"#.utf8
        )
        let payload: JSONValue = .object([
            "frequencyStartIndex": .number(0),
            "startFrequency": .number(0.05),
            "frequencyStep": .number(0.01),
            "frequencyCount": .number(20)
        ])

        let first = try await worker.execute(
            workUnit: scopedWorkUnit(
                projectID: "a", datasetID: "shared", payload: payload
            ),
            datasetData: data
        )
        let initial = worker.preparedDatasetDebugState(
            projectID: "a", datasetID: "shared"
        )
        let repeated = try await worker.execute(
            workUnit: scopedWorkUnit(
                projectID: "a", datasetID: "shared", payload: payload
            ),
            datasetData: data
        )
        let reused = worker.preparedDatasetDebugState(
            projectID: "a", datasetID: "shared"
        )
        let values: [Float] = [0, 1, 0, -1, 0, 1]
        let sequentialTotalValueSquared = values.reduce(Float(0)) {
            $0 + $1 * $1
        }

        #expect(initial.coordinateBuffer == reused.coordinateBuffer)
        #expect(initial.valueBuffer == reused.valueBuffer)
        #expect(initial.totalValueSquared == sequentialTotalValueSquared)
        #expect(initial.totalValueSquared == reused.totalValueSquared)
        #expect(reused.preparations == 1)
        #expect(
            first.legacyResultFields.bestPower ==
                repeated.legacyResultFields.bestPower
        )

        _ = try await worker.execute(
            workUnit: scopedWorkUnit(
                projectID: "b", datasetID: "shared", payload: payload
            ),
            datasetData: data
        )
        let otherProject = worker.preparedDatasetDebugState(
            projectID: "b", datasetID: "shared"
        )
        #expect(otherProject.coordinateBuffer != initial.coordinateBuffer)

        _ = try await worker.execute(
            workUnit: scopedWorkUnit(
                projectID: "b", datasetID: "different", payload: payload
            ),
            datasetData: data
        )
        #expect(worker.preparedDatasetDebugState(
            projectID: "a", datasetID: "shared"
        ).coordinateBuffer == nil)
        #expect(otherProject.count == 2)

        _ = try await worker.execute(
            workUnit: scopedWorkUnit(
                projectID: "a", datasetID: "shared", payload: payload
            ),
            datasetData: data
        )
        let rebuilt = worker.preparedDatasetDebugState(
            projectID: "a", datasetID: "shared"
        )
        #expect(rebuilt.coordinateBuffer != nil)
        #expect(rebuilt.totalValueSquared == initial.totalValueSquared)
        #expect(rebuilt.count == 2)
        #expect(rebuilt.preparations == 4)
    }

    @Test func fusedBatchReportsSharedTimingExactlyOnceAcrossChildren() async throws {
        let worker = try LombScargleWorker()
        let data = Data(
            #"{"coordinates":[0,1,2,3,4,5],"values":[0,1,0,-1,0,1]}"#.utf8
        )
        var startIndex = 0
        let counts = [10, 10, 3]
        let units = counts.map { count -> WorkUnit in
            defer { startIndex += count }
            return scopedWorkUnit(
                projectID: "timing", datasetID: "shared",
                payload: .object([
                    "frequencyStartIndex": .number(Double(startIndex)),
                    "startFrequency": .number(0.05 + Double(startIndex) * 0.01),
                    "frequencyStep": .number(0.01),
                    "frequencyCount": .number(Double(count))
                ])
            )
        }
        let members = try await worker.executeBatch(
            workUnits: units, datasetData: data
        )
        let executions = try members.map { try $0.result.get() }
        let payloads = try executions.map { try #require($0.payload.objectValue) }
        let childMetal = payloads.compactMap {
            $0["metalDurationSeconds"]?.doubleValue
        }
        let childPreparation = payloads.compactMap {
            $0["datasetPreparationDurationSeconds"]?.doubleValue
        }
        let fusedMetal = try #require(
            payloads.first?["fusedDispatchMetalDurationSeconds"]?.doubleValue
        )
        let fusedTotal = try #require(
            payloads.first?["fusedGroupWorkloadDurationSeconds"]?.doubleValue
        )
        let fusedPreparation = try #require(
            payloads.first?["fusedDatasetPreparationDurationSeconds"]?.doubleValue
        )
        #expect(abs(childMetal.reduce(0, +) - fusedMetal) < 1e-12)
        #expect(abs(executions.map(\.duration).reduce(0, +) - fusedTotal) < 1e-12)
        #expect(abs(childPreparation.reduce(0, +) - fusedPreparation) < 1e-12)
        #expect(childMetal[2] < childMetal[0])
        #expect(executions[2].duration < executions[0].duration)
    }

    @Test func lombScargleRejectsZeroNormalizationDataset() async throws {
        let worker = try LombScargleWorker()

        await #expect(throws: LombScargleError.self) {
            try await worker.execute(
                workUnit: scopedWorkUnit(
                    projectID: "project",
                    datasetID: "zero",
                    payload: .object([
                        "startFrequency": .number(0.1),
                        "frequencyStep": .number(0.01),
                        "frequencyCount": .number(2)
                    ])
                ),
                datasetData: Data(
                    #"{"coordinates":[0,1],"values":[0,0]}"#.utf8
                )
            )
        }
    }

    @Test func lombScargleExecutionStillHonorsCancellation() async throws {
        let worker = try LombScargleWorker()

        let task = Task {
            try await worker.execute(
                workUnit: scopedWorkUnit(
                    projectID: "project",
                    datasetID: "dataset",
                    payload: .object([
                        "startFrequency": .number(0.1),
                        "frequencyStep": .number(0.01),
                        "frequencyCount": .number(2)
                    ])
                ),
                datasetData: Data(
                    #"{"coordinates":[0,1],"values":[0,1]}"#.utf8
                )
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled Lomb-Scargle execution to fail")
        } catch {
            #expect(
                error is CancellationError ||
                error is WorkloadCancellation
            )
            #expect(
                classifyWorkFailure(error) == .environmentUnavailable
            )
        }
    }

    @Test func workloadRouterSelectsHandlerByExactID() async throws {
        let router = try WorkloadRouter(
            handlers: [
                StubHandler(workloadID: "alpha"),
                StubHandler(workloadID: "beta")
            ]
        )

        let execution = try await router.execute(
            workUnit: workUnit(
                workloadID: "beta",
                payload: nil,
                legacyStartFrequency: nil
            ),
            datasetData: nil
        )

        #expect(execution.payload == .string("beta"))
    }

    @Test func workloadRouterRejectsDuplicateIDs() {
        #expect(throws: WorkloadRouterError.self) {
            try WorkloadRouter(
                handlers: [
                    StubHandler(workloadID: "duplicate"),
                    StubHandler(workloadID: "duplicate")
                ]
            )
        }
    }

    @Test func projectScopedDatasetAndStatusPathsEncodeIdentifiers() async throws {
        let recorder = RequestRecorder { request in
            switch request.url.flatMap({
                URLComponents(
                    url: $0,
                    resolvingAgainstBaseURL: false
                )?.percentEncodedPath
            }) {
            case "/v1/projects/project%20a/datasets/data%2Fset":
                return (Data("scoped".utf8), 200)
            case "/v1/projects/project%20a/status",
                 "/v1/projects/current/status":
                return (Self.statusData, 200)
            default:
                return (Data(), 404)
            }
        }
        let client = coordinatorClient(recorder: recorder)

        let data = try await client.datasetData(
            projectID: "project a",
            datasetID: "data/set"
        )
        _ = try await client.projectStatus(projectID: "project a")
        _ = try await client.projectStatus()

        #expect(data == Data("scoped".utf8))
        #expect(recorder.paths == [
            "/v1/projects/project%20a/datasets/data%2Fset",
            "/v1/projects/project%20a/status",
            "/v1/projects/current/status"
        ])
    }

    @MainActor
    @Test func datasetCacheIsScopedByProject() async throws {
        let recorder = RequestRecorder { request in
            let path = request.url!.path
            return (Data(path.utf8), 200)
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: [])
        )

        let first = try await manager.datasetData(
            projectID: "project-a",
            datasetID: "dataset-x"
        )
        let second = try await manager.datasetData(
            projectID: "project-b",
            datasetID: "dataset-x"
        )
        let cached = try await manager.datasetData(
            projectID: "project-a",
            datasetID: "dataset-x"
        )

        #expect(first != second)
        #expect(cached == first)
        #expect(recorder.paths.count == 2)
    }

    @MainActor
    @Test func rawDatasetCacheEvictsLeastRecentlyUsedEntry() async throws {
        let recorder = RequestRecorder { request in
            (Data(request.url!.path.utf8), 200)
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: [])
        )

        for index in 0..<4 {
            _ = try await manager.datasetData(
                projectID: "project", datasetID: "dataset-\(index)"
            )
        }
        _ = try await manager.datasetData(
            projectID: "project", datasetID: "dataset-0"
        )
        _ = try await manager.datasetData(
            projectID: "project", datasetID: "dataset-4"
        )
        _ = try await manager.datasetData(
            projectID: "project", datasetID: "dataset-1"
        )

        #expect(recorder.paths.count == 6)
    }

    @MainActor
    @Test func completedDisplayedProjectDoesNotPreventClaim() async throws {
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (
                    Data(#"{"accepted":true,"message":"ok"}"#.utf8),
                    200
                )
            case ("GET", "/v1/projects/current/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                return (Data(), 204)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: []),
            projectStatusRefreshInterval: .milliseconds(20)
        )

        manager.start()
        try await Task.sleep(for: .milliseconds(200))
        manager.stop()

        #expect(recorder.paths.contains("/v1/work/claim"))
    }

    @MainActor
    @Test func contributionStartRequestsBackgroundSupportOnlyOnce() async throws {
        let background = StubBackgroundContributionSession()
        let manager = ContributionManager(
            coordinator: idleCoordinator(),
            workloadRouter: try WorkloadRouter(handlers: []),
            backgroundSession: background
        )

        manager.start()
        manager.start()
        #expect(background.submissions == 1)
        manager.stop()
    }

    @MainActor
    @Test func unavailableBackgroundSupportLeavesForegroundWorkerRunning() throws {
        let background = StubBackgroundContributionSession(submitResult: false)
        let manager = ContributionManager(
            coordinator: idleCoordinator(),
            workloadRouter: try WorkloadRouter(handlers: []),
            backgroundSession: background
        )

        manager.start()
        #expect(manager.isContributing)
        #expect(background.submissions == 1)
        manager.stop()
    }

    @MainActor
    @Test func backgroundExpirationAndUserStopCleanUpTheSameWorker() async throws {
        let background = StubBackgroundContributionSession()
        let manager = ContributionManager(
            coordinator: idleCoordinator(),
            workloadRouter: try WorkloadRouter(handlers: []),
            backgroundSession: background
        )

        manager.start()

        let firstTask = StubBackgroundContributionTask(
            identifier: try #require(background.lastSubmittedIdentifier)
        )
        let firstIdentifier = firstTask.identifier

        manager.attachBackgroundTask(firstTask)
        firstTask.expirationHandler?()

        try await waitUntil {
            !manager.isContributing
                && background.cancellations == 1
                && firstTask.completions == [false]
        }

        #expect(!manager.isContributing)
        #expect(background.cancellations == 1)
        #expect(firstTask.completions == [false])

        // stop() cancels the contribution Task immediately, but that Task clears
        // ContributionManager.task only when its async cleanup finishes.
        // start() safely does nothing while the old Task still exists, so retry
        // until the next session is actually submitted.
        for _ in 0..<100 {
            manager.start()

            if background.submissions == 2 {
                break
            }

            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(background.submissions == 2)

        let secondTask = StubBackgroundContributionTask(
            identifier: try #require(background.lastSubmittedIdentifier)
        )

        #expect(secondTask.identifier != firstIdentifier)

        manager.attachBackgroundTask(secondTask)
        manager.stop()

        #expect(background.cancellations == 2)
        #expect(secondTask.completions == [false])
    }

    @MainActor
    @Test func backgroundIdentifiersMatchWildcardAndAreUnique() {
        let first = BackgroundContributionIdentifiers.session(UUID())
        let second = BackgroundContributionIdentifiers.session(UUID())

        #expect(
            BackgroundContributionIdentifiers.permitted ==
                "com.openstar.OpenStar.contribution.*"
        )
        #expect(first.hasPrefix("com.openstar.OpenStar.contribution."))
        #expect(second.hasPrefix("com.openstar.OpenStar.contribution."))
        #expect(first != second)
    }

    #if !os(iOS)
    @MainActor
    @Test func unsupportedPlatformUsesForegroundOnlyBackgroundSession() throws {
        let session = BackgroundContributionSession()
        #expect(!session.register { _ in })
        #expect(try session.submit() == nil)
        session.cancel()
    }
    #endif

    @MainActor
    @Test func failedProjectStatusDoesNotPreventNextClaim() async throws {
        let workID = UUID()
        let workData = Data(
            """
            {"id":"\(workID.uuidString)","projectID":"removed-project","workloadID":"unsupported"}
            """.utf8
        )
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (
                    Data(#"{"accepted":true,"message":"ok"}"#.utf8),
                    200
                )
            case ("GET", "/v1/projects/current/status"):
                return (Self.statusData, 200)
            case ("GET", "/v1/projects/removed-project/status"):
                return (Data("project removed".utf8), 404)
            case ("POST", "/v1/work/claim"):
                return (workData, 200)
            case ("POST", let path?) where path.hasSuffix("/result"):
                return (
                    Data(#"{"accepted":true,"message":"recorded"}"#.utf8),
                    200
                )
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: []),
            projectStatusRefreshInterval: .milliseconds(20)
        )

        manager.start()
        defer { manager.stop() }

        for _ in 0..<20 {
            if recorder.paths.filter({ $0 == "/v1/work/claim" }).count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let paths = recorder.paths
        let failedStatusIndex = try #require(
            paths.firstIndex(of: "/v1/projects/removed-project/status")
        )
        let laterClaimIndex = try #require(
            paths[(failedStatusIndex + 1)...]
                .firstIndex(of: "/v1/work/claim")
        )
        #expect(laterClaimIndex > failedStatusIndex)
        #expect(manager.currentProject == "removed-project")
        #expect(manager.projectStatus?.projectID == "display")
        #expect(manager.isContributing)
    }

    @MainActor
    @Test func acceptedResultClaimsNextUnitWithoutStatusOnHotPath() async throws {
        let claims = LockedCounter()
        let first = UUID()
        let second = UUID()
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (Data(#"{"accepted":true,"message":"ok"}"#.utf8), 200)
            case ("GET", let path?) where path.hasSuffix("/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                let number = claims.increment()
                guard number <= 2 else { return (Data(), 204) }
                let id = number == 1 ? first : second
                return (Self.workData(id: id), 200)
            case ("POST", let path?) where path.hasSuffix("/result"):
                return (Data(#"{"accepted":true,"message":"recorded"}"#.utf8), 200)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(
                handlers: [StubHandler(workloadID: "test")]
            ),
            projectStatusRefreshInterval: .seconds(60)
        )

        manager.start()
        defer { manager.stop() }
        try await waitUntil { manager.unitsAccepted == 2 }

        let paths = recorder.paths
        let firstResult = try #require(
            paths.firstIndex(where: { $0.hasSuffix("/result") })
        )
        let nextClaim = try #require(
            paths[(firstResult + 1)...].firstIndex(of: "/v1/work/claim")
        )
        #expect(
            !paths[(firstResult + 1)..<nextClaim]
                .contains(where: { $0.hasSuffix("/status") })
        )
    }

    @MainActor
    @Test func datasetFailureAfterBatchClaimAccountsForEveryChild() async throws {
        let ids = (0..<3).map { _ in UUID() }
        let claims = LockedCounter()
        let batch = Data(("[" + ids.map {
            "{\"id\":\"\($0.uuidString)\",\"projectID\":\"project\","
                + "\"workloadID\":\"batch\",\"datasetID\":\"missing\"}"
        }.joined(separator: ",") + "]").utf8)
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (Data(#"{"accepted":true,"message":"ok"}"#.utf8), 200)
            case ("GET", let path?) where path.hasSuffix("/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                return claims.increment() == 1 ? (batch, 200) : (Data(), 204)
            case ("GET", let path?) where path.hasSuffix("/datasets/missing"):
                return (Data("unavailable".utf8), 503)
            case ("POST", let path?) where path.hasSuffix("/result"):
                return (Data(#"{"accepted":true,"message":"recorded"}"#.utf8), 200)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: [PartialBatchHandler()]),
            projectStatusRefreshInterval: .seconds(60)
        )
        manager.start()
        defer { manager.stop() }
        try await waitUntil { manager.unitsAccepted == ids.count }

        let results = recorder.bodies.compactMap {
            try? JSONDecoder().decode(WorkResult.self, from: $0)
        }
        #expect(Set(results.map(\.workUnitID)) == Set(ids))
        #expect(results.allSatisfy { $0.failureKind == .transportUnavailable })
    }

    @MainActor
    @Test func failedChildSubmissionDoesNotSuppressLaterSiblings() async throws {
        let ids = (0..<3).map { _ in UUID() }
        let claims = LockedCounter()
        let batch = Data(("[" + ids.map {
            "{\"id\":\"\($0.uuidString)\",\"projectID\":\"project\","
                + "\"workloadID\":\"batch\"}"
        }.joined(separator: ",") + "]").utf8)
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (Data(#"{"accepted":true,"message":"ok"}"#.utf8), 200)
            case ("GET", let path?) where path.hasSuffix("/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                return claims.increment() == 1 ? (batch, 200) : (Data(), 204)
            case ("POST", let path?) where path.contains(ids[0].uuidString):
                return (Data("rejected".utf8), 400)
            case ("POST", let path?) where path.hasSuffix("/result"):
                return (Data(#"{"accepted":true,"message":"recorded"}"#.utf8), 200)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: [PartialBatchHandler()]),
            projectStatusRefreshInterval: .seconds(60)
        )
        manager.start()
        defer { manager.stop() }
        try await waitUntil {
            recorder.paths.filter { $0.hasSuffix("/result") }.count == ids.count
        }
        let resultPaths = recorder.paths.filter { $0.hasSuffix("/result") }
        #expect(ids.allSatisfy { id in
            resultPaths.contains { $0.contains(id.uuidString) }
        })
    }

    @MainActor
    @Test func emptyClaimBackoffGrowsAndResetsAfterWork() async throws {
        let claims = LockedCounter()
        let sleeps = DurationRecorder()
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (Data(#"{"accepted":true,"message":"ok"}"#.utf8), 200)
            case ("GET", let path?) where path.hasSuffix("/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                switch claims.increment() {
                case 1, 2, 4: return (Data(), 204)
                case 3: return (Self.workData(id: UUID()), 200)
                default: return (Data(), 204)
                }
            case ("POST", let path?) where path.hasSuffix("/result"):
                return (Data(#"{"accepted":true,"message":"recorded"}"#.utf8), 200)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(
                handlers: [StubHandler(workloadID: "test")]
            ),
            emptyClaimSleep: { duration in
                sleeps.append(duration)
                try Task.checkCancellation()
                await Task.yield()
            }
        )

        manager.start()
        defer { manager.stop() }
        try await waitUntil { sleeps.values.count >= 3 }

        #expect(Array(sleeps.values.prefix(3)) == [
            .milliseconds(25), .milliseconds(50), .milliseconds(25)
        ])
    }

    @MainActor
    @Test func projectStatusRefreshesPeriodicallyAndStopCancelsPolling() async throws {
        let recorder = RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (Data(#"{"accepted":true,"message":"ok"}"#.utf8), 200)
            case ("GET", let path?) where path.hasSuffix("/status"):
                return (Self.statusData, 200)
            case ("POST", "/v1/work/claim"):
                return (Data(), 204)
            default:
                return (Data(), 404)
            }
        }
        let manager = ContributionManager(
            coordinator: coordinatorClient(recorder: recorder),
            workloadRouter: try WorkloadRouter(handlers: []),
            projectStatusRefreshInterval: .milliseconds(20),
            initialEmptyClaimBackoff: .seconds(5),
            maximumEmptyClaimBackoff: .seconds(5)
        )

        manager.start()
        try await waitUntil {
            recorder.paths.filter { $0.hasSuffix("/status") }.count >= 2
        }
        #expect(manager.projectStatus?.projectID == "display")

        manager.stop()
        try await waitUntil { !manager.isContributing }
        try await Task.sleep(for: .milliseconds(50))
        let countAfterStop = recorder.paths.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.paths.count == countAfterStop)
    }
    
    @Test func adaptiveBatchControllerWaitsBeforeRegrowingAfterShrink() {
        let controller = AdaptiveBatchController()

        for _ in 0..<7 {
            _ = controller.observe(metalDuration: 0.005)
        }
        #expect(controller.desiredBatchCount == 128)

        _ = controller.observe(metalDuration: 0.068)
        #expect(controller.desiredBatchCount == 128)

        _ = controller.observe(metalDuration: 0.069)
        #expect(controller.desiredBatchCount == 64)

        for _ in 0..<8 {
            _ = controller.observe(metalDuration: 0.020)
            #expect(controller.desiredBatchCount == 64)
        }

        for _ in 0..<10 {
            _ = controller.observe(metalDuration: 0.020)
            if controller.desiredBatchCount > 64 {
                break
            }
        }

        #expect(controller.desiredBatchCount == 128)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for worker state")
    }

    private static func workData(id: UUID) -> Data {
        Data(
            #"{"id":"\#(id.uuidString)","projectID":"project","workloadID":"test"}"#.utf8
        )
    }

    private static let statusData = Data(
        #"{"projectID":"display","workloadID":"test","totalWorkUnits":1,"pendingWorkUnits":0,"assignedWorkUnits":0,"completedWorkUnits":1,"retryCount":0}"#.utf8
    )

    private func coordinatorClient(
        recorder: RequestRecorder
    ) -> CoordinatorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecorderURLProtocol.self]
        RecorderURLProtocol.recorder = recorder
        return CoordinatorClient(
            baseURL: URL(string: "https://coordinator.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func idleCoordinator() -> CoordinatorClient {
        coordinatorClient(recorder: RequestRecorder { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/nodes/register"):
                return (Data(#"{"accepted":true,"message":"ok"}"#.utf8), 200)
            case ("POST", "/v1/work/claim"):
                return (Data(), 204)
            case ("GET", let path?) where path.hasSuffix("/status"):
                return (Self.statusData, 200)
            default:
                return (Data(), 404)
            }
        })
    }

    private func workUnit(
        workloadID: String = LombScargleWorker.workloadID,
        payload: JSONValue?,
        legacyStartFrequency: Double?
    ) -> WorkUnit {
        WorkUnit(
            id: workID,
            projectID: "project",
            workloadID: workloadID,
            datasetID: "dataset",
            payload: payload,
            frequencyStartIndex: 12,
            startFrequency: legacyStartFrequency,
            frequencyStep: 0.02,
            frequencyCount: 30
        )
    }

    private func scopedWorkUnit(
        projectID: String,
        datasetID: String,
        payload: JSONValue
    ) -> WorkUnit {
        WorkUnit(
            id: UUID(),
            projectID: projectID,
            workloadID: LombScargleWorker.workloadID,
            datasetID: datasetID,
            payload: payload,
            frequencyStartIndex: nil,
            startFrequency: nil,
            frequencyStep: nil,
            frequencyCount: nil
        )
    }
}

@MainActor
private final class StubBackgroundContributionSession:
    BackgroundContributionSessionSupporting {
    private let submitResult: Bool
    private(set) var registrations = 0
    private(set) var submissions = 0
    private(set) var cancellations = 0
    private(set) var lastSubmittedIdentifier: String?

    init(submitResult: Bool = true) {
        self.submitResult = submitResult
    }

    func register(
        launchHandler: @escaping (BackgroundContributionTask) -> Void
    ) -> Bool {
        registrations += 1
        return registrations == 1
    }

    func submit() throws -> String? {
        submissions += 1
        guard submitResult else { return nil }
        let identifier = BackgroundContributionIdentifiers.session(UUID())
        lastSubmittedIdentifier = identifier
        return identifier
    }

    func cancel() {
        cancellations += 1
    }
}

@MainActor
private final class StubBackgroundContributionTask: BackgroundContributionTask {
    let identifier: String
    var expirationHandler: (() -> Void)?
    private(set) var acceptedCounts: [Int] = []
    private(set) var completions: [Bool] = []

    init(identifier: String) {
        self.identifier = identifier
    }

    func recordAcceptedWork(unitsAccepted: Int) {
        acceptedCounts.append(unitsAccepted)
    }

    func complete(success: Bool) {
        expirationHandler = nil
        completions.append(success)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let response: (URLRequest) -> (Data, Int)
    private var recordedPaths: [String] = []
    private var recordedBodies: [Data] = []

    init(response: @escaping (URLRequest) -> (Data, Int)) {
        self.response = response
    }

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    var bodies: [Data] {
        lock.withLock { recordedBodies }
    }

    func handle(_ request: URLRequest) -> (Data, Int) {
        let body = bodyData(from: request)

        lock.withLock {
            if let body {
                recordedBodies.append(body)
            }

            recordedPaths.append(
                URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )!.percentEncodedPath
            )
        }

        return response(request)
    }

    private func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = buffer.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }

                return stream.read(
                    baseAddress,
                    maxLength: buffer.count
                )
            }

            if count < 0 {
                return nil
            }

            if count == 0 {
                break
            }

            data.append(contentsOf: buffer[..<count])
        }

        return data
    }
}

private func error(_ description: String) -> NSError {
    NSError(
        domain: "OpenStarTests.Metal",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Duration] = []

    var values: [Duration] {
        lock.withLock { recordedValues }
    }

    func append(_ duration: Duration) {
        lock.withLock { recordedValues.append(duration) }
    }
}

private final class RecorderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: RequestRecorder!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    override func startLoading() {
        let (data, status) = Self.recorder.handle(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct StubHandler: OpenStarWorkloadHandler {
    let workloadIDs: [String]
    let capabilities: [WorkloadCapability]

    init(workloadID: String) {
        workloadIDs = [workloadID]
        capabilities = [
            WorkloadCapability(
                workloadID: workloadID,
                executionBackends: [.cpu],
                validatorID: nil
            )
        ]
    }

    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        WorkloadExecution(
            duration: 0,
            payload: .string(workUnit.workloadID),
            summary: nil,
            legacyResultFields: .none
        )
    }
}

private struct PartialBatchHandler: OpenStarBatchWorkloadHandler {
    let workloadIDs = ["batch"]
    let capabilities = [
        WorkloadCapability(
            workloadID: "batch", executionBackends: [.cpu], validatorID: nil
        )
    ]
    let desiredBatchCount = 16

    func execute(
        workUnit: WorkUnit, datasetData: Data?
    ) async throws -> WorkloadExecution {
        WorkloadExecution(
            duration: 0, payload: .string("complete"), summary: nil,
            legacyResultFields: .none
        )
    }

    func executeBatch(
        workUnits: [WorkUnit], datasetData: Data?
    ) async throws -> [WorkloadBatchMember] {
        guard let first = workUnits.first else { return [] }
        return [
            WorkloadBatchMember(
                workUnit: first,
                result: .success(try await execute(
                    workUnit: first, datasetData: datasetData
                ))
            )
        ]
    }
}
