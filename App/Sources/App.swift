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
                    LaunchView().task {
                        let e = Engine(settings: settings, store: store)
                        if DesignFixture.requested { DesignFixture.apply(to: e, settings: settings) } else { e.bootstrap() }
                        engine = e
                    }
                }
            }
            .tint(LooplDesign.accent)
        }
    }
}

/// What the launch screen hands over to: the mark, centred, nothing else.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            LooplMark().frame(width: 88, height: 88)
        }
    }
}

struct RootView: View {
    @Bindable var engine: Engine
    @Bindable var settings: AppSettings
    @Bindable var store: ModelStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: Pane = .chat
    enum Pane: Hashable { case chat, models, settings }

    var body: some View {
        if sizeClass == .regular {
            // iPad / landscape: two columns — history in the sidebar, the conversation as the detail.
            NavigationSplitView {
                HistoryList(engine: engine, selection: $selection)
            } detail: {
                switch selection {
                case .chat: ChatView(engine: engine, settings: settings, store: store, inSplit: true)
                case .models: ModelsView(engine: engine, store: store, settings: settings)
                case .settings: SettingsView(engine: engine, settings: settings, store: store)
                }
            }
        } else {
            TabView(selection: $selection) {
                Tab("Chat", systemImage: LooplDesign.iconChat, value: .chat) { ChatView(engine: engine, settings: settings, store: store) }
                Tab("Models", systemImage: LooplDesign.iconModels, value: .models) { ModelsView(engine: engine, store: store, settings: settings) }
                Tab("Settings", systemImage: LooplDesign.iconSettings, value: .settings) { SettingsView(engine: engine, settings: settings, store: store) }
            }
        }
    }
}
