//
//  LombScargleWorker.swift
//  OpenStar
//
//  Domain/workload plugin for Lomb-Scargle period-search work.
//  OpenStar Core routes this workload but does not understand its payload.
//

import Foundation
import Metal

nonisolated
struct LombScargleDataset: Codable, Sendable {
    let id: String?
    let coordinates: [Float]
    let values: [Float]

    private enum CodingKeys: String, CodingKey {
        case id, coordinates, values, times, flux
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .id)
        coordinates = try Self.decodeArray(
            from: container,
            genericKey: .coordinates,
            legacyKey: .times
        )
        values = try Self.decodeArray(
            from: container,
            genericKey: .values,
            legacyKey: .flux
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(coordinates, forKey: .coordinates)
        try container.encode(values, forKey: .values)
    }

    private static func decodeArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        genericKey: CodingKeys,
        legacyKey: CodingKeys
    ) throws -> [Float] {
        if container.contains(genericKey) {
            return try container.decode([Float].self, forKey: genericKey)
        }

        return try container.decode([Float].self, forKey: legacyKey)
    }
}

nonisolated
struct LombScargleWorkPayload: Sendable {
    let frequencyStartIndex: Int
    let startFrequency: Float
    let frequencyStep: Float
    let frequencyCount: Int
}

nonisolated
final class AdaptiveBatchController: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 1
    private var smoothedDuration: Double?
    private var consecutiveOverruns = 0
    private var growthCooldown = 0

    var desiredBatchCount: Int { lock.withLock { count } }

    @discardableResult
    func observe(metalDuration: Double) -> Int {
        lock.withLock {
            guard metalDuration.isFinite, metalDuration >= 0 else { return count }

            if metalDuration > 0.075 {
                count = max(count / 2, 1)
                smoothedDuration = metalDuration
                consecutiveOverruns = 0
                growthCooldown = 8
                return count
            }

            if metalDuration > 0.060 {
                consecutiveOverruns += 1

                if consecutiveOverruns >= 2 {
                    count = max(count / 2, 1)
                    smoothedDuration = metalDuration
                    consecutiveOverruns = 0
                    growthCooldown = 8
                }

                return count
            }

            consecutiveOverruns = 0

            let smoothed = smoothedDuration.map {
                $0 * 0.6 + metalDuration * 0.4
            } ?? metalDuration

            smoothedDuration = smoothed

            if metalDuration >= 0.035 {
                if growthCooldown > 0 {
                    growthCooldown -= 1
                }
                return count
            }

            if growthCooldown > 0 {
                growthCooldown -= 1
                return count
            }

            if smoothed < 0.035 {
                count = min(count * 2, 128)
            }

            return count
        }
    }
}

nonisolated
struct LombScargleBatchGroup: Sendable {
    let units: [WorkUnit]
    let payloads: [LombScargleWorkPayload]
}

nonisolated
enum LombScargleError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable
    case pipelineCreationFailed(Error)
    case missingDataset
    case invalidDataset
    case invalidWorkUnit(String)
    case bufferAllocationFailed
    case commandBufferUnavailable
    case encoderUnavailable
    case commandFailed(Error?)
    case noFiniteResult
    case validationFailed(LombScargleValidation)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal is unavailable."

        case .commandQueueUnavailable:
            return "Could not create Metal command queue."

        case .libraryUnavailable:
            return "Could not load Metal shader library."

        case .functionUnavailable:
            return "Could not find openStarLombScargle."

        case .pipelineCreationFailed(let error):
            return "Could not create Metal pipeline: \(error.localizedDescription)"

        case .missingDataset:
            return "The Lomb-Scargle workload requires a dataset."

        case .invalidDataset:
            return "The Lomb-Scargle dataset is invalid."

        case .invalidWorkUnit(let message):
            return "The Lomb-Scargle work unit is invalid: \(message)"

        case .bufferAllocationFailed:
            return "Could not allocate Metal buffers."

        case .commandBufferUnavailable:
            return "Could not create Metal command buffer."

        case .encoderUnavailable:
            return "Could not create Metal compute encoder."

        case .commandFailed(let error):
            return error?.localizedDescription ?? "Metal command failed."

        case .noFiniteResult:
            return "The period search produced no finite result."

        case .validationFailed(let validation):
            return validation.reason
        }
    }
}

nonisolated
final class LombScargleWorker: OpenStarBatchWorkloadHandler, @unchecked Sendable {
    // New domain-neutral workload name plus the existing project ID as a
    // compatibility alias. Both route to the same implementation.
    static let workloadID = "openstar.lomb-scargle.v1"
    static let legacyWorkloadID = "openstar.tess-period-search.v1"

    let workloadIDs = [
        LombScargleWorker.workloadID,
        LombScargleWorker.legacyWorkloadID
    ]

    let capabilities = [
        WorkloadCapability(
            workloadID: LombScargleWorker.workloadID,
            executionBackends: [.metal],
            validatorID: LombScargleValidation.validatorID
        ),
        WorkloadCapability(
            workloadID: LombScargleWorker.legacyWorkloadID,
            executionBackends: [.metal],
            validatorID: LombScargleValidation.validatorID
        )
    ]

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let preparedDatasets: PreparedDatasetCache
    private let batchController: AdaptiveBatchController

    var desiredBatchCount: Int { batchController.desiredBatchCount }

    private struct DatasetCacheKey: Hashable {
        let projectID: String
        let datasetID: String
    }

    private final class PreparedDataset: @unchecked Sendable {
        let coordinates: [Float]
        let values: [Float]
        let totalValueSquared: Float
        let coordinateBuffer: MTLBuffer
        let valueBuffer: MTLBuffer

        init(
            coordinates: [Float],
            values: [Float],
            totalValueSquared: Float,
            coordinateBuffer: MTLBuffer,
            valueBuffer: MTLBuffer
        ) {
            self.coordinates = coordinates
            self.values = values
            self.totalValueSquared = totalValueSquared
            self.coordinateBuffer = coordinateBuffer
            self.valueBuffer = valueBuffer
        }
    }

    private final class PreparedDatasetCache: @unchecked Sendable {
        private let capacity: Int
        private var values: [DatasetCacheKey: PreparedDataset] = [:]
        private var recency: [DatasetCacheKey] = []
        private var preparationCount = 0
        private let lock = NSLock()

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        func value(
            for key: DatasetCacheKey,
            prepare: () throws -> PreparedDataset
        ) rethrows -> PreparedDataset {
            lock.lock()
            defer { lock.unlock() }

            if let value = values[key] {
                touch(key)
                return value
            }

            let value = try prepare()
            preparationCount += 1
            if values.count == capacity, let oldest = recency.first {
                values.removeValue(forKey: oldest)
                recency.removeFirst()
            }
            values[key] = value
            recency.append(key)
            return value
        }

        private func touch(_ key: DatasetCacheKey) {
            recency.removeAll { $0 == key }
            recency.append(key)
        }

        func debugState(for key: DatasetCacheKey) -> (
            coordinateBuffer: ObjectIdentifier?,
            valueBuffer: ObjectIdentifier?,
            totalValueSquared: Float?,
            count: Int,
            preparations: Int
        ) {
            lock.lock()
            defer { lock.unlock() }
            let value = values[key]
            return (
                value.map { ObjectIdentifier($0.coordinateBuffer as AnyObject) },
                value.map { ObjectIdentifier($0.valueBuffer as AnyObject) },
                value?.totalValueSquared,
                values.count,
                preparationCount
            )
        }
    }

    init(
        preparedDatasetCacheCapacity: Int = 4,
        batchController: AdaptiveBatchController = AdaptiveBatchController()
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LombScargleError.metalUnavailable
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw LombScargleError.commandQueueUnavailable
        }

        guard let library = device.makeDefaultLibrary() else {
            throw LombScargleError.libraryUnavailable
        }

        guard let function = library.makeFunction(
            name: "openStarLombScargle"
        ) else {
            throw LombScargleError.functionUnavailable
        }

        do {
            pipeline = try device.makeComputePipelineState(
                function: function
            )
        } catch {
            throw LombScargleError.pipelineCreationFailed(error)
        }

        self.device = device
        self.commandQueue = commandQueue
        preparedDatasets = PreparedDatasetCache(
            capacity: preparedDatasetCacheCapacity
        )
        self.batchController = batchController
    }

    @concurrent
    func execute(
        workUnit: WorkUnit,
        datasetData: Data?
    ) async throws -> WorkloadExecution {
        let members = try await executeBatch(
            workUnits: [workUnit], datasetData: datasetData
        )
        guard let member = members.first else {
            throw LombScargleError.invalidWorkUnit("empty batch execution")
        }
        return try member.result.get()
    }

    @concurrent
    func executeBatch(
        workUnits: [WorkUnit],
        datasetData: Data?
    ) async throws -> [WorkloadBatchMember] {
        guard let datasetData else { throw LombScargleError.missingDataset }
        guard !workUnits.isEmpty else { return [] }

        var outcomes: [UUID: Result<WorkloadExecution, any Error>] = [:]
        for unit in workUnits {
            do { _ = try Self.workPayload(from: unit) }
            catch { outcomes[unit.id] = .failure(error) }
        }
        for group in Self.contiguousGroups(workUnits) {
            do {
                try Task.checkCancellation()
                let groupStarted = ProcessInfo.processInfo.systemUptime
                let preparationStarted = groupStarted
                let dataset = try preparedDataset(
                    workUnit: group.units[0], data: datasetData
                )
                let preparationDuration = ProcessInfo.processInfo.systemUptime
                    - preparationStarted
                let metal = try runMetalPowersSynchronously(
                    payloads: group.payloads, dataset: dataset
                )
                let next = batchController.observe(metalDuration: metal.duration)
                print(
                    "⭐️ [OpenStar] Metal batch units=\(group.units.count) "
                    + "frequencies=\(group.payloads.reduce(0) { $0 + $1.frequencyCount }) "
                    + String(format: "duration=%.4fs nextBatch=%d", metal.duration, next)
                )

                var offset = 0
                let childMetalDurations = Self.allocatedDurations(
                    total: metal.duration,
                    frequencyCounts: group.payloads.map(\.frequencyCount)
                )
                var validated: [UUID: ValidatedResult] = [:]
                for ((unit, payload), childMetalDuration) in zip(
                    zip(group.units, group.payloads), childMetalDurations
                ) {
                    do {
                        let slice = Array(metal.powers[offset..<(offset + payload.frequencyCount)])
                        let numerical = try Self.reduce(
                            powers: slice, payload: payload,
                            metalDuration: childMetalDuration
                        )
                        validated[unit.id] = try validate(
                            numerical: numerical, payload: payload, dataset: dataset
                        )
                    } catch {
                        outcomes[unit.id] = .failure(error)
                    }
                    offset += payload.frequencyCount
                }
                let groupDuration = ProcessInfo.processInfo.systemUptime - groupStarted
                let counts = group.payloads.map(\.frequencyCount)
                let childTotalDurations = Self.allocatedDurations(
                    total: groupDuration, frequencyCounts: counts
                )
                let childPreparationDurations = Self.allocatedDurations(
                    total: preparationDuration, frequencyCounts: counts
                )
                for (((unit, payload), totalDuration), childPreparation) in zip(
                    zip(zip(group.units, group.payloads), childTotalDurations),
                    childPreparationDurations
                ) {
                    guard let result = validated[unit.id] else { continue }
                    outcomes[unit.id] = .success(makeExecution(
                        validated: result, payload: payload,
                        totalDuration: totalDuration,
                        preparationDuration: childPreparation,
                        fusedMetalDuration: metal.duration,
                        fusedGroupDuration: groupDuration,
                        fusedPreparationDuration: preparationDuration
                    ))
                }
            } catch is CancellationError {
                // Preserve outcomes from earlier groups. This group and every
                // later group remain recoverable through no-penalty results.
                for unit in group.units where outcomes.index(forKey: unit.id) == nil {
                    outcomes[unit.id] = .failure(WorkloadCancellation())
                }
                break
            } catch {
                for unit in group.units { outcomes[unit.id] = .failure(error) }
            }
        }
        return workUnits.map {
            WorkloadBatchMember(
                workUnit: $0,
                result: outcomes[$0.id] ?? .failure(WorkloadCancellation())
            )
        }
    }

    static func contiguousGroups(_ units: [WorkUnit]) -> [LombScargleBatchGroup] {
        let parsed = units.compactMap { unit -> (WorkUnit, LombScargleWorkPayload)? in
            guard let payload = try? workPayload(from: unit) else { return nil }
            return (unit, payload)
        }.sorted { $0.1.frequencyStartIndex < $1.1.frequencyStartIndex }

        var groups: [LombScargleBatchGroup] = []
        for item in parsed {
            if let last = groups.last,
               let priorUnit = last.units.last,
               let prior = last.payloads.last,
               priorUnit.projectID == item.0.projectID,
               priorUnit.datasetID == item.0.datasetID,
               priorUnit.workloadID == item.0.workloadID,
               last.units.count < 128,
               prior.frequencyStartIndex + prior.frequencyCount == item.1.frequencyStartIndex,
               compatibleGrid(previous: prior, next: item.1) {
                groups[groups.count - 1] = LombScargleBatchGroup(
                    units: last.units + [item.0], payloads: last.payloads + [item.1]
                )
            } else {
                groups.append(.init(units: [item.0], payloads: [item.1]))
            }
        }
        return groups
    }

    private static func compatibleGrid(
        previous: LombScargleWorkPayload, next: LombScargleWorkPayload
    ) -> Bool {
        let stepTolerance = 4 * max(
            previous.frequencyStep.ulp,
            next.frequencyStep.ulp
        )
        guard abs(previous.frequencyStep - next.frequencyStep)
                <= stepTolerance else { return false }
        return true
    }

    /// Frequencies a fused dispatch evaluates, exposed for deterministic
    /// verification of the per-child Float32 execution invariant.
    static func fusedFrequencies(
        payloads: [LombScargleWorkPayload]
    ) -> [Float] {
        payloads.flatMap { payload in
            (0..<payload.frequencyCount).map {
                payload.startFrequency + Float($0) * payload.frequencyStep
            }
        }
    }

    static func allocatedDurations(
        total: Double, frequencyCounts: [Int]
    ) -> [Double] {
        guard !frequencyCounts.isEmpty else { return [] }
        let denominator = frequencyCounts.reduce(0, +)
        guard denominator > 0 else { return Array(repeating: 0, count: frequencyCounts.count) }
        var allocated: [Double] = []
        var used = 0.0
        for (index, count) in frequencyCounts.enumerated() {
            let value = index == frequencyCounts.count - 1
                ? total - used
                : total * Double(count) / Double(denominator)
            allocated.append(value)
            used += value
        }
        return allocated
    }

    static func workPayload(
        from workUnit: WorkUnit
    ) throws -> LombScargleWorkPayload {
        if let payload = workUnit.payload {
            guard let payloadObject = payload.objectValue else {
                throw LombScargleError.invalidWorkUnit(
                    "generic payload must be a JSON object"
                )
            }

            guard let startFrequency = payloadObject["startFrequency"]?.doubleValue,
                  let frequencyStep = payloadObject["frequencyStep"]?.doubleValue,
                  let frequencyCount = payloadObject["frequencyCount"]?.intValue else {
                throw LombScargleError.invalidWorkUnit(
                    "generic payload is missing startFrequency, frequencyStep, or frequencyCount"
                )
            }

            let startIndex =
                payloadObject["frequencyStartIndex"]?.intValue ?? 0

            return try validatedPayload(
                frequencyStartIndex: startIndex,
                startFrequency: startFrequency,
                frequencyStep: frequencyStep,
                frequencyCount: frequencyCount
            )
        }

        // v18 compatibility path. This goes away after all coordinators emit
        // workload parameters only inside WorkUnit.payload.
        guard let startFrequency = workUnit.startFrequency,
              let frequencyStep = workUnit.frequencyStep,
              let frequencyCount = workUnit.frequencyCount else {
            throw LombScargleError.invalidWorkUnit(
                "no generic payload or legacy frequency fields were supplied"
            )
        }

        return try validatedPayload(
            frequencyStartIndex: workUnit.frequencyStartIndex ?? 0,
            startFrequency: startFrequency,
            frequencyStep: frequencyStep,
            frequencyCount: frequencyCount
        )
    }

    private static func validatedPayload(
        frequencyStartIndex: Int,
        startFrequency: Double,
        frequencyStep: Double,
        frequencyCount: Int
    ) throws -> LombScargleWorkPayload {
        guard frequencyStartIndex >= 0,
              startFrequency.isFinite,
              frequencyStep.isFinite,
              startFrequency > 0,
              frequencyStep > 0,
              frequencyCount > 0 else {
            throw LombScargleError.invalidWorkUnit(
                "frequency grid is invalid"
            )
        }

        let startFrequencyFloat = Float(startFrequency)
        let frequencyStepFloat = Float(frequencyStep)
        let lastFrequency = startFrequency +
            Double(frequencyCount - 1) * frequencyStep

        guard startFrequencyFloat.isFinite,
              frequencyStepFloat.isFinite,
              lastFrequency.isFinite,
              Float(lastFrequency).isFinite,
              startFrequencyFloat > 0,
              frequencyStepFloat > 0 else {
            throw LombScargleError.invalidWorkUnit(
                "frequency grid cannot be represented by the Metal Float32 workload"
            )
        }

        return LombScargleWorkPayload(
            frequencyStartIndex: frequencyStartIndex,
            startFrequency: startFrequencyFloat,
            frequencyStep: frequencyStepFloat,
            frequencyCount: frequencyCount
        )
    }

    private struct MetalPowers {
        let duration: Double
        let powers: [Float]
    }

    private struct NumericalResult {
        let metalDuration: Double
        let bestIndex: Int
        let bestFrequency: Double
        let reciprocalFrequency: Double
        let bestPower: Double
    }

    private struct ValidatedResult {
        let numerical: NumericalResult
        let validation: LombScargleValidation
        let validationDuration: Double
    }

    private func preparedDataset(
        workUnit: WorkUnit,
        data: Data
    ) throws -> PreparedDataset {
        guard let datasetID = workUnit.datasetID else {
            return try prepareDataset(data)
        }

        let key = DatasetCacheKey(
            projectID: workUnit.projectID,
            datasetID: datasetID
        )
        return try preparedDatasets.value(for: key) {
            try prepareDataset(data)
        }
    }

    func preparedDatasetDebugState(
        projectID: String,
        datasetID: String
    ) -> (
        coordinateBuffer: ObjectIdentifier?,
        valueBuffer: ObjectIdentifier?,
        totalValueSquared: Float?,
        count: Int,
        preparations: Int
    ) {
        preparedDatasets.debugState(
            for: DatasetCacheKey(
                projectID: projectID,
                datasetID: datasetID
            )
        )
    }

    private func prepareDataset(_ data: Data) throws -> PreparedDataset {
        let dataset = try JSONDecoder().decode(
            LombScargleDataset.self,
            from: data
        )

        guard !dataset.coordinates.isEmpty,
              dataset.coordinates.count == dataset.values.count,
              dataset.coordinates.allSatisfy(\.isFinite),
              dataset.values.allSatisfy(\.isFinite) else {
            throw LombScargleError.invalidDataset
        }

        guard dataset.coordinates.count <= Int(UInt32.max),
              dataset.coordinates.count <=
                Int.max / MemoryLayout<Float>.stride else {
            throw LombScargleError.invalidWorkUnit(
                "input dimensions exceed the Metal workload limits"
            )
        }

        var totalValueSquared: Float = 0
        for value in dataset.values {
            totalValueSquared += value * value
        }
        guard totalValueSquared.isFinite,
              totalValueSquared > 0 else {
            throw LombScargleError.invalidDataset
        }

        let byteCount = dataset.coordinates.count * MemoryLayout<Float>.stride
        guard let coordinateBuffer = device.makeBuffer(
            bytes: dataset.coordinates,
            length: byteCount,
            options: .storageModeShared
        ), let valueBuffer = device.makeBuffer(
            bytes: dataset.values,
            length: byteCount,
            options: .storageModeShared
        ) else {
            throw LombScargleError.bufferAllocationFailed
        }

        return PreparedDataset(
            coordinates: dataset.coordinates,
            values: dataset.values,
            totalValueSquared: totalValueSquared,
            coordinateBuffer: coordinateBuffer,
            valueBuffer: valueBuffer
        )
    }

    private static func reduce(
        powers: [Float],
        payload: LombScargleWorkPayload,
        metalDuration: Double
    ) throws -> NumericalResult {
        guard let winner = powers.enumerated().filter({ $0.element.isFinite })
            .max(by: { $0.element < $1.element }) else {
            throw LombScargleError.noFiniteResult
        }
        let frequency = Double(payload.startFrequency)
            + Double(winner.offset) * Double(payload.frequencyStep)
        guard frequency.isFinite, frequency > 0 else {
            throw LombScargleError.noFiniteResult
        }
        return NumericalResult(
            metalDuration: metalDuration, bestIndex: winner.offset,
            bestFrequency: frequency, reciprocalFrequency: 1 / frequency,
            bestPower: Double(winner.element)
        )
    }

    private func validate(
        numerical: NumericalResult,
        payload: LombScargleWorkPayload,
        dataset: PreparedDataset
    ) throws -> ValidatedResult {
        let started = ProcessInfo.processInfo.systemUptime
        let validation = try LombScargleCPUValidator.validate(
            coordinates: dataset.coordinates, values: dataset.values,
            metalBestIndex: numerical.bestIndex,
            metalBestPower: numerical.bestPower,
            startFrequency: payload.startFrequency,
            frequencyStep: payload.frequencyStep,
            frequencyCount: payload.frequencyCount
        )
        guard validation.passed else {
            throw LombScargleError.validationFailed(validation)
        }
        return ValidatedResult(
            numerical: numerical,
            validation: validation,
            validationDuration: ProcessInfo.processInfo.systemUptime - started
        )
    }

    private func makeExecution(
        validated: ValidatedResult,
        payload: LombScargleWorkPayload,
        totalDuration: Double,
        preparationDuration: Double,
        fusedMetalDuration: Double,
        fusedGroupDuration: Double,
        fusedPreparationDuration: Double
    ) -> WorkloadExecution {
        let numerical = validated.numerical
        let validation = validated.validation
        let result: JSONValue = .object([
            "bestFrequency": .number(numerical.bestFrequency),
            "bestPeriodDays": .number(numerical.reciprocalFrequency),
            "bestPower": .number(numerical.bestPower),
            "bestFrequencyIndex": .number(Double(
                payload.frequencyStartIndex + numerical.bestIndex
            )),
            "metalDurationSeconds": .number(numerical.metalDuration),
            "datasetPreparationDurationSeconds": .number(preparationDuration),
            "totalWorkloadDurationSeconds": .number(totalDuration),
            "fusedDispatchMetalDurationSeconds": .number(fusedMetalDuration),
            "fusedGroupWorkloadDurationSeconds": .number(fusedGroupDuration),
            "fusedDatasetPreparationDurationSeconds": .number(
                fusedPreparationDuration
            ),
            "validation": .object([
                "validatorID": .string(LombScargleValidation.validatorID),
                "passed": .bool(true),
                "cpuBestLocalIndex": .number(Double(validation.cpuBestLocalIndex)),
                "cpuPowerAtMetalWinner": .number(validation.cpuPowerAtMetalWinner),
                "absolutePowerError": .number(validation.absolutePowerError),
                "allowedPowerError": .number(validation.allowedPowerError),
                "durationSeconds": .number(validated.validationDuration)
            ])
        ])
        return WorkloadExecution(
            duration: totalDuration, payload: result,
            summary: WorkloadResultSummary(
                title: "Lomb-Scargle Result",
                fields: [
                    .init(id: "frequency", label: "Frequency", value: String(format: "%.6f", numerical.bestFrequency)),
                    .init(id: "power", label: "Power", value: String(format: "%.6f", numerical.bestPower)),
                    .init(id: "validator", label: "Local Validation", value: "Passed")
                ]
            ),
            legacyResultFields: .init(
                bestFrequency: numerical.bestFrequency,
                bestPeriodDays: numerical.reciprocalFrequency,
                bestPower: numerical.bestPower
            )
        )
    }

    private func runMetalPowersSynchronously(
        payloads: [LombScargleWorkPayload],
        dataset: PreparedDataset
    ) throws -> MetalPowers {
        let sampleCount = dataset.coordinates.count
        let frequencyCount = payloads.reduce(0) { $0 + $1.frequencyCount }

        guard sampleCount <= Int(UInt32.max),
              !payloads.isEmpty, payloads.count <= 128,
              frequencyCount <= Int(UInt32.max),
              frequencyCount <= Int.max / MemoryLayout<Float>.stride,
              sampleCount <= Int.max / MemoryLayout<Float>.stride else {
            throw LombScargleError.invalidWorkUnit(
                "input dimensions exceed the Metal workload limits"
            )
        }

        let outputByteCount =
            frequencyCount * MemoryLayout<Float>.stride

        guard let powerBuffer = device.makeBuffer(
            length: outputByteCount,
            options: .storageModeShared
        ) else {
            throw LombScargleError.bufferAllocationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw LombScargleError.commandBufferUnavailable
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LombScargleError.encoderUnavailable
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(dataset.coordinateBuffer, offset: 0, index: 0)
        encoder.setBuffer(dataset.valueBuffer, offset: 0, index: 1)
        encoder.setBuffer(powerBuffer, offset: 0, index: 2)

        var gpuSampleCount = UInt32(sampleCount)
        var childStartFrequencies = payloads.map(\.startFrequency)
        var childFrequencySteps = payloads.map(\.frequencyStep)
        var cumulative = 0
        var childEndOffsets = payloads.map { payload -> UInt32 in
            cumulative += payload.frequencyCount
            return UInt32(cumulative)
        }
        var childCount = UInt32(payloads.count)
        var totalValueSquared = dataset.totalValueSquared

        encoder.setBytes(
            &gpuSampleCount,
            length: MemoryLayout<UInt32>.stride,
            index: 3
        )

        childStartFrequencies.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 4)
        }

        childFrequencySteps.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 5)
        }

        encoder.setBytes(
            &totalValueSquared,
            length: MemoryLayout<Float>.stride,
            index: 6
        )
        childEndOffsets.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 7)
        }
        encoder.setBytes(&childCount,
            length: MemoryLayout<UInt32>.stride, index: 8)

        let executionWidth = pipeline.threadExecutionWidth

        let threadgroupWidth = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            executionWidth * 4
        )

        encoder.dispatchThreads(
            MTLSize(
                width: frequencyCount,
                height: 1,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(
                width: threadgroupWidth,
                height: 1,
                depth: 1
            )
        )

        encoder.endEncoding()

        let started = ProcessInfo.processInfo.systemUptime

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let metalDuration =
            ProcessInfo.processInfo.systemUptime - started

        // Do not begin potentially expensive slicing, reduction, and CPU
        // validation after a user stop or background expiration.
        try Task.checkCancellation()

        guard commandBuffer.status == .completed else {
            throw LombScargleError.commandFailed(
                commandBuffer.error
            )
        }

        let pointer = powerBuffer.contents().bindMemory(
            to: Float.self, capacity: frequencyCount
        )
        return MetalPowers(
            duration: metalDuration,
            powers: Array(UnsafeBufferPointer(start: pointer, count: frequencyCount))
        )
    }
}
