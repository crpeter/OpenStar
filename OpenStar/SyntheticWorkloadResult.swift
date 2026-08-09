//
//  SyntheticWorkloadResult.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  SyntheticWorkload.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import Foundation

struct SyntheticWorkloadResult: Sendable {

    let duration: Double

    let checksum: Double
}

enum SyntheticWorkload {

    nonisolated
    static func run() async throws
        -> SyntheticWorkloadResult {

        let started = Date()

        var checksum = 0.0

        let iterations = 2_000_000

        for index in 0..<iterations {

            if index.isMultiple(of: 50_000) {
                try Task.checkCancellation()

                await Task.yield()
            }

            let value =
                Double(
                    (index * 31) % 10_007
                )

            checksum +=
                value * 0.000_001
        }

        return SyntheticWorkloadResult(
            duration:
                Date().timeIntervalSince(started),
            checksum: checksum
        )
    }
}