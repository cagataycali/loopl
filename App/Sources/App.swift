import SwiftUI
import Loopl
import LooplUI

@main
struct LooplApp: App {
    @State private var settings = AppSettings()
    @State private var store = ModelStore()
    @State private var engine: Engine?

    var body: some Scene {
        WindowGroup {
            Group {
                if SelfTest.requested {
                    SelfTestView(settings: settings, store: store)
                } else if let engine {
                    RootView(engine: engine, settings: settings, store: store)
                } else {
                    ProgressView().task { engine = Engine(settings: settings, store: store) }
                }
            }
            .tint(LooplDesign.accent)
        }
    }
}

struct RootView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore

    var body: some View {
        TabView {
            Tab("Chat", systemImage: LooplDesign.iconChat) { ChatView(engine: engine, settings: settings) }
            Tab("Models", systemImage: LooplDesign.iconModels) { ModelsView(engine: engine, store: store, settings: settings) }
            Tab("Agent", systemImage: LooplDesign.iconAgent) { AgentView(engine: engine, settings: settings) }
            Tab("Settings", systemImage: LooplDesign.iconSettings) { SettingsView(engine: engine, settings: settings, store: store) }
        }
    }
}
