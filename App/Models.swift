import Foundation
import SwiftData
import SwiftUI

// MARK: - Settings keys

enum AppSettings {
    static let modelKey = "gemini_model"
    static let sheetsURLKey = "google_sheets_url"
    static let defaultModel = "gemini-3.8-flash"
    static let modelMigrationKey = "gemini_model_migrated_3_8"
    static let modelPresets: [String] = [
        "gemini-3.8-flash",
        "gemini-2.5-flash",
        "gemini-2.5-pro"
    ]

    /// One-time migration: apps that saved an older model name switch to the new default.
    static func migrateModelIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: modelMigrationKey) else { return }
        defaults.set(defaultModel, forKey: modelKey)
        defaults.set(true, forKey: modelMigrationKey)
    }
}

// MARK: - SwiftData Models

@Model
final class Invoice {
    var title: String
    var supplier: String
    var date: Date
    var totalAmount: Double
    var notes: String
    /// "new" | "preparing" | "done"
    var status: String = "new"
    @Attribute(.externalStorage) var imageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \InvoiceItem.invoice)
    var items: [InvoiceItem] = []

    init(
        title: String,
        supplier: String = "",
        date: Date = Date(),
        totalAmount: Double = 0,
        notes: String = "",
        imageData: Data? = nil
    ) {
        self.title = title
        self.supplier = supplier
        self.date = date
        self.totalAmount = totalAmount
        self.notes = notes
        self.imageData = imageData
    }

    func recalculateTotal() {
        totalAmount = items.reduce(0) { $0 + $1.total }
    }
}

@Model
final class InvoiceItem {
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var total: Double
    var sortIndex: Int
    var prepared: Bool = false
    var invoice: Invoice?

    init(
        name: String,
        code: String = "",
        qty: Double = 1,
        unitPrice: Double = 0,
        total: Double = 0,
        sortIndex: Int = 0
    ) {
        self.name = name
        self.code = code
        self.qty = qty
        self.unitPrice = unitPrice
        self.total = total
        self.sortIndex = sortIndex
    }
}

@Model
final class Product {
    var name: String
    var code: String
    var qty: Double
    var price: Double
    var sku: String = ""
    var cost: Double = 0
    var imageURL: String = ""
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        code: String = "",
        qty: Double = 0,
        price: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.code = code
        self.qty = qty
        self.price = price
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Inventory merge service

struct InventoryEntry {
    var name: String
    var code: String
    var qty: Double
    var price: Double      // سعر البيع
    var cost: Double = 0   // سعر الشراء / التكلفة
}

enum InventoryMergeMode {
    case addQuantity
    case replaceQuantity
}

struct InventoryMergeResult {
    var added: Int = 0
    var updated: Int = 0
}

enum InventoryService {
    @discardableResult
    static func merge(
        _ entries: [InventoryEntry],
        mode: InventoryMergeMode,
        in context: ModelContext
    ) -> InventoryMergeResult {
        let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        var byCode: [String: Product] = [:]
        var byName: [String: Product] = [:]

        for product in existing {
            let codeKey = product.code.codeKey
            if !codeKey.isEmpty {
                byCode[codeKey] = product
            }
            let skuKey = product.sku.codeKey
            if !skuKey.isEmpty && byCode[skuKey] == nil {
                byCode[skuKey] = product
            }
            byName[product.name.trimmed.lowercased()] = product
        }

        var result = InventoryMergeResult()

        for entry in entries {
            let name = entry.name.trimmed
            let code = entry.code.trimmed
            if name.isEmpty && code.isEmpty { continue }

            let codeKey = code.codeKey
            let nameKey = name.lowercased()

            var match: Product?
            if !codeKey.isEmpty {
                match = byCode[codeKey]
            }
            if match == nil && !nameKey.isEmpty {
                match = byName[nameKey]
            }

            if let product = match {
                switch mode {
                case .addQuantity:
                    product.qty += entry.qty
                case .replaceQuantity:
                    product.qty = entry.qty
                }
                if entry.price > 0 {
                    product.price = entry.price
                }
                if entry.cost > 0 {
                    product.cost = entry.cost
                }
                if !name.isEmpty {
                    product.name = name
                }
                if product.code.trimmed.isEmpty && !code.isEmpty {
                    product.code = code
                }
                product.updatedAt = Date()
                result.updated += 1
            } else {
                let product = Product(
                    name: name.isEmpty ? code : name,
                    code: code,
                    qty: entry.qty,
                    price: entry.price
                )
                product.cost = entry.cost
                context.insert(product)
                if !codeKey.isEmpty {
                    byCode[codeKey] = product
                }
                byName[product.name.trimmed.lowercased()] = product
                result.added += 1
            }
        }

        try? context.save()
        return result
    }
}

// MARK: - Formatting & parsing helpers

enum Formatters {
    static func number(
        _ value: Double,
        minFraction: Int = 0,
        maxFraction: Int = 2,
        grouping: Bool = true
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = minFraction
        formatter.maximumFractionDigits = max(minFraction, maxFraction)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func date(_ date: Date, includeTime: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar@numbers=latn")
        formatter.dateStyle = .medium
        formatter.timeStyle = includeTime ? .short : .none
        return formatter.string(from: date)
    }
}

extension String {
    /// Extracts the first usable image URL from a sheet cell (handles =IMAGE("..."),
    /// several links separated by comma/space/newline, protocol-relative links and Drive share links).
    var firstImageURL: URL? {
        var text = trimmed
        if text.isEmpty { return nil }
        if let range = text.range(of: #"https?://[^\s,;"')]+"#, options: .regularExpression) {
            text = String(text[range])
        } else if text.hasPrefix("//") {
            text = "https:" + text
        } else {
            return nil
        }
        // Google Drive share links -> direct view links
        if let match = text.range(of: #"drive\.google\.com/file/d/([^/]+)"#, options: .regularExpression) {
            let id = text[match].replacingOccurrences(of: "drive.google.com/file/d/", with: "")
            text = "https://drive.google.com/uc?export=view&id=\(id)"
        }
        if let url = URL(string: text) { return url }
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%"))) {
            return URL(string: encoded)
        }
        return nil
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts Arabic-Indic and Persian digits to Western digits and normalizes separators.
    var normalizedDigits: String {
        var output = ""
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669:
                if let converted = UnicodeScalar(scalar.value - 0x0660 + 48) {
                    output.unicodeScalars.append(converted)
                }
            case 0x06F0...0x06F9:
                if let converted = UnicodeScalar(scalar.value - 0x06F0 + 48) {
                    output.unicodeScalars.append(converted)
                }
            case 0x066B:
                output.append(".")
            case 0x066C, 0x060C:
                break
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Key used to compare product codes.
    var codeKey: String {
        normalizedDigits.trimmed.lowercased()
    }

    /// Lenient numeric parsing that supports Arabic digits and thousands separators.
    var parsedDouble: Double? {
        let normalized = normalizedDigits
        var cleaned = ""
        for character in normalized {
            if character.isASCII && (character.isNumber || character == "." || character == "-") {
                cleaned.append(character)
            }
        }
        if cleaned.isEmpty { return nil }
        return Double(cleaned)
    }
}


// MARK: - Invoice status

enum InvoiceStatus {
    static let new = "new"
    static let preparing = "preparing"
    static let done = "done"
}

extension Notification.Name {
    static let goToPreparationTab = Notification.Name("goToPreparationTab")
}

// MARK: - Stock matching

enum StockState {
    case available      // الموجود يكفي
    case partial        // موجود لكن أقل من المطلوب
    case out            // معروف في المخزون لكن الكمية 0
    case notFound       // مش موجود في المخزون
}

struct StockInfo {
    var product: Product?
    var state: StockState
    var stock: Double
    var missing: Double

    var isFullyAvailable: Bool { state == .available }
}

struct StockMatcher {
    private var byCode: [String: Product] = [:]
    private var byName: [String: Product] = [:]

    init(products: [Product]) {
        for product in products {
            let code = product.code.codeKey
            if !code.isEmpty { byCode[code] = product }
            let sku = product.sku.codeKey
            if !sku.isEmpty && byCode[sku] == nil { byCode[sku] = product }
            let name = product.name.trimmed.lowercased()
            if !name.isEmpty { byName[name] = product }
        }
    }

    func info(for item: InvoiceItem) -> StockInfo {
        var match: Product?
        let code = item.code.codeKey
        if !code.isEmpty { match = byCode[code] }
        if match == nil {
            let name = item.name.trimmed.lowercased()
            if !name.isEmpty { match = byName[name] }
        }
        guard let product = match else {
            return StockInfo(product: nil, state: .notFound, stock: 0, missing: item.qty)
        }
        let stock = max(product.qty, 0)
        if stock >= item.qty {
            return StockInfo(product: product, state: .available, stock: stock, missing: 0)
        }
        return StockInfo(
            product: product,
            state: stock > 0 ? .partial : .out,
            stock: stock,
            missing: item.qty - stock
        )
    }
}

/// صف يعرض حالة المخزون تحت الصنف
struct StockBadge: View {
    let info: StockInfo

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch info.state {
        case .available:
            return "الموجود: \(Formatters.number(info.stock, maxFraction: 3))"
        case .partial:
            return "الموجود: \(Formatters.number(info.stock, maxFraction: 3)) — ناقص \(Formatters.number(info.missing, maxFraction: 3))"
        case .out:
            return "الموجود: 0 — ناقص \(Formatters.number(info.missing, maxFraction: 3))"
        case .notFound:
            return "غير موجود في المخزون"
        }
    }

    private var icon: String {
        switch info.state {
        case .available: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .out, .notFound: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch info.state {
        case .available: return .green
        case .partial: return .orange
        case .out, .notFound: return .red
        }
    }
}
