import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage(AppModel.localeKey) private var identifier = AppModel.defaultLocale
    @State private var locales: [Locale] = []

    var body: some View {
        Form {
            Picker("文字起こしの言語", selection: $identifier) {
                ForEach(options, id: \.self) { Text(name($0)).tag($0) }
            }
            Text("次の文字起こしから使われます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task { locales = await model.queue.supportedLocales() }
    }

    private var options: [String] {
        let all = Set(locales.map { $0.identifier(.bcp47) } + [identifier])
        return all.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    private func name(_ identifier: String) -> String {
        Locale(identifier: "ja").localizedString(forIdentifier: identifier) ?? identifier
    }
}
