import SwiftUI

struct RootView: View {
    @StateObject private var web = WebController()
    private let config = AppConfig.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Fills the status bar area with the app's theme colour.
                config.theme.ignoresSafeArea()
                config.background.ignoresSafeArea(edges: .bottom)

                // Full screen under the notch and home bar; the page uses env(safe-area-inset-*).
                WebViewContainer(controller: web)
                    .ignoresSafeArea()

                if web.offline {
                    NoConnectionView { web.retry() }
                }

                // Long press on the top bar opens the sync status.
                Color.clear
                    .frame(height: max(geo.safeAreaInsets.top, 20))
                    .contentShape(Rectangle())
                    .onLongPressGesture { web.showStatus = true }
                    .offset(y: -geo.safeAreaInsets.top)
            }
        }
        .sheet(isPresented: $web.showStatus) {
            StatusView()
        }
    }
}

struct NoConnectionView: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No connection")
                .font(.title2.bold())
            Text("Check your internet connection and try again.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
