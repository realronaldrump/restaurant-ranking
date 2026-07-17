import SwiftUI

@MainActor
struct MoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                circleCard
                EditorialSectionHeader("Tools", eyebrow: "Restaurant log")
                tool("Statistics", "A summary of your visits and ratings", "chart.bar.xaxis", .stats)
                tool("Settle the Score", "Answer up to five quick questions", "scale.3d", .settleScore)
                tool("Backfill", "Add past visits from selected photos", "photo.stack", .backfill)
                tool("Merge Duplicates", "Combine two records without losing visits", "arrow.triangle.merge", .merge)
                tool("Settings & Privacy", "Circle, permissions, iCloud, and preferences", "gearshape", .settings)
            }.padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("More").navigationBarTitleDisplayMode(.inline)
    }

    private var circleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 4) { Eyebrow("Your circle"); Text(store.activeCircle?.name ?? "Your Circle").font(BBTheme.display(29)) }; Spacer(); Button("Invite") { router.sheet = .shareCircle }.font(.callout.weight(.bold)) }
            HStack(spacing: -8) {
                ForEach(store.circleMembers) { person in
                    Text(person.name.prefix(1).uppercased()).font(.headline).foregroundStyle(BBTheme.paper)
                        .frame(width: 48, height: 48).background(Color(hex: person.colorHex), in: Circle()).overlay(Circle().stroke(BBTheme.paper, lineWidth: 2))
                        .accessibilityLabel(person.name)
                }
                if store.circleMembers.count < 6 { Image(systemName: "plus").frame(width: 48, height: 48).background(BBTheme.ink.opacity(0.07), in: Circle()).overlay(Circle().stroke(BBTheme.paper, lineWidth: 2)) }
                Spacer()
                Text("\(store.circleMembers.count) / 6").font(.caption).foregroundStyle(.secondary)
            }
        }.ledgerCard()
    }

    private func tool(_ title: String, _ detail: String, _ symbol: String, _ route: AppRoute) -> some View {
        Button { router.morePath.append(route) } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.title3).foregroundStyle(BBTheme.oxblood).frame(width: 34)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.pressable).ledgerCard()
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x6F1D2B
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
