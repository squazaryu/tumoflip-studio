import SwiftUI

enum StudioLayout {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cornerRadius: CGFloat = 8
}

struct StudioPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let actions: Actions

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)
            actions
        }
        .padding(.horizontal, StudioLayout.pagePadding)
        .padding(.vertical, 13)
        .background(.bar)
    }
}

extension StudioPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String, systemImage: String) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) {
            EmptyView()
        }
    }
}

struct StudioPanel<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: StudioLayout.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: StudioLayout.cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
    }
}

struct StudioSectionHeader: View {
    let title: String
    let systemImage: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StudioStatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
    }
}

struct StudioConsole: View {
    let text: String
    let placeholder: String
    var minHeight: CGFloat = 180

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .frame(minHeight: minHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: StudioLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioLayout.cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
