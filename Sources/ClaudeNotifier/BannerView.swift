import SwiftUI
import AppKit

// MARK: - System material backing

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

// MARK: - Banner

struct BannerView: View {
    let id: String
    let event: EventRequest
    let onDecision: (String, UserDecision) -> Void

    // MARK: Accent

    private var accentColor: Color {
        if event.error != nil { return .red }
        switch event.kind {
        case .permission:   return Color(red: 1.00, green: 0.58, blue: 0.00)   // orange
        case .question:     return Color(red: 0.04, green: 0.52, blue: 1.00)   // blue
        case .stop:         return Color(red: 0.19, green: 0.82, blue: 0.35)   // green
        case .notification: return Color.secondary
        }
    }

    private var iconName: String {
        if event.error != nil { return "exclamationmark.triangle.fill" }
        switch event.kind {
        case .permission:   return "lock.shield.fill"
        case .question:     return "questionmark.bubble.fill"
        case .stop:         return "checkmark.circle.fill"
        case .notification: return "bell.fill"
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            summaryBlock
            if let err = event.error, !err.isEmpty { errorRow(err) }
            buttonRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 340, alignment: .leading)
        .background(
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { onDecision(id, .focus) }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let sub = contextLine {
                    Text(sub)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button { onDecision(id, .dismiss) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    // MARK: Summary / code block

    @ViewBuilder
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Tool badge (permission only)
            if event.kind == .permission, let tool = event.tool {
                HStack(spacing: 5) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9))
                        .foregroundColor(accentColor)
                    Text(tool)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(accentColor)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            // Command / description
            if event.kind == .permission {
                Text(event.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            } else {
                Text(event.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Error

    private func errorRow(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(.red)
                .padding(.top, 1)
            Text(err)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.red)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttonRow: some View {
        switch event.kind {
        case .permission:
            HStack(spacing: 7) {
                nativeButton("Yes",       role: .confirm) { onDecision(id, .allow) }
                nativeButton("Session",   role: .session) { onDecision(id, .allowSession) }
                nativeButton("No",        role: .cancel)  { onDecision(id, .deny) }
            }
        case .question:
            nativeButton("Focus Session", role: .session) { onDecision(id, .focus) }
        case .stop, .notification:
            EmptyView()
        }
    }

    private enum ButtonRole { case confirm, session, cancel }

    private func nativeButton(
        _ label: String,
        role: ButtonRole,
        action: @escaping () -> Void
    ) -> some View {
        let fg: Color
        let bg: Color
        switch role {
        case .confirm: fg = .white;    bg = Color(red: 0.19, green: 0.82, blue: 0.35)
        case .session: fg = .white;    bg = Color(red: 0.04, green: 0.52, blue: 1.00)
        case .cancel:  fg = Color(nsColor: .labelColor); bg = Color(nsColor: .controlColor)
        }

        return Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(fg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private var contextLine: String? {
        if let c = event.context, !c.isEmpty { return c }
        if let w = event.cwd,     !w.isEmpty { return shortenPath(w) }
        return nil
    }

    private func shortenPath(_ p: String) -> String {
        p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
