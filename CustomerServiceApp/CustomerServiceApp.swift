import SwiftUI

@main
struct CustomerServiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.restore()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        Task { await viewModel.becameActive() }
                    } else if phase == .background {
                        viewModel.enteredBackground()
                    }
                }
        }
    }
}

