import SwiftUI

/// Workbook identity, matching the web app: ink chrome, warm paper work area,
/// one brass accent.
enum Theme {
    static let ink = Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1D / 255)
    static let ink2 = Color(red: 0x22 / 255, green: 0x25 / 255, blue: 0x2C / 255)
    static let paper = Color(red: 0xF3 / 255, green: 0xF2 / 255, blue: 0xED / 255)
    static let line = Color(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE4 / 255)
    static let muted = Color(red: 0x6B / 255, green: 0x6E / 255, blue: 0x73 / 255)
    static let brass = Color(red: 0xC0 / 255, green: 0x86 / 255, blue: 0x2C / 255)
    static let brassWash = Color(red: 0xF6 / 255, green: 0xEE / 255, blue: 0xDD / 255)
    static let text = Color(red: 0x21 / 255, green: 0x25 / 255, blue: 0x29 / 255)
    static let link = Color(red: 0xD5 / 255, green: 0x00 / 255, blue: 0x1C / 255)
}

/// The small type badge on document rows (RM, TI, SIT…).
struct TypeBadge: View {
    let type: String
    var body: some View {
        Text(type.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.brass)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minWidth: 34)
            .background(Theme.brassWash, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct DocumentRow: View {
    let document: DocumentSummary
    var selected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TypeBadge(type: document.documentType)
            Image(systemName: document.isPDF ? "doc.richtext" : "doc.text")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
            if !document.code.isEmpty {
                Text(document.code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.brass)
            }
            Text(document.title)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.brassWash : Color.white)
        .contentShape(Rectangle())
    }
}

/// Loading / failed / empty states shared by the list screens.
struct StatusView: View {
    let systemImage: String
    let title: String
    var message: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.muted)
            Text(title).font(.headline).foregroundStyle(Theme.text)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One async load with loading / error / value states.
enum Loadable<Value> {
    case loading
    case failed(String)
    case loaded(Value)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
