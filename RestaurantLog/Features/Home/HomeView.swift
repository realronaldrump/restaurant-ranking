import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        let visits = store.visits
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
    }

    private func masthead(_ visits: [VisitEntity]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("\(mastheadPossessive) dining ledger")
                Spacer(minLength: 12)
                Label(
                    Date.now.formatted(.dateTime.month(.abbreviated).day()),
                    systemImage: "calendar"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(BBTheme.surface, in: Capsule())
            }
            Text("Big Beautiful\nRestaurant Log")
                .font(BBTheme.display(42))
                .tracking(-1)
                .lineSpacing(-3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("app-title")
            Text("A private record of the meals, places, and opinions you want to remember.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
            Divider().overlay(BBTheme.strongHairline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { ledgerStats(visits) }
                VStack(alignment: .leading, spacing: 8) { ledgerStats(visits) }
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private func ledgerStats(_ visits: [VisitEntity]) -> some View {
        Label("\(visits.count) \(visits.count == 1 ? "visit" : "visits")", systemImage: "fork.knife")
        Label("\(Set(visits.compactMap { $0.location?.id }).count) places", systemImage: "mappin")
        Label("Since \(establishedYear(visits))", systemImage: "clock")
    }

    private var mastheadPossessive: String {
        let name = store.currentPerson?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "YOUR" }
        return "\(name.uppercased())’S"
    }

    private func establishedYear(_ visits: [VisitEntity]) -> String {
        let earliest = visits.min(by: { $0.date < $1.date })?.date ?? .now
        return String(Calendar.current.component(.year, from: earliest))
    }

    private var logButton: some View {
        Button { router.sheet = .logMeal; Haptics.impact() } label: {
            ZStack(alignment: .trailing) {
                LinearGradient(
                    colors: [BBTheme.oxblood, BBTheme.oxblood.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .stroke(BBTheme.paper.opacity(0.13), lineWidth: 1)
                    .frame(width: 150, height: 150)
                    .offset(x: 48, y: -44)
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NEW VISIT")
                            .font(BBTheme.eyebrow)
                            .tracking(1.2)
                            .foregroundStyle(BBTheme.paper.opacity(0.78))
                        Text("Log a meal").font(BBTheme.display(32)).foregroundStyle(BBTheme.paper)
                        Text("Photo or place, then your reaction.")
                            .font(.callout)
                            .foregroundStyle(BBTheme.paper.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .frame(width: 50, height: 50)
                        .background(BBTheme.paper.opacity(0.13), in: Circle())
                }
                .padding(22)
            }
            .foregroundStyle(BBTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BBTheme.Radius.card, style: .continuous)
                    .stroke(BBTheme.paper.opacity(0.13), lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("log-meal-button")
        .accessibilityHint("Opens the quick meal logging flow")
    }

    @ViewBuilder private var pendingRatings: some View {
        let pending = store.pendingVisits()
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Your opinion, please", eyebrow: "Shared visits")
                ForEach(pending.prefix(2), id: \.objectID) { visit in
                    Button { router.sheet = .rateVisit(visit.id) } label: {
                        HStack(spacing: 14) {
                            IconTile(symbol: "person.2.wave.2.fill")
                            VStack(alignment: .leading) {
                                Text(visit.location?.name ?? "Shared visit").font(.headline)
                                Text("\(visit.date.formatted(date: .abbreviated, time: .omitted)) · Add your reaction")
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
            EditorialSectionHeader("The top table", eyebrow: "Right now", actionTitle: "Full ranking") { router.selectedTab = .rankings }
            if scores.isEmpty {
                EmptyLogView(title: "No table yet", message: "Log one meal and the ranking begins.", symbol: "chair.lounge")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(scores.enumerated()), id: \.element.id) { index, item in
                        Button { router.logPath.append(.location(item.id)) } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .font(BBTheme.score(22))
                                    .foregroundStyle(index == 0 ? BBTheme.paper : BBTheme.oxblood)
                                    .frame(width: 38, height: 38)
                                    .background(index == 0 ? BBTheme.oxblood : BBTheme.oxblood.opacity(0.08), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.location.name).font(.headline)
                                    Text(item.location.category.shortTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); ScoreMark(score: item.score, size: 31, provisional: item.isProvisional)
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
            router.logPath.append(.settleScore)
        } label: {
            HStack(spacing: 18) {
                ZStack {
                    Circle().fill(BBTheme.oxblood.opacity(0.08)).frame(width: 64, height: 64)
                    Circle().stroke(BBTheme.oxblood.opacity(0.24), lineWidth: 1).frame(width: 64, height: 64)
                    Text("\(count)").font(BBTheme.score(28)).foregroundStyle(BBTheme.oxblood)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(count == 1 ? "1 question" : "\(count) questions")
                    Text("Settle the Score").font(BBTheme.display(25))
                    Text("Clarify a few close rankings.").font(.caption).foregroundStyle(.secondary)
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
                EditorialSectionHeader("Recently entered", eyebrow: "The record", actionTitle: "History") { router.selectedTab = .history }
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
        if visit.managedObjectContext == nil || visit.isDeleted {
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
                Text(visit.location?.name ?? "Unknown place").font(.headline)
                HStack(spacing: 5) {
                    Text(visit.date.formatted(date: .abbreviated, time: .omitted))
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

    /// The current person's verdict in oxblood; another diner's verdict, dimmed,
    /// when only they have rated; UNRATED when nobody has.
    @ViewBuilder private func reactionMark(_ ratings: [RatingEntity]) -> some View {
        let mine = store.currentPerson.flatMap { person in ratings.first { $0.personID == person.id } }
        if let mine {
            Image(systemName: mine.reaction.symbol).foregroundStyle(BBTheme.oxblood).accessibilityLabel(mine.reaction.rawValue)
        } else if let other = ratings.first {
            let name = store.person(id: other.personID)?.name ?? "Someone"
            Image(systemName: other.reaction.symbol).foregroundStyle(.secondary)
                .accessibilityLabel("\(other.reaction.rawValue), rated by \(name)")
        } else {
            Text("UNRATED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}
