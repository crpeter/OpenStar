//
//  MetalBenchmarkResult 2.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  MetalComputeWorker.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import Foundation
import Metal

nonisolated
struct MetalBenchmarkResult: Sendable {
    let duration: Double
    let estimatedGFLOPS: Double
    let checksum: Double
    let verificationValue: Float
}

nonisolated
enum MetalComputeError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable
    case functionUnavailable
    case pipelineCreationFailed(Error)
    case invalidWorkUnit
    case bufferAllocationFailed
    case commandBufferUnavailable
    case encoderUnavailable
    case commandFailed(Error?)
    case verificationFailed(expected: Float, actual: Float)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal is unavailable."

        case .commandQueueUnavailable:
            return "Could not create Metal command queue."

        case .libraryUnavailable:
            return "Could not load Metal shader library."

        case .functionUnavailable:
            return "Could not find openStarBenchmark."

        case .pipelineCreationFailed(let error):
            return "Could not create Metal pipeline: \(error.localizedDescription)"

        case .invalidWorkUnit:
            return "The work unit contains invalid parameters."

        case .bufferAllocationFailed:
            return "Could not allocate Metal buffers."

        case .commandBufferUnavailable:
            return "Could not create Metal command buffer."

        case .encoderUnavailable:
            return "Could not create Metal compute encoder."

        case .commandFailed(let error):
            return error?.localizedDescription ?? "Metal command failed."

        case .verificationFailed(let expected, let actual):
            return "GPU verification failed. Expected \(expected), got \(actual)."
        }
    }
}

nonisolated
final class MetalComputeWorker: @unchecked Sendable {
    static let workloadID = "openstar.metal-benchmark.v1"

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalComputeError.metalUnavailable
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalComputeError.commandQueueUnavailable
        }

        guard let library = device.makeDefaultLibrary() else {
            throw MetalComputeError.libraryUnavailable
        }

        guard let function = library.makeFunction(
            name: "openStarBenchmark"
        ) else {
            throw MetalComputeError.functionUnavailable
        }

        let pipeline: MTLComputePipelineState

        do {
            pipeline = try device.makeComputePipelineState(
                function: function
            )
        } catch {
            throw MetalComputeError.pipelineCreationFailed(error)
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }

    @concurrent
    func run(
        workUnit: WorkUnit
    ) async throws -> MetalBenchmarkResult {
        try Task.checkCancellation()

        guard workUnit.elementCount > 0,
              workUnit.iterationsPerElement > 0,
              workUnit.elementCount <= 8_388_608,
              workUnit.iterationsPerElement <= 32_768 else {
            throw MetalComputeError.invalidWorkUnit
        }

        let result = try runSynchronously(
            elementCount: workUnit.elementCount,
            iterationsPerElement: workUnit.iterationsPerElement
        )

        try Task.checkCancellation()

        return result
    }

    private func runSynchronously(
        elementCount: Int,
        iterationsPerElement: Int
    ) throws -> MetalBenchmarkResult {
        let byteCount =
            elementCount *
            MemoryLayout<Float>.stride

        guard let inputBuffer = device.makeBuffer(
            length: byteCount,
            options: .storageModeShared
        ),
        let outputBuffer = device.makeBuffer(
            length: byteCount,
            options: .storageModeShared
        ) else {
            throw MetalComputeError.bufferAllocationFailed
        }

        prepareInput(
            buffer: inputBuffer,
            elementCount: elementCount
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalComputeError.commandBufferUnavailable
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalComputeError.encoderUnavailable
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)

        var iterations = UInt32(iterationsPerElement)

        encoder.setBytes(
            &iterations,
            length: MemoryLayout<UInt32>.stride,
            index: 2
        )

        let executionWidth = pipeline.threadExecutionWidth

        let threadgroupWidth = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            executionWidth * 4
        )

        encoder.dispatchThreads(
            MTLSize(
                width: elementCount,
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

        let started =
            ProcessInfo.processInfo.systemUptime

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let duration =
            ProcessInfo.processInfo.systemUptime -
            started

        guard commandBuffer.status == .completed else {
            throw MetalComputeError.commandFailed(
                commandBuffer.error
            )
        }

        let verification = try verifyAndChecksum(
            outputBuffer: outputBuffer,
            elementCount: elementCount,
            iterationsPerElement: iterationsPerElement
        )

        let operationCount =
            Double(elementCount) *
            Double(iterationsPerElement) *
            4.0

        let estimatedGFLOPS =
            operationCount /
            duration /
            1_000_000_000

        return MetalBenchmarkResult(
            duration: duration,
            estimatedGFLOPS: estimatedGFLOPS,
            checksum: verification.checksum,
            verificationValue: verification.value
        )
    }

    private func prepareInput(
        buffer: MTLBuffer,
        elementCount: Int
    ) {
        let pointer = buffer.contents().bindMemory(
            to: Float.self,
            capacity: elementCount
        )

        for index in 0..<elementCount {
            let normalized =
                Float(index % 1_024) /
                1_024.0

            pointer[index] =
                0.25 +
                normalized
        }
    }

    private func verifyAndChecksum(
        outputBuffer: MTLBuffer,
        elementCount: Int,
        iterationsPerElement: Int
    ) throws -> (
        checksum: Double,
        value: Float
    ) {
        let output = outputBuffer.contents().bindMemory(
            to: Float.self,
            capacity: elementCount
        )

        let actual = output[0]

        var expected: Float = 0.25

        for _ in 0..<iterationsPerElement {
            expected = Float(0.0000002)
                .addingProduct(
                    expected,
                    1.0000001
                )

            expected = Float(0.0000001)
                .addingProduct(
                    expected,
                    0.9999999
                )
        }

        guard actual.isFinite,
              abs(actual - expected) < 0.01 else {
            throw MetalComputeError.verificationFailed(
                expected: expected,
                actual: actual
            )
        }

        let sampleCount = min(
            2_048,
            elementCount
        )

        let sampleStride = max(
            1,
            elementCount / sampleCount
        )

        var checksum = 0.0
        var index = 0

        while index < elementCount {
            checksum += Double(output[index])
            index += sampleStride
        }

        return (
            checksum,
            actual
        )
    }
}
