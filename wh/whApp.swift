//
//  whApp.swift
//  wh
//
//  Created by Greg Miller on 9/23/25.
//

import SwiftUI

@main
struct whApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
