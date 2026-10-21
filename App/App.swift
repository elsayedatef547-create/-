import SwiftUI
import SwiftData
import UIKit

@main
struct InvoiceScannerApp: App {
    let sharedModelContainer: ModelContainer

    init() {
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        AppSettings.migrateModelIfNeeded()

        let schema = Schema([Invoice.self, InvoiceItem.self, Product.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            sharedModelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                sharedModelContainer = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(\.layoutDirection, .rightToLeft)
        }
        .modelContainer(sharedModelContainer)
    }
}
