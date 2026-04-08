import SwiftUI

@main
struct MiniWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        appDelegate.appState = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel(state: appState.recorder.state, meterLevel: appState.recorder.meterLevel)
        }
        .menuBarExtraStyle(.window)
    }
}
