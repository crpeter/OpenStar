//
//  CoordinatorConfiguration.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import Foundation

nonisolated
enum CoordinatorConfiguration {
    static let baseURL: URL = {
#if os(macOS)
        return URL(string: "http://127.0.0.1:8080")!
#else
        return URL(string: "http://192.168.1.184:8080")!
#endif
    }()
}
