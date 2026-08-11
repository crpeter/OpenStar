//
//  AstronomyDataset.swift
//  OpenStar
//
//  Created by Cody Peter on 8/11/26.
//


import Foundation

nonisolated
struct AstronomyDataset: Codable, Sendable {
    let id: String
    let targetName: String?
    let mission: String?
    let timeUnit: String?
    let fluxUnit: String?
    let times: [Float]
    let flux: [Float]
}
