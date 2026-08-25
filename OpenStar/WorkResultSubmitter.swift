//
//  WorkResultSubmitter.swift
//  OpenStar
//
//  Bounded concurrent submission for independent work-result receipts.
//  This is generic worker transport infrastructure; it does not understand
//  workload payloads or science semantics.
//

import Foundation

nonisolated
struct WorkResultSubmissionFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

nonisolated
struct WorkResultSubmissionOutcome: Sendable {
    let index: Int
    let receipt: ResultReceipt?
    let failure: WorkResultSubmissionFailure?
}

nonisolated
enum WorkResultSubmitter {
    static let defaultMaximumConcurrent = 4

    static func submit(
        results: [WorkResult],
        coordinator: CoordinatorClient,
        maximumConcurrent: Int = defaultMaximumConcurrent,
        maximumAttempts: Int = 3
    ) async -> [WorkResultSubmissionOutcome] {
        await submit(
            results: results,
            maximumConcurrent: maximumConcurrent
        ) { result in
            await submitWithRetry(
                coordinator: coordinator,
                result: result,
                maximumAttempts: maximumAttempts
            )
        }
    }

    static func submit(
        results: [WorkResult],
        maximumConcurrent: Int,
        operation: @escaping @Sendable (WorkResult) async
            -> Result<ResultReceipt, WorkResultSubmissionFailure>
    ) async -> [WorkResultSubmissionOutcome] {
        guard !results.isEmpty else { return [] }

        let limit = min(max(maximumConcurrent, 1), results.count)

        return await withTaskGroup(of: WorkResultSubmissionOutcome.self) { group in
            var nextIndex = 0
            var outcomes = Array<WorkResultSubmissionOutcome?>(
                repeating: nil,
                count: results.count
            )

            while nextIndex < limit {
                let index = nextIndex
                let result = results[index]
                group.addTask {
                    await outcome(
                        index: index,
                        result: result,
                        operation: operation
                    )
                }
                nextIndex += 1
            }

            while let outcome = await group.next() {
                outcomes[outcome.index] = outcome

                if nextIndex < results.count {
                    let index = nextIndex
                    let result = results[index]
                    group.addTask {
                        await self.outcome(
                            index: index,
                            result: result,
                            operation: operation
                        )
                    }
                    nextIndex += 1
                }
            }

            return outcomes.compactMap { $0 }
        }
    }

    private static func outcome(
        index: Int,
        result: WorkResult,
        operation: @escaping @Sendable (WorkResult) async
            -> Result<ResultReceipt, WorkResultSubmissionFailure>
    ) async -> WorkResultSubmissionOutcome {
        switch await operation(result) {
        case .success(let receipt):
            return WorkResultSubmissionOutcome(
                index: index,
                receipt: receipt,
                failure: nil
            )
        case .failure(let failure):
            return WorkResultSubmissionOutcome(
                index: index,
                receipt: nil,
                failure: failure
            )
        }
    }

    private static func submitWithRetry(
        coordinator: CoordinatorClient,
        result: WorkResult,
        maximumAttempts: Int
    ) async -> Result<ResultReceipt, WorkResultSubmissionFailure> {
        precondition(maximumAttempts > 0)

        var attempt = 1

        while true {
            do {
                return .success(
                    try await coordinator.submit(result: result)
                )
            } catch {
                let retryable: Bool

                if classifyWorkFailure(error) == .transportUnavailable {
                    retryable = true
                } else if let coordinatorError = error as? CoordinatorClientError,
                          case .serverError(let statusCode, _) = coordinatorError {
                    retryable = statusCode == 408
                        || statusCode == 429
                        || (500..<600).contains(statusCode)
                } else {
                    retryable = false
                }

                guard attempt < maximumAttempts, retryable else {
                    return .failure(
                        WorkResultSubmissionFailure(
                            message: error.localizedDescription
                        )
                    )
                }

                let delay = 250 * (1 << (attempt - 1))
                print(
                    "⭐️ [OpenStar] Result submission attempt \(attempt) failed; retrying"
                )
                try? await Task.sleep(for: .milliseconds(delay))
                attempt += 1
            }
        }
    }
}
