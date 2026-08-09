//
//  NodeIdentity.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//


//
//  NodeIdentity.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import Foundation

@MainActor
enum NodeIdentity {
    private static let key = "OpenStarNodeID"

    static var id: UUID {
        if let value = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: value) {
            return id
        }

        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
