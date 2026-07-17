import SwiftUI

@MainActor
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                masthead
                logButton
                pendingRatings
                topTable
                settleCard
                recentHistory
            }
            .padding(.horizontal, 18).padding(.bottom, 32).readablePageWidth()
        }
        .editorialPage()
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mastheadPossessive).font(BBTheme.eyebrow).foregroundStyle(BBTheme.oxblood)
                    Text("Big Beautiful").font(BBTheme.display(43)).tracking(-1.1)
                    Text("Restaurant Ranking App").font(BBTheme.display(23, weight: .regular)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date.now, format: .dateTime.month(.abbreviated).day())
                    .font(BBTheme.display(17)).padding(.top, 7)
            }
            Divider().overlay(BBTheme.ink)
            HStack { Text("THE PERSONAL DINING LEDGER").font(.caption2.weight(.bold)).tracking(1.5); Spacer(); Text("EST. \(establishedYear)").font(.caption2.weight(.bold)).tracking(1.5) }
        }
        .padding(.top, 12)
    }

    private var mastheadPossessive: String {
        let name = store.currentPerson?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return "DAVIS’S" }
        return "\(name.uppercased())’S"
    }

    private var establishedYear: String {
        let earliest = store.visits.map(\.date).min() ?? .now
        return String(Calendar.current.component(.year, from: earliest))
    }

    private var logButton: some View {
        Button { router.sheet = .logMeal; Haptics.impact() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("THE THREE-TAP RITUAL")
                        .font(BBTheme.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(BBTheme.paper.opacity(0.8))
                    Text("Log a Meal").font(BBTheme.display(34)).foregroundStyle(BBTheme.paper)
                    Text("Place. Reaction. Done.").font(.callout).foregroundStyle(BBTheme.paper.opacity(0.72))
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.title2)
            }
            .padding(22).foregroundStyle(BBTheme.paper).background(BBTheme.oxblood)
        }
        .buttonStyle(.plain).accessibilityIdentifier("log-meal-button")
    }

    @ViewBuilder private var pendingRatings: some View {
        let pending = store.pendingVisits()
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                EditorialSectionHeader("Your opinion, please", eyebrow: "Shared visits")
                ForEach(pending.prefix(2)) { visit in
                    Button { router.sheet = .rateVisit(visit.id) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "person.2.wave.2.fill").foregroundStyle(BBTheme.oxblood)
                            VStack(alignment: .leading) {
                                Text(visit.location?.name ?? "Shared visit").font(.headline)
                                Text("\(visit.date.formatted(date: .abbreviated, time: .omitted)) · Rate this visit").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }
                    }.buttonStyle(.plain).ledgerCard()
                }
            }
        }
    }

    private var topTable: some View {
        let scores = Array(store.ranked().prefix(3))
        return VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("The top table", eyebrow: "Right now", actionTitle: "Full ranking") { router.selectedTab = .rankings }
            if scores.isEmpty {
                EmptyLedgerView(title: "No table yet", message: "Log one meal and the ranking begins.", symbol: "chair.lounge")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(scores.enumerated()), id: \.element.id) { index, item in
                        Button { router.ledgerPath.append(.location(item.id)) } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)").font(BBTheme.score(26)).frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.location.name).font(.headline)
                                    Text(item.location.category.shortTitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); ScoreMark(score: item.score, size: 31, provisional: item.isProvisional)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(Color.clear)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        if index < scores.count - 1 { Divider() }
                    }
                }.ledgerCard()
            }
        }
    }

    @ViewBuilder private var settleCard: some View {
        if store.ranked().count >= 2 { settleCardBody }
    }

    private var settleCardBody: some View {
        let count = store.settleQuestions().count
        return Button { router.ledgerPath.append(.settleScore) } label: {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(BBTheme.oxblood, lineWidth: 1).frame(width: 62, height: 62)
                    Text("\(count)").font(BBTheme.score(28)).foregroundStyle(BBTheme.oxblood)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("One minute")
                    Text("Settle the Score").font(BBTheme.display(25))
                    Text(count == 0 ? "The ledger is unusually certain." : "A few close calls could use your judgment.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "arrow.right")
            }.padding(.vertical, 4)
        }.buttonStyle(.plain).ledgerCard()
    }

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorialSectionHeader("Recently entered", eyebrow: "The record", actionTitle: "History") { router.selectedTab = .history }
            ForEach(store.visits.prefix(4)) { visit in
                NavigationLink(value: AppRoute.visit(visit.id)) { VisitRow(visit: visit) }.buttonStyle(.plain)
            }
        }
    }
}

struct VisitRow: View {
    @Environment(AppStore.self) private var store
    let visit: VisitEntity
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                if let photo = visit.photoArray.first {
                    PhotoImage(photo: photo).frame(width: 54, height: 54).clipped()
                } else {
                    Rectangle().fill(BBTheme.ink.opacity(0.06)).frame(width: 54, height: 54)
                    Image(systemName: visit.location?.category.symbol ?? "fork.knife").foregroundStyle(BBTheme.oxblood)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(visit.location?.name ?? "Unknown place").font(.headline)
                HStack(spacing: 5) {
                    Text(visit.date.formatted(date: .abbreviated, time: .omitted))
                    if let type = visit.visitType { Text("· \(type.rawValue)") }
                    if !visit.photoArray.isEmpty { Image(systemName: "photo.fill") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            reactionMark
        }
        .contentShape(Rectangle()).padding(.vertical, 4)
    }

    /// The current person's verdict in oxblood; another diner's verdict, dimmed,
    /// when only they have rated; UNRATED when nobody has.
    @ViewBuilder private var reactionMark: some View {
        let mine = store.currentPerson.flatMap { visit.rating(for: $0.id) }
        if let mine {
            Image(systemName: mine.reaction.symbol).foregroundStyle(BBTheme.oxblood).accessibilityLabel(mine.reaction.rawValue)
        } else if let other = visit.ratingArray.first {
            let name = store.people.first { $0.id == other.personID }?.name ?? "Someone"
            Image(systemName: other.reaction.symbol).foregroundStyle(.secondary)
                .accessibilityLabel("\(other.reaction.rawValue), rated by \(name)")
        } else {
            Text("UNRATED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }
}
