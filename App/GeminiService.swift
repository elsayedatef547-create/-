import Foundation
import UIKit

// MARK: - Errors

enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidModel
    case network(String)
    case http(Int, String)
    case blocked(String)
    case emptyResponse
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "لم يتم إدخال مفتاح Gemini API. أضفه من تبويب الإعدادات."
        case .invalidModel:
            return "اسم النموذج غير صالح. تحقق من الإعدادات."
        case .network(let message):
            return "تعذّر الاتصال بالخادم: \(message)"
        case .http(let code, let message):
            return "خطأ من الخادم (\(code)): \(message)"
        case .blocked(let reason):
            return "تم حظر الطلب من قبل Gemini: \(reason)"
        case .emptyResponse:
            return "لم يُرجع Gemini أي نتيجة."
        case .parsing(let message):
            return "تعذّر قراءة نتيجة Gemini: \(message)"
        }
    }
}

// MARK: - Extracted item

struct ExtractedItem: Decodable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var code: String
    var qty: Double
    var unitPrice: Double
    var total: Double

    enum CodingKeys: String, CodingKey {
        case name
        case code
        case qty
        case unitPrice = "unit_price"
        case total
    }

    init(name: String, code: String, qty: Double, unitPrice: Double, total: Double) {
        self.name = name
        self.code = code
        self.qty = qty
        self.unitPrice = unitPrice
        self.total = total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = container.lenientString(.name)
        let decodedCode = container.lenientString(.code).normalizedDigits.trimmed
        var decodedQty = container.lenientDouble(.qty)
        var decodedPrice = container.lenientDouble(.unitPrice)
        var decodedTotal = container.lenientDouble(.total)

        if decodedQty <= 0 && (decodedPrice > 0 || decodedTotal > 0) {
            decodedQty = 1
        }
        if decodedTotal <= 0 && decodedQty > 0 && decodedPrice > 0 {
            decodedTotal = decodedQty * decodedPrice
        }
        if decodedPrice <= 0 && decodedQty > 0 && decodedTotal > 0 {
            decodedPrice = decodedTotal / decodedQty
        }

        self.name = decodedName
        self.code = decodedCode
        self.qty = decodedQty
        self.unitPrice = decodedPrice
        self.total = decodedTotal
    }
}

private extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = try? decode(Double.self, forKey: key) {
            if abs(number) < 1e15 && number == number.rounded() {
                return String(Int64(number))
            }
            return String(number)
        }
        return ""
    }

    func lenientDouble(_ key: Key) -> Double {
        if let number = try? decode(Double.self, forKey: key) {
            return number
        }
        if let text = try? decode(String.self, forKey: key) {
            return text.parsedDouble ?? 0
        }
        return 0
    }
}

// MARK: - Request / response payloads

private struct GeminiRequest: Encodable {
    struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }
    }

    struct Content: Encodable {
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let responseMimeType: String

        enum CodingKeys: String, CodingKey {
            case temperature
            case responseMimeType = "response_mime_type"
        }
    }

    let contents: [Content]
    let generationConfig: GenerationConfig

    enum CodingKeys: String, CodingKey {
        case contents
        case generationConfig = "generation_config"
    }
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct Content: Decodable {
        let parts: [Part]?
    }

    struct Part: Decodable {
        let text: String?
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

private struct GeminiErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let code: Int?
        let message: String?
    }

    let error: Detail?
}

// MARK: - Service

enum GeminiService {
    /// The exact prompt sent to Gemini.
    static let extractionPrompt: String = """
    You are an expert invoice data extraction engine.
    Analyze the attached invoice (it may be a photo or a PDF). The invoice may be written in Arabic, English, or both. If any numbers are written with Arabic-Indic digits (٠١٢٣٤٥٦٧٨٩), convert them to Western digits (0-9).

    Extract EVERY line item from the invoice and return ONLY a valid JSON array. Do not include markdown, code fences, explanations, or any text outside the JSON.

    Use exactly this format:
    [{"name": "Product Name", "code": "123", "qty": 2, "unit_price": 10.5, "total": 21.0}]

    Rules:
    - "name": the product or service description exactly as written on the invoice (keep Arabic text as Arabic).
    - "code": the product code, SKU, or barcode as a string. Use "" if none is printed.
    - "qty": the quantity as a number.
    - "unit_price": the price of a single unit as a number (no currency symbols, no thousands separators).
    - "total": the line total as a number (no currency symbols, no thousands separators).
    - Do not include subtotal, tax, discount, or grand total rows as items.
    - If a value is unreadable, use 0 for numbers and "" for strings.
    - If no items can be found, return [].
    """

    // MARK: Image preparation

    static func prepareImage(_ image: UIImage, maxDimension: CGFloat = 2000, quality: CGFloat = 0.8) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    // MARK: Extraction

    static func extractItems(from data: Data, mimeType: String) async throws -> [ExtractedItem] {
        guard let storedKey = KeychainHelper.readAPIKey(), !storedKey.trimmed.isEmpty else {
            throw GeminiError.missingAPIKey
        }
        let apiKey = storedKey.trimmed

        var model = (UserDefaults.standard.string(forKey: AppSettings.modelKey) ?? AppSettings.defaultModel).trimmed
        if model.isEmpty {
            model = AppSettings.defaultModel
        }
        if model.hasPrefix("models/") {
            model = String(model.dropFirst("models/".count))
        }

        guard
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent")
        else {
            throw GeminiError.invalidModel
        }

        let body = GeminiRequest(
            contents: [
                GeminiRequest.Content(parts: [
                    GeminiRequest.Part(text: extractionPrompt, inlineData: nil),
                    GeminiRequest.Part(
                        text: nil,
                        inlineData: GeminiRequest.InlineData(
                            mimeType: mimeType,
                            data: data.base64EncodedString()
                        )
                    )
                ])
            ],
            generationConfig: GeminiRequest.GenerationConfig(
                temperature: 0,
                responseMimeType: "application/json"
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw GeminiError.network(error.localizedDescription)
        }

        guard let http = result.1 as? HTTPURLResponse else {
            throw GeminiError.emptyResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: result.0)
            let message = envelope?.error?.message ?? String(data: result.0, encoding: .utf8) ?? ""
            throw GeminiError.http(http.statusCode, message)
        }

        let decoded: GeminiResponse
        do {
            decoded = try JSONDecoder().decode(GeminiResponse.self, from: result.0)
        } catch {
            throw GeminiError.parsing(error.localizedDescription)
        }

        if let reason = decoded.promptFeedback?.blockReason, !reason.isEmpty {
            throw GeminiError.blocked(reason)
        }

        let text = (decoded.candidates?.first?.content?.parts ?? [])
            .compactMap { $0.text }
            .joined()

        if text.trimmed.isEmpty {
            throw GeminiError.emptyResponse
        }

        return try parseItems(from: text)
    }

    // MARK: Parsing

    static func parseItems(from text: String) throws -> [ExtractedItem] {
        let cleaned = text.trimmed

        guard
            let start = cleaned.firstIndex(of: "["),
            let end = cleaned.lastIndex(of: "]"),
            start < end
        else {
            throw GeminiError.parsing("لم يتم العثور على مصفوفة JSON في الرد.")
        }

        let jsonString = String(cleaned[start...end])
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw GeminiError.parsing("ترميز غير صالح.")
        }

        do {
            let items = try JSONDecoder().decode([ExtractedItem].self, from: jsonData)
            return items.filter { item in
                !(item.name.trimmed.isEmpty && item.code.trimmed.isEmpty && item.total == 0)
            }
        } catch {
            throw GeminiError.parsing(error.localizedDescription)
        }
    }
}
