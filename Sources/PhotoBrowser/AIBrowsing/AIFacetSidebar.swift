import SwiftUI
import BrowserCore

struct AIFacetSidebar: View {
    @EnvironmentObject private var store: AIBrowseStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("识别状态")).font(.caption).foregroundStyle(.secondary)
                ForEach(store.states) { state in
                    Button { store.filter.state = state.id } label: {
                        HStack {
                            Text(L10n.lookup(state.name)); Spacer(); Text("\(store.counts[state.id] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        }.padding(8).background(RoundedRectangle(cornerRadius: 6).fill(store.filter.state == state.id ? Color.blue.opacity(0.2) : .clear))
                    }.buttonStyle(.plain)
                }
                Divider()
                if store.filter.state == "processing.succeeded" {
                    Text(L10n.text("同类标签取并集，不同字段取交集")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    ForEach(store.fields.sorted { rank($0.id) < rank($1.id) }) { field in
                        DisclosureGroup(isExpanded: Binding(get: { store.expanded.contains(field.id) }, set: {
                            if $0 { store.expanded.insert(field.id); store.loadFacet(field.id) } else { store.expanded.remove(field.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField(L10n.text("搜索此字段的标签"), text: Binding(get: { store.facetSearch[field.id] ?? "" }, set: {
                                    store.facetSearch[field.id] = $0; store.loadFacet(field.id)
                                })).textFieldStyle(.roundedBorder)
                                if let error = store.facetErrors[field.id] { Text(error).font(.caption2).foregroundStyle(.orange) }
                                else if let rows = store.facets[field.id] {
                                    ForEach(rows) { row in
                                        Button {
                                            store.remember(field: field.id, code: row.code, name: row.name)
                                            store.toggle(field.id, code: row.code)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                Image(systemName: store.filter.tags[field.id]?.contains(row.code) == true ? "checkmark.square.fill" : "square").foregroundStyle(.blue)
                                                Text(row.name).lineLimit(2).multilineTextAlignment(.leading)
                                                Spacer(minLength: 0); Text("\(row.count)").monospacedDigit().foregroundStyle(.secondary)
                                            }.font(.system(size: 11)).padding(.vertical, 3)
                                        }.buttonStyle(.plain).help(row.name)
                                    }
                                    if rows.count >= 10 {
                                        Button(L10n.text(store.expandedLists.contains(field.id) ? "收起" : "更多标签")) {
                                            if store.expandedLists.contains(field.id) { store.expandedLists.remove(field.id) } else { store.expandedLists.insert(field.id) }
                                            store.loadFacet(field.id)
                                        }.font(.caption)
                                    }
                                } else { ProgressView().controlSize(.mini) }
                            }.padding(.top, 8)
                        } label: { Text(L10n.lookup(field.name)).font(.system(size: 12, weight: .semibold)) }
                        .disclosureGroupStyle(AIFacetDisclosureStyle())
                    }
                } else {
                    Text(L10n.text("此状态支持按文件名和目录搜索，返回已识别后恢复标签筛选。")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14)
        }
    }
    private func rank(_ field: String) -> Int {
        // Layout order only; vocabulary and term codes always come from recognition metadata.
        if field == "scene_codes" { return 0 }; if field == "subject_codes" { return 1 }; if field == "environment_codes" { return 2 }
        return 3 + (store.fields.firstIndex(where: { $0.id == field }) ?? 0)
    }
}

private struct AIFacetDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(L10n.text(configuration.isExpanded ? "展开" : "收起"))
            if configuration.isExpanded { configuration.content }
        }
    }
}
