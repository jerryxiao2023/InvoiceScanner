import SwiftUI

@main
struct InvoiceScannerApp: App {
    @StateObject private var store = RecordStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}
