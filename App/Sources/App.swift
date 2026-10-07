import SwiftUI
import Loopl
import LooplUI

@main
struct LooplApp: App {
    @UIApplicationDelegateAdaptor(LooplAppDelegate.self) private var appDelegate   // ⌘↩ from inside the composer (KeyCommands.swift)
    @State private var settings = AppSettings()
    @State private var store = ModelStore()
    @State private var engine: Engine?
    @State private var onboarding = false
    @State private var replaying = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if SelfTest.requested {
                    SelfTestView(settings: settings, store: store)
                } else if let engine {
                    RootView(engine: engine, settings: settings, store: store)
                        .looplHaptics(engine.haptics)
                        // First launch: the intro + story + first model (Onboarding.needed). Full screen — it IS the app until the
                        // first model is picked. Hung off the root, never a List Section (#66). Settings › About replays it.
                        .fullScreenCover(isPresented: $onboarding) {
                            OnboardingView(engine: engine, store: store, replay: replaying) {
                                onboarding = false
                                if case .ready = engine.readiness { NotificationCenter.default.post(name: Onboarding.finished, object: nil) }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: Onboarding.replay)) { _ in replaying = true; onboarding = true }
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
    @State private var columns: NavigationSplitViewVisibility = .automatic
    enum Pane: Hashable { case chat, models, settings }
    /// Posted by a pane that wants another one in front (the chat's empty state → Models; IMPROVE-4 #9).
    static let openModels = Notification.Name("loopl.openModels")

    var body: some View {
        panes.onReceive(NotificationCenter.default.publisher(for: Self.openModels)) { _ in selection = .models }
    }
    @ViewBuilder private var panes: some View {
        if sizeClass == .regular {
            // iPad / landscape: two columns — history in the sidebar, the conversation as the detail.
            NavigationSplitView(columnVisibility: $columns) {
                HistoryList(engine: engine, selection: $selection)
            } detail: {
                switch selection {
                case .chat: ChatView(engine: engine, settings: settings, store: store, inSplit: true)
                case .models: ModelsView(engine: engine, store: store, settings: settings)
                case .settings: SettingsView(engine: engine, settings: settings, store: store)
                }
            }
            // ⌘Y shows / hides the History sidebar (on iPhone the same chord opens the History sheet — ChatView).
            .background {
                // Toggle on the SHOWN state, not on `.detailOnly`: the initial value is `.automatic` (sidebar hidden in
                // portrait), so "== .detailOnly ? .all : .detailOnly" wasted the first press re-hiding a hidden sidebar.
                Button("History") { withAnimation { columns = columns == .all ? .detailOnly : .all } }
                    .keyboardShortcut("y", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
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
