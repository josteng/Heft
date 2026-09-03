import HeftCore
import SwiftUI

/// Remembered export options.
///
/// App-wide rather than per-vault, like the other settings singletons: page
/// size and scale are a property of the paper someone prints on, not of the
/// notes they keep.
final class PDFExportSettings: ObservableObject {
    static let shared = PDFExportSettings()

    @Published var options: PDFExportOptions { didSet { persist() } }

    private static let key = "dev.stenglein.Heft.export.pdf"

    private init() {
        options = PDFExportOptions(decoding: UserDefaults.standard.data(forKey: Self.key))
    }

    private func persist() {
        UserDefaults.standard.set(options.encoded, forKey: Self.key)
    }
}

/// The options shown inside the save panel.
///
/// An accessory view rather than a separate sheet: choosing where the file
/// goes and choosing what it looks like are one decision, and Obsidian's
/// two-step (settings dialog, then a save panel) asks twice for one export.
struct PDFExportAccessory: View {
    @ObservedObject private var settings = PDFExportSettings.shared

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Page size")
                HStack(spacing: 10) {
                    Picker("", selection: $settings.options.paper) {
                        ForEach(PDFExportOptions.Paper.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Toggle("Landscape", isOn: $settings.options.isLandscape)
                }
            }
            GridRow {
                Text("Margin")
                Picker("", selection: $settings.options.margin) {
                    ForEach(PDFExportOptions.Margin.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .gridColumnAlignment(.leading)
            }
            GridRow {
                Text("Text size")
                HStack(spacing: 10) {
                    Slider(
                        value: $settings.options.bodyPointSize,
                        in: PDFExportOptions.bodySizeRange,
                        step: 0.5
                    )
                    .frame(width: 190)
                    Text(settings.options.bodyPointSize
                        .formatted(.number.precision(.fractionLength(0...1))) + " pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Text("The size body text is printed at. Headings, code and tables "
                     + "keep their proportions to it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 250, alignment: .leading)
            }
            GridRow {
                Color.clear.frame(width: 0, height: 0)
                Toggle("Put the note's name at the top", isOn: $settings.options.includesTitle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
