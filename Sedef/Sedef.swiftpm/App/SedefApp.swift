import SwiftUI

@main
struct SedefApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserScreen()
                .ignoresSafeArea()
                .background(Color.black)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
                .preferredColorScheme(.dark)
        }
    }
}

struct BrowserScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrowserViewController {
        BrowserViewController()
    }

    func updateUIViewController(_ controller: BrowserViewController, context: Context) {}
}
