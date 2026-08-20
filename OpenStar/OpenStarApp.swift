//
//  OpenStarApp.swift
//  OpenStar
//
//  Created by Cody Peter on 8/9/26.
//

import SwiftUI

@main
struct OpenStarApp: App {
    @State private var contributionManager: ContributionManager

    init() {
        let manager = ContributionManager()
        _contributionManager = State(initialValue: manager)
        #if os(iOS)
        BackgroundContributionSession.shared.register {
            [weak manager] task in
            manager?.attachBackgroundTask(task)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manager: contributionManager)
        }
    }
}
