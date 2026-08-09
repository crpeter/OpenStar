//
//  PeriodSearchResult.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  TESSPeriodSearchWorker.swift
//  OpenStar
//

import Foundation
import Metal

nonisolated
struct PeriodSearchResult: Sendable {
    let duration: Double
    let bestFrequency: Double
    let bestPeriodDays: Double
    let bestPower: Double
}

nonisolated
enum PeriodSearchError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable
    case pipelineCreationFailed(Error)
    case invalidDataset
    case invalidWorkUnit
    case bufferAllocationFailed
    case commandBufferUnavailable
    case encoderUnavailable
    case commandFailed(Error?)
    case noFiniteResult

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

        case .invalidDataset:
            return "The astronomy dataset is invalid."

        case .invalidWorkUnit:
            return "The period-search work unit is invalid."

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
        }
    }
}

nonisolated
final class TESSPeriodSearchWorker: @unchecked Sendable {
    static let workloadID = "openstar.tess-period-search.v1"

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PeriodSearchError.metalUnavailable
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw PeriodSearchError.commandQueueUnavailable
        }

        guard let library = device.makeDefaultLibrary() else {
            throw PeriodSearchError.libraryUnavailable
        }

        guard let function = library.makeFunction(
            name: "openStarLombScargle"
        ) else {
            throw PeriodSearchError.functionUnavailable
        }

        do {
            pipeline = try device.makeComputePipelineState(
                function: function
            )
        } catch {
            throw PeriodSearchError.pipelineCreationFailed(error)
        }

        self.device = device
        self.commandQueue = commandQueue
    }

    @concurrent
    func run(
        workUnit: WorkUnit,
        dataset: AstronomyDataset
    ) async throws -> PeriodSearchResult {
        try Task.checkCancellation()

        let result = try runSynchronously(
            workUnit: workUnit,
            dataset: dataset
        )

        try Task.checkCancellation()

        return result
    }

    private func runSynchronously(
        workUnit: WorkUnit,
        dataset: AstronomyDataset
    ) throws -> PeriodSearchResult {
        guard !dataset.times.isEmpty,
              dataset.times.count == dataset.flux.count else {
            throw PeriodSearchError.invalidDataset
        }

        guard workUnit.frequencyCount > 0,
              workUnit.frequencyStep > 0,
              workUnit.startFrequency > 0 else {
            throw PeriodSearchError.invalidWorkUnit
        }

        let sampleCount = dataset.times.count

        let timeByteCount =
            sampleCount * MemoryLayout<Float>.stride

        let outputByteCount =
            workUnit.frequencyCount * MemoryLayout<Float>.stride

        guard let timeBuffer = device.makeBuffer(
            bytes: dataset.times,
            length: timeByteCount,
            options: .storageModeShared
        ),
        let fluxBuffer = device.makeBuffer(
            bytes: dataset.flux,
            length: timeByteCount,
            options: .storageModeShared
        ),
        let powerBuffer = device.makeBuffer(
            length: outputByteCount,
            options: .storageModeShared
        ) else {
            throw PeriodSearchError.bufferAllocationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw PeriodSearchError.commandBufferUnavailable
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PeriodSearchError.encoderUnavailable
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(timeBuffer, offset: 0, index: 0)
        encoder.setBuffer(fluxBuffer, offset: 0, index: 1)
        encoder.setBuffer(powerBuffer, offset: 0, index: 2)

        var gpuSampleCount = UInt32(sampleCount)
        var startFrequency = workUnit.startFrequency
        var frequencyStep = workUnit.frequencyStep

        encoder.setBytes(
            &gpuSampleCount,
            length: MemoryLayout<UInt32>.stride,
            index: 3
        )

        encoder.setBytes(
            &startFrequency,
            length: MemoryLayout<Float>.stride,
            index: 4
        )

        encoder.setBytes(
            &frequencyStep,
            length: MemoryLayout<Float>.stride,
            index: 5
        )

        let executionWidth = pipeline.threadExecutionWidth

        let threadgroupWidth = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            executionWidth * 4
        )

        encoder.dispatchThreads(
            MTLSize(
                width: workUnit.frequencyCount,
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

        let duration =
            ProcessInfo.processInfo.systemUptime - started

        guard commandBuffer.status == .completed else {
            throw PeriodSearchError.commandFailed(
                commandBuffer.error
            )
        }

        let powers = powerBuffer.contents().bindMemory(
            to: Float.self,
            capacity: workUnit.frequencyCount
        )

        var bestIndex: Int?
        var bestPower = -Float.infinity

        for index in 0..<workUnit.frequencyCount {
            let power = powers[index]

            if power.isFinite && power > bestPower {
                bestPower = power
                bestIndex = index
            }
        }

        guard let bestIndex,
              bestPower.isFinite else {
            throw PeriodSearchError.noFiniteResult
        }

        let bestFrequency =
            Double(workUnit.startFrequency) +
            Double(bestIndex) *
            Double(workUnit.frequencyStep)

        return PeriodSearchResult(
            duration: duration,
            bestFrequency: bestFrequency,
            bestPeriodDays: 1.0 / bestFrequency,
            bestPower: Double(bestPower)
        )
    }
}