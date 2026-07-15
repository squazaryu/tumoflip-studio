import SwiftUI
import MarauderKit

/// Единая палитра и переиспользуемые UI-компоненты приложения.
enum Theme {
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let panel2 = Color(nsColor: .textBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let textPrimary = Color.primary
    static let textDim = Color.secondary
    static let consoleBackground = Color(nsColor: .textBackgroundColor)
    static let consoleText = Color.primary.opacity(0.86)

    static func severity(_ s: Severity) -> Color {
        switch s {
        case .critical: return Color(red: 0.74, green: 0.42, blue: 1.0)
        case .high:     return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .medium:   return Color(red: 1.0, green: 0.70, blue: 0.33)
        case .low:      return Color(red: 0.48, green: 0.85, blue: 0.56)
        }
    }
    static func rssi(_ v: Int?) -> Color {
        guard let v else { return textDim }
        if v >= -55 { return Color(red: 0.48, green: 0.85, blue: 0.56) }
        if v >= -75 { return Color(red: 1.0, green: 0.70, blue: 0.33) }
        return Color(red: 1.0, green: 0.42, blue: 0.42)
    }
}

/// карточка-контейнер
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        StudioPanel(padding: padding) {
            content
        }
    }
}

/// заголовок секции
struct SectionTitle: View {
    let text: String
    var systemImage: String? = nil
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            if let trailing { trailing }
        }
    }
}

/// карточка-метрика (KPI)
struct StatCard: View {
    let label: String
    let value: String
    var icon: String = "circle"
    var color: Color = .white
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text(label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: StudioLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: StudioLayout.cornerRadius, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}
