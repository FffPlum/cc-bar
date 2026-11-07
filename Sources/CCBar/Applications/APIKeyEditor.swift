import SwiftUI
import CCBarConfiguration

struct APIKeyEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var supplier: ModelSupplier
    @State private var name: String
    @State private var endpoint: String
    @State private var key = ""
    @State private var error: String?
    init(supplier: ModelSupplier = .openai) {
        _supplier = State(initialValue: supplier)
        _name = State(initialValue: supplier.name)
        _endpoint = State(initialValue: supplier.defaultEndpoint)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Add API Key", "添加 API Key")).font(.title3.bold())
            Picker(tr("Provider", "供应商"), selection: $supplier) {
                ForEach(ModelSupplier.allCases) { item in
                    Text(item == .custom ? tr("Custom", "自定义") : item.name).tag(item)
                }
            }
            TextField(tr("Name", "名称"), text: $name)
            TextField(tr("API endpoint", "API 地址"), text: $endpoint)
            SecureField("API Key", text: $key)
            if let url = URL(string: supplier.website), !supplier.website.isEmpty {
                Link(tr("Get an API Key", "获取 API Key"), destination: url)
            }
            Text(tr("Keys are stored in private files on this Mac and used only when you apply an application profile.",
                    "Key 保存在本机私有文件中，应用供应商配置时才会使用。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Save", "保存")) {
                    do {
                        try appState.authorizations.saveAccount(supplier: supplier, name: name,
                                                               endpoint: endpoint, key: key)
                        dismiss()
                    } catch ConfigurationError.invalidProvider {
                        self.error = tr("API key wasn't saved. Check the name, API URL, and key.",
                                        "API Key 未保存，请检查名称、API 地址和 Key。")
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
        .onChange(of: supplier) { _, value in name = value.name; endpoint = value.defaultEndpoint }
    }
}
