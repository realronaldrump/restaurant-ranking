import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        let visits = store.visits.filter(\.isAlive)
        ScrollView {
            VStack(alignment: .leading, spacing: BBTheme.Spacing.section) {
                masthead(visits)
                logButton
                pendingRatings
                topTable
                settleCard
                recentHistory(visits)
            }
            .padding(.horizontal, BBTheme.Spacing.page)
            .padding(.bottom, 36)
            .readablePageWidth()
        }
        .editorialPage()
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func masthead(_ visits: [VisitEntity]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow(rosterEyebrow)
                Spacer(minLength: 12)
                Label(
                    Date.now.formatted(.dateTime.month(.abbreviated).day()),
                    systemImage: "calendar"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            Text("Big Beautiful Restaurant Log")
                .font(BBTheme.display(36))
                .tracking(-0.7)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("app-title")
            Divider().overlay(BBTheme.strongHairline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { visitStats(visits) }
                VStack(alignment: .leading, spacing: 8) { visitStats(visits) }
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private func visitStats(_ visits: [VisitEntity]) -> some View {
        Label("\(visits.count) \(visits.count == 1 ? "outing" : "outings")", systemImage: "fork.knife")
        Label("\(Set(visits.compactMap { $0.location?.id }).count) restaurants", systemImage: "mappin")
        Label("Since \(establishedYear(visits))", systemImage: "clock")
    }

    private var isShared: Bool { store.circleMembers.count > 1 }

    private var rosterEyebrow: String {
        guard isShared else { return "Your log" }
        return "\(store.activeCircle?.name ?? "Shared log") · \(store.circleMembers.count) people"
    }

    private func establishedYear(_ visits: [VisitEntity]) -> String {
        let earliest = visits.min(by: { $0.date < $1.date })?.date ?? .now
        return String(Calendar.current.component(.year, from: earliest))
    }

    private var logButton: some View {
        Button { router.sheet = .logMeal; Haptics.impact() } label: {
            ZStack(alignment: .trailing) {
                LinearGradient(
                    colors: [BBTheme.oxbloodFill, BBTheme.oxbloodFill.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [BBTheme.cream.opacity(0.14), BBTheme.cream.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 92
                )
                .frame(width: 184, height: 184)
                .offset(x: 62, y: -54)
                .accessibilityHidden(true)
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Log an outing").font(BBTheme.display(32)).foregroundStyle(BBTheme.cream)
                        Text("Pick the restaurant, then your reaction.")
                            .font(.callout)
                            .foregroundStyle(BBTheme.cream.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .frame(width: 50, height: 50)
                        .background(BBTheme.cream.opacity(0.13), in: Circle())
                }
                .padding(22)
            }
            .foregroundStyle(BBTheme.cream)
            .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                    .stroke(BBTheme.cream.opacity(0.13), lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("log-meal-button")
        .accessibilityHint("Opens the outing logging flow")
    }

    @ViewBuilder private var pendingRatings: some View {
        let pending = store.pendingVisits().filter(\.isAlive)
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Waiting for your reaction")
                ForEach(pending.prefix(2), id: \.objectID) { visit in
                    Button { router.sheet = .rateVisit(visit.id) } label: {
                        HStack(spacing: 14) {
                            IconTile(symbol: "person.2.wave.2.fill")
                            VStack(alignment: .leading) {
                                Text(visit.location?.name ?? "Shared outing").font(.headline)
                                Text("\(visit.dateKnowledge == .known ? visit.date.formatted(date: .abbreviated, time: .shortened) : "Date unknown") · Add your diner entry")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .editorialCard(padding: 14)
                }
            }
        }
    }

    private var topTable: some View {
        let scores = Array(store.ranked().prefix(3))
        return VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("Your top three", actionTitle: "See full ranking") { router.selectedTab = .rankings }
            if scores.isEmpty {
                EmptyLogView(title: "Nothing ranked yet", message: "Log an outing to start your ranking.", symbol: "list.number")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(scores.enumerated()), id: \.element.id) { index, item in
                        Button { router.logPath.append(.location(item.id, rankingScope: store.currentPerson.map { .person($0.id) })) } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .font(BBTheme.score(22))
                                    .foregroundStyle(index == 0 ? BBTheme.cream : BBTheme.oxblood)
                                    .frame(width: 38, height: 38)
                                    .background(index == 0 ? BBTheme.oxbloodFill : BBTheme.oxblood.opacity(0.08), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.location.name)
                                        .font(BBTheme.display(21))
                                        .lineLimit(2)
                                        .layoutPriority(1)
                                    Text(item.location.category.shortTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                ScoreMark(score: item.score, size: 18, provisional: item.isProvisional)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < scores.count - 1 { Divider() }
                    }
                }.editorialCard()
            }
        }
    }

    @ViewBuilder private var settleCard: some View {
        let promptCount = store.settleScorePrompts().count
        if promptCount > 0 { settleCardBody(count: promptCount) }
    }

    private func settleCardBody(count: Int) -> some View {
        Button {
            router.selectedTab = .settle
        } label: {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(BBTheme.oxblood.opacity(0.08)).frame(width: 64, height: 64)
                    Circle().stroke(BBTheme.oxblood.opacity(0.24), lineWidth: 1).frame(width: 64, height: 64)
                    Text("\(count)").font(BBTheme.score(28)).foregroundStyle(BBTheme.oxblood)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settle the Score").font(BBTheme.display(25))
                    Text(count == 1 ? "1 question about a close call." : "\(count) questions about close calls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        }
        .buttonStyle(.pressable)
        .editorialCard()
    }

    @ViewBuilder private func recentHistory(_ visits: [VisitEntity]) -> some View {
        if !visits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader(isShared ? "Recent outings" : "Your recent outings", actionTitle: "History") { router.selectedTab = .history }
                let recent = Array(visits.prefix(4))
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.objectID) { index, visit in
                        NavigationLink(value: AppRoute.visit(visit.id)) {
                            VisitRow(visit: visit).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if index < recent.count - 1 { Divider() }
                    }
                }
                .editorialCard(padding: 12)
            }
        }
    }
}

struct VisitRow: View {
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    @ViewBuilder var body: some View {
        if !visit.isAlive {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        let photos = visit.photoArray
        let ratings = store.ratings(for: visit)
        return HStack(spacing: 13) {
            ZStack {
                if let photo = photos.first {
                    PhotoImage(photo: photo)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BBTheme.oxblood.opacity(0.08))
                        .frame(width: 56, height: 56)
                    Image(systemName: visit.location?.category.symbol ?? "fork.knife").foregroundStyle(BBTheme.oxblood)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(visit.location?.name ?? "Unknown restaurant").font(.headline)
                HStack(spacing: 5) {
                    Text(visit.dateKnowledge == .known ? visit.date.formatted(date: .abbreviated, time: .shortened) : "Date unknown")
                    if let type = visit.visitType { Text("· \(type.rawValue)") }
                    if !photos.isEmpty { Image(systemName: "photo.fill") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            reactionMark(ratings)
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    /// Names both the reaction and its owner so history does not rely on icon
    /// recognition or color to distinguish the current person's entry.
    @ViewBuilder private func reactionMark(_ ratings: [RatingEntity]) -> some View {
        let mine = store.currentPerson.flatMap { person in ratings.first { $0.personID == person.id } }
        if let mine {
            reactionLabel(mine, owner: "You", emphasized: true)
        } else if let other = ratings.first {
            let name = store.person(id: other.personID)?.name ?? "Someone"
            reactionLabel(other, owner: name, emphasized: false)
        } else {
                Text("No reaction yet")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("No reaction yet")
        }
    }

    private func reactionLabel(_ rating: RatingEntity, owner: String, emphasized: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(rating.reaction.compactTitle, systemImage: rating.reaction.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(emphasized ? BBTheme.oxblood : BBTheme.ink)
            Text(owner)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(owner), \(rating.reaction.title)")
    }
}
