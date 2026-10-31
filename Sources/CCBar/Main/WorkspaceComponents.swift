import SwiftUI
import CCBarConfiguration

struct SupplierIcon: View {
    let supplier: ModelSupplier
    var size: CGFloat = 28
    var body: some View {
        if let brand = supplier.brand {
            ServiceTile(logoName: brand.logoName, fallback: String(supplier.name.prefix(1)),
                        tint: BrandColorResolver.color(for: brand, settings: SettingsStore.shared),
                        size: size, logoSize: size * 0.65, cornerRadius: size * 0.22)
        } else {
            Image(systemName: "server.rack").frame(width: size, height: size).foregroundStyle(.secondary)
        }
    }
}

struct WorkspaceHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Spacer()
            actions()
        }
    }
}


/// One value owns both presentation and its input, avoiding stale first-presentation state.
struct EditorRequest<Value>: Identifiable {
    let id = UUID()
    let value: Value?
}
