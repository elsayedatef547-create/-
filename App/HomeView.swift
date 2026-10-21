import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Home

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Invoice.date, order: .reverse) private var invoices: [Invoice]

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var isProcessing = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    ContentUnavailableView(
                        "لا توجد فواتير",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("اضغط على «رفع فاتورة جديدة» لتحليل فاتورة وإضافتها.")
                    )
                } else {
                    List {
                        ForEach(invoices) { invoice in
                            NavigationLink {
                                InvoiceDetailView(invoice: invoice)
                            } label: {
                                InvoiceRow(invoice: invoice)
                            }
                        }
                        .onDelete(perform: deleteInvoices)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("الفواتير")
            .safeAreaInset(edge: .bottom) {
                uploadMenu
            }
            .overlay {
                if isProcessing {
                    processingOverlay
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await loadPhoto(newValue) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(isPresented: $showCamera) { image in
                Task { await process(image: image) }
            }
            .ignoresSafeArea()
        }
        .background(
            // Separate host view so the file picker doesn't clash with the other presentations.
            Color.clear
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.pdf, .image, .data],
                    allowsMultipleSelection: false
                ) { result in
                    handleImport(result)
                }
        )
        .alert("خطأ", isPresented: $showError) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: Subviews

    private var uploadMenu: some View {
        Menu {
            Button {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                } else {
                    present(error: "الكاميرا غير متاحة على هذا الجهاز.")
                }
            } label: {
                Label("التقاط صورة بالكاميرا", systemImage: "camera.fill")
            }

            Button {
                showPhotoPicker = true
            } label: {
                Label("اختيار من الصور", systemImage: "photo.on.rectangle")
            }

            Button {
                // Let the menu finish dismissing before presenting the picker.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showFileImporter = true
                }
            } label: {
                Label("اختيار ملف PDF أو صورة", systemImage: "doc.fill")
            }
        } label: {
            Label("رفع فاتورة جديدة", systemImage: "plus.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.indigo, in: Capsule())
                .foregroundStyle(.white)
        }
        .disabled(isProcessing)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("جاري تحليل الفاتورة...")
                    .font(.headline)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: Actions

    private func deleteInvoices(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(invoices[index])
        }
        try? modelContext.save()
    }

    private func present(error message: String) {
        errorMessage = message
        showError = true
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                present(error: "تعذّر تحميل الصورة المختارة.")
                return
            }
            await process(image: image)
        } catch {
            present(error: error.localizedDescription)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            present(error: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            // Read while the security-scoped access is guaranteed to be valid.
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                present(error: "تعذّر قراءة الملف.")
                return
            }
            let isPDF = url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF".utf8))
            Task { await importData(data, isPDF: isPDF) }
        }
    }

    @MainActor
    private func importData(_ data: Data, isPDF: Bool) async {
        if isPDF {
            await runExtraction(data: data, mimeType: "application/pdf", preview: nil)
        } else if let image = UIImage(data: data) {
            await process(image: image)
        } else {
            present(error: "نوع الملف غير مدعوم.")
        }
    }

    @MainActor
    private func process(image: UIImage) async {
        guard let jpeg = GeminiService.prepareImage(image) else {
            present(error: "تعذّر معالجة الصورة.")
            return
        }
        await runExtraction(data: jpeg, mimeType: "image/jpeg", preview: jpeg)
    }

    @MainActor
    private func runExtraction(data: Data, mimeType: String, preview: Data?) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            let extracted = try await GeminiService.extractItems(from: data, mimeType: mimeType)

            let invoice = Invoice(
                title: "فاتورة \(Formatters.date(Date()))",
                date: Date(),
                imageData: preview
            )
            modelContext.insert(invoice)

            for (index, entry) in extracted.enumerated() {
                let item = InvoiceItem(
                    name: entry.name,
                    code: entry.code,
                    qty: entry.qty,
                    unitPrice: entry.unitPrice,
                    total: entry.total,
                    sortIndex: index
                )
                modelContext.insert(item)
                item.invoice = invoice
            }

            invoice.recalculateTotal()
            try modelContext.save()

            if extracted.isEmpty {
                present(error: "لم يتم العثور على أصناف في الفاتورة. يمكنك إضافتها يدوياً.")
            }
        } catch {
            present(error: error.localizedDescription)
        }
    }
}

// MARK: - Invoice row

struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(invoice.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(Formatters.date(invoice.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !invoice.supplier.isEmpty {
                    Text(invoice.supplier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.number(invoice.totalAmount, minFraction: 2))
                    .font(.subheadline.bold())
                Text("\(invoice.items.count) صنف")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Invoice detail

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct InvoiceDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var invoice: Invoice
    @Query private var products: [Product]

    @State private var editingItem: InvoiceItem?
    @State private var shareItem: ShareItem?
    @State private var alertMessage = ""
    @State private var showAlert = false

    private var sortedItems: [InvoiceItem] {
        invoice.items.sorted { $0.sortIndex < $1.sortIndex }
    }

    private var computedTotal: Double {
        invoice.items.reduce(0) { $0 + $1.total }
    }

    /// أسعار البيع من المخزون، بمفتاح الباركود أو الـ SKU
    private var salePriceLookup: [String: Double] {
        var map: [String: Double] = [:]
        for product in products where product.price > 0 {
            let barcode = product.code.codeKey
            if !barcode.isEmpty { map[barcode] = product.price }
            let sku = product.sku.codeKey
            if !sku.isEmpty { map[sku] = product.price }
        }
        return map
    }

    private var totalSale: Double {
        let lookup = salePriceLookup
        return invoice.items.reduce(0) { partial, item in
            partial + item.qty * (lookup[item.code.codeKey] ?? 0)
        }
    }

    var body: some View {
        let salePrices = salePriceLookup
        let matcher = StockMatcher(products: products)
        let infos = sortedItems.map { matcher.info(for: $0) }
        let availableCount = infos.filter { $0.isFullyAvailable }.count
        let missingCount = infos.count - availableCount
        return List {
            if !invoice.items.isEmpty {
                Section("المخزون مقابل الفاتورة") {
                    HStack {
                        Label("موجود: \(availableCount)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Label("ناقص: \(missingCount)", systemImage: "xmark.circle.fill")
                            .foregroundStyle(missingCount > 0 ? .red : .secondary)
                    }
                    .font(.subheadline.weight(.semibold))

                    if invoice.status == InvoiceStatus.new {
                        Button {
                            startPreparation()
                        } label: {
                            Label("تجهيز", systemImage: "checklist")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    } else {
                        Button {
                            NotificationCenter.default.post(name: .goToPreparationTab, object: nil)
                        } label: {
                            Label(invoice.status == InvoiceStatus.done ? "تم التجهيز — فتح في التجهيز" : "قيد التجهيز — فتح في التجهيز",
                                  systemImage: "arrow.right.circle")
                        }
                    }
                }
            }

            Section("معلومات الفاتورة") {
                TextField("العنوان", text: $invoice.title)
                TextField("المورد", text: $invoice.supplier)
                DatePicker("التاريخ", selection: $invoice.date)
                TextField("ملاحظات", text: $invoice.notes, axis: .vertical)
                    .lineLimit(1...4)
            }

            if let data = invoice.imageData, let uiImage = UIImage(data: data) {
                Section("صورة الفاتورة") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity)
                }
            }

            Section("الأصناف (\(invoice.items.count))") {
                ForEach(sortedItems) { item in
                    Button {
                        editingItem = item
                    } label: {
                        ItemRow(item: item, salePrice: salePrices[item.code.codeKey], stock: matcher.info(for: item))
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteItems)

                Button {
                    addItem()
                } label: {
                    Label("إضافة صنف", systemImage: "plus.circle")
                }
            }

            Section {
                HStack {
                    Text("إجمالي الفاتورة")
                        .font(.headline)
                    Spacer()
                    Text(Formatters.number(computedTotal, minFraction: 2))
                        .font(.title3.bold())
                        .foregroundStyle(.indigo)
                }
                if totalSale > 0 {
                    HStack {
                        Text("إجمالي البيع")
                            .font(.headline)
                        Spacer()
                        Text(Formatters.number(totalSale, minFraction: 2))
                            .font(.title3.bold())
                            .foregroundStyle(.green)
                    }
                }
            }

            Section {
                Button {
                    addToInventory()
                } label: {
                    Label("إضافة الأصناف إلى المخزون", systemImage: "shippingbox.and.arrow.backward")
                }
                .disabled(invoice.items.isEmpty)
            }
        }
        .navigationTitle("تفاصيل الفاتورة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sharePDF()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(invoice.items.isEmpty)
            }
        }
        .sheet(item: $editingItem, onDismiss: {
            invoice.totalAmount = computedTotal
            try? modelContext.save()
        }) { item in
            ItemEditView(item: item)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("تنبيه", isPresented: $showAlert) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onDisappear {
            invoice.totalAmount = computedTotal
            try? modelContext.save()
        }
    }

    // MARK: Actions

    private func deleteItems(at offsets: IndexSet) {
        let snapshot = sortedItems
        let toDelete = offsets.map { snapshot[$0] }
        for item in toDelete {
            let identifier = item.persistentModelID
            invoice.items.removeAll { $0.persistentModelID == identifier }
            modelContext.delete(item)
        }
        invoice.totalAmount = computedTotal
        try? modelContext.save()
    }

    private func startPreparation() {
        invoice.status = InvoiceStatus.preparing
        for item in invoice.items { item.prepared = false }
        try? modelContext.save()
        NotificationCenter.default.post(name: .goToPreparationTab, object: nil)
    }

    private func addItem() {
        let nextIndex = (invoice.items.map { $0.sortIndex }.max() ?? -1) + 1
        let item = InvoiceItem(name: "", sortIndex: nextIndex)
        modelContext.insert(item)
        item.invoice = invoice
        editingItem = item
    }

    private func sharePDF() {
        invoice.totalAmount = computedTotal
        do {
            let url = try PDFGenerator.writeTemporaryFile(for: invoice, salePrices: salePriceLookup)
            shareItem = ShareItem(url: url)
        } catch {
            alertMessage = "تعذّر إنشاء ملف PDF: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func addToInventory() {
        let entries = sortedItems.map { item in
            InventoryEntry(name: item.name, code: item.code, qty: item.qty, price: 0, cost: item.unitPrice)
        }
        let result = InventoryService.merge(entries, mode: .addQuantity, in: modelContext)
        alertMessage = "تمت الإضافة إلى المخزون: \(result.added) صنف جديد، \(result.updated) صنف محدّث."
        showAlert = true
    }
}

struct ItemRow: View {
    let item: InvoiceItem
    var salePrice: Double? = nil
    var stock: StockInfo? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.isEmpty ? "صنف بدون اسم" : item.name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                if !item.code.isEmpty {
                    Text(item.code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("\(Formatters.number(item.qty, maxFraction: 3)) × \(Formatters.number(item.unitPrice, minFraction: 2))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let salePrice {
                    Text("سعر البيع: \(Formatters.number(salePrice, minFraction: 2))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if let stock {
                    StockBadge(info: stock)
                }
            }
            Spacer()
            Text(Formatters.number(item.total, minFraction: 2))
                .font(.subheadline.bold())
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ItemEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: InvoiceItem

    var body: some View {
        NavigationStack {
            Form {
                Section("بيانات الصنف") {
                    TextField("الاسم", text: $item.name)
                    TextField("الكود", text: $item.code)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("الكمية والسعر") {
                    HStack {
                        Text("الكمية")
                        Spacer()
                        TextField("0", value: $item.qty, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("سعر الوحدة")
                        Spacer()
                        TextField("0", value: $item.unitPrice, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("الإجمالي")
                        Spacer()
                        TextField("0", value: $item.total, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("تعديل الصنف")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
            .onChange(of: item.qty) { _, _ in
                item.total = item.qty * item.unitPrice
            }
            .onChange(of: item.unitPrice) { _, _ in
                item.total = item.qty * item.unitPrice
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Camera picker

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            parent.isPresented = false
            if let image {
                parent.onImage(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
