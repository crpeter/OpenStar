import Foundation
import Testing
@testable import OpenStar

@Suite(.serialized)
struct WorkResultSubmitterTests {
    private actor Probe {
        private var active = 0
        private var peak = 0
        private var seen: [UUID] = []

        func begin(_ id: UUID) {
            active += 1
            peak = max(peak, active)
            seen.append(id)
        }

        func end() {
            active -= 1
        }

        func snapshot() -> (peak: Int, seen: [UUID]) {
            (peak, seen)
        }
    }

    @Test
    func boundedSubmissionRunsIndependentResultsConcurrently() async throws {
        let probe = Probe()
        let results = (0..<12).map { _ in workResult() }

        let outcomes = await WorkResultSubmitter.submit(
            results: results,
            maximumConcurrent: 4
        ) { result in
            await probe.begin(result.workUnitID)
            try? await Task.sleep(for: .milliseconds(20))
            await probe.end()
            return .success(
                ResultReceipt(accepted: true, message: "ok")
            )
        }

        let snapshot = await probe.snapshot()

        #expect(outcomes.map(\.index) == Array(results.indices))
        #expect(outcomes.allSatisfy { $0.receipt?.accepted == true })
        #expect(outcomes.allSatisfy { $0.failure == nil })
        #expect(snapshot.peak == 4)
        #expect(Set(snapshot.seen) == Set(results.map(\.workUnitID)))
    }

    @Test
    func failedSubmissionDoesNotSuppressLaterSiblings() async throws {
        let results = (0..<9).map { _ in workResult() }
        let failedID = results[2].workUnitID
        let probe = Probe()

        let outcomes = await WorkResultSubmitter.submit(
            results: results,
            maximumConcurrent: 4
        ) { result in
            await probe.begin(result.workUnitID)
            try? await Task.sleep(for: .milliseconds(5))
            await probe.end()

            if result.workUnitID == failedID {
                return .failure(
                    WorkResultSubmissionFailure(message: "expected failure")
                )
            }

            return .success(
                ResultReceipt(accepted: true, message: "ok")
            )
        }

        let snapshot = await probe.snapshot()
        let failure = try #require(
            outcomes.first { $0.failure != nil }
        )

        #expect(outcomes.count == results.count)
        #expect(failure.index == 2)
        #expect(failure.failure?.message == "expected failure")
        #expect(outcomes.filter { $0.receipt?.accepted == true }.count == 8)
        #expect(Set(snapshot.seen) == Set(results.map(\.workUnitID)))
    }

    @Test
    func singleSubmissionRetainsSingleRequestSemantics() async throws {
        let probe = Probe()
        let results = [workResult()]

        let outcomes = await WorkResultSubmitter.submit(
            results: results,
            maximumConcurrent: 4
        ) { result in
            await probe.begin(result.workUnitID)
            await probe.end()
            return .success(
                ResultReceipt(accepted: true, message: "ok")
            )
        }

        let snapshot = await probe.snapshot()
        #expect(outcomes.count == 1)
        #expect(outcomes[0].index == 0)
        #expect(outcomes[0].receipt?.accepted == true)
        #expect(snapshot.peak == 1)
    }

    private func workResult() -> WorkResult {
        WorkResult(
            workUnitID: UUID(),
            nodeID: UUID(),
            status: .completed,
            duration: 0.01,
            payload: .object(["ok": .bool(true)]),
            errorMessage: nil,
            failureKind: nil,
            bestFrequency: nil,
            bestPeriodDays: nil,
            bestPower: nil
        )
    }
}
