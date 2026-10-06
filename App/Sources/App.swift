import SwiftUI
import Loopl
import LooplUI

@main
struct LooplApp: App {
    @State private var settings = AppSettings()
    @State private var store = ModelStore()
    @State private var engine: Engine?
    @State private var onboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if SelfTest.requested {
                    SelfTestView(settings: settings, store: store)
                } else if let engine {
                    RootView(engine: engine, settings: settings, store: store)
                        .looplHaptics(engine.haptics)
                        // First launch: pick the first model (Onboarding.needed). Hung off the root, never a List Section (#66).
                        .sheet(isPresented: $onboarding) {
                            OnboardingView(engine: engine, store: store) { onboarding = false }
                        }
                } else {
                    LaunchView().task {
                        StorageFixture.apply(to: store)
                        let e = Engine(settings: settings, store: store)
                        if DesignFixture.requested { DesignFixture.apply(to: e, settings: settings) }
                        if Onboarding.needed(settings: settings, store: store) { onboarding = true }
                        else if !DesignFixture.requested { e.bootstrap() }
                        engine = e
                    }
                }
            }
            .tint(LooplDesign.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
            // App-wide (not only on the Storage screen): a drive plugged in while loopl was in the background —
            // or one iOS mounted late — is re-resolved the moment the app is active again.
            .onChange(of: scenePhase) { _, p in
                if p == .active, engine != nil { store.refresh(); store.storage.retryLateMounts() }
            }
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
    @State private var selection: Pane = DesignFixture.initialPane
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
            // Every pane's list tops its bottom inset up to clear the tab bar (see looplScrollClearance()).
            .looplBottomBar()
        }
    }
}
