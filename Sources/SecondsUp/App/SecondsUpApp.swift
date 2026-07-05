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
            MainView()
                .frame(minWidth: 1050, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

enum AppTab: Hashable {
    case extract
    case repair
    case montage
}

struct MainView: View {
    @StateObject private var extractModel = ExtractModel()
    @StateObject private var montageModel = MontageModel()
    @StateObject private var repairModel = RepairModel()
    @State private var tab: AppTab = .extract

    var body: some View {
        Group {
            switch tab {
            case .extract:
                ExtractView(model: extractModel)
            case .repair:
                RepairView(model: repairModel)
            case .montage:
                MontageView(model: montageModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Tryb", selection: $tab) {
                    Label("Wycinanie", systemImage: "scissors")
                        .tag(AppTab.extract)
                    Label("Naprawa", systemImage: "wrench.and.screwdriver")
                        .tag(AppTab.repair)
                    Label("Montaz", systemImage: "film")
                        .tag(AppTab.montage)
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: tab) { newTab in
            switch newTab {
            case .montage:
                // Folder eksportu sekund to naturalne zrodlo montazu.
                montageModel.suggestFolderIfEmpty(extractModel.outputFolder)
            case .repair:
                repairModel.suggestFolderIfEmpty(
                    montageModel.folder ?? extractModel.outputFolder
                )
            case .extract:
                break
            }
        }
    }
}
