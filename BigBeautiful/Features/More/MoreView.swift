import SwiftUI

@MainActor
struct MoreView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                circleCard
                EditorialSectionHeader("The house tools", eyebrow: "Keep it beautiful")
                tool("Statistics", "The shape of your dining life", "chart.bar.xaxis", .stats)
                tool("Settle the Score", "Five questions. About one minute.", "scale.3d", .settleScore)
                tool("Backfill", "Rebuild history from selected photos", "photo.stack", .backfill)
                tool("Merge Duplicates", "Correct the record without losing a visit", "arrow.triangle.merge", .merge)
                tool("Settings & Privacy", "Circle, permissions, iCloud, and preferences", "gearshape", .settings)
                Text("Every score is a living prediction. Every visit is permanent history. Every comparison is evidence rather than law.")
                    .font(BBTheme.display(18, weight: .regular)).foregroundStyle(.secondary).padding(.vertical, 12)
            }.padding(.horizontal, 16).padding(.bottom, 30).readablePageWidth()
        }
        .editorialPage().navigationTitle("More").navigationBarTitleDisplayMode(.inline)
    }

    private var circleCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 4) { Eyebrow("Your circle"); Text(store.activeCircle?.name ?? "The Table").font(BBTheme.display(29)) }; Spacer(); Button("Invite") { router.sheet = .shareCircle }.font(.callout.weight(.bold)) }
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
        }.buttonStyle(.plain).ledgerCard()
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0x6F1D2B
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
