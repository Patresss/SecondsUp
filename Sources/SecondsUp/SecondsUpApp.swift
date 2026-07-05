import Foundation
import SwiftUI

@main
struct SecondsUpApp: App {
    init() {
        if CommandLine.arguments.contains("--self-test-export") {
            Foundation.exit(Int32(SelfTest.run(arguments: CommandLine.arguments)))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1050, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
