import XCTest

@MainActor
final class RestaurantLogUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-resetForUITests", "-seedSampleData"]
        app.launch()
        XCTAssertTrue(
            app.buttons["log-meal-button"].waitForExistence(timeout: 12),
            "The first launch must reach usable content without terminating and reopening the app."
        )
    }

    func testSeededLogNavigatesPrimaryTabs() {
        XCTAssertTrue(app.staticTexts["app-title"].exists)
        XCTAssertTrue(app.tabBars.buttons["Log"].exists)

        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["George"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["Michelle"].exists)
        app.segmentedControls.buttons["Circle"].tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Everyone"].exists)
        XCTAssertTrue(app.buttons["History filter, All outings"].exists)

        app.tabBars.buttons["Settle"].tap()
        XCTAssertTrue(app.navigationBars["Settle the Score"].waitForExistence(timeout: 5))

        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Activity"].exists)
        XCTAssertTrue(app.staticTexts["Statistics"].exists)
        XCTAssertTrue(app.staticTexts["Want to Try"].exists)
        XCTAssertTrue(app.staticTexts["Find outings in photos"].exists)
        XCTAssertFalse(app.staticTexts["Merge Duplicates"].exists)
    }

    func testActivityInboxIsReachableAndStartsQuiet() {
        app.buttons["notifications-button"].tap()

        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["notifications-empty"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["mark-all-notifications-read"].exists)
    }

    func testHistoryCanSortByCity() {
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        let sortButton = app.buttons["history-sort"]
        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(sortButton.label.contains("Newest first"))
        sortButton.tap()

        let cityOption = app.buttons["City"]
        XCTAssertTrue(cityOption.waitForExistence(timeout: 3))
        cityOption.tap()

        XCTAssertTrue(sortButton.waitForExistence(timeout: 3))
        XCTAssertTrue(sortButton.label.contains("City"))
        XCTAssertTrue(app.staticTexts["Salt Lake City"].waitForExistence(timeout: 3))
    }

    func testRankingsCanBeViewedByCity() {
        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))

        let viewButton = app.buttons["ranking-view"]
        XCTAssertTrue(viewButton.waitForExistence(timeout: 3))
        XCTAssertTrue(viewButton.label.contains("Ranking"))
        viewButton.tap()

        let cityOption = app.buttons["City"]
        XCTAssertTrue(cityOption.waitForExistence(timeout: 3))
        cityOption.tap()

        XCTAssertTrue(viewButton.waitForExistence(timeout: 3))
        XCTAssertTrue(viewButton.label.contains("City"))
        XCTAssertTrue(app.staticTexts["Salt Lake City"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Rank 1 in Salt Lake City")
            ).firstMatch.exists
        )
    }

    func testRankingsMergeEquivalentCityLabelsIntoOneSection() {
        app.terminate()
        app.launchArguments = [
            "-resetForUITests",
            "-seedSampleData",
            "-seedRankingCityNormalizationData"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["log-meal-button"].waitForExistence(timeout: 12))

        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))
        app.buttons["ranking-view"].tap()
        XCTAssertTrue(app.buttons["City"].waitForExistence(timeout: 3))
        app.buttons["City"].tap()

        let wacoHeading = app.staticTexts["Waco, TX"]
        for _ in 0..<8 where !wacoHeading.isHittable { app.swipeUp() }
        XCTAssertTrue(wacoHeading.waitForExistence(timeout: 3))

        let wacoRows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "in Waco, TX")
        )
        XCTAssertGreaterThanOrEqual(wacoRows.count, 2)
    }

    func testSettleRoundReachesCompletionAfterFifthPrompt() {
        app.terminate()
        app.launchArguments = [
            "-resetForUITests",
            "-seedSampleData",
            "-seedSettleRoundData"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["log-meal-button"].waitForExistence(timeout: 12))

        app.tabBars.buttons["Settle"].tap()
        XCTAssertTrue(app.navigationBars["Settle the Score"].waitForExistence(timeout: 5))

        for question in 1...5 {
            XCTAssertTrue(app.staticTexts["QUESTION \(question) OF 5"].waitForExistence(timeout: 3))
            app.buttons["Skip"].tap()
        }

        XCTAssertTrue(
            app.buttons["settle-continue-button"].waitForExistence(timeout: 3),
            "Completing question five must show the round checkpoint without terminating the app."
        )
    }

    func testLongRestaurantNameDoesNotCollapseRankingScoreColumn() {
        app.terminate()
        app.launchArguments = [
            "-resetForUITests",
            "-seedSampleData",
            "-seedRankingLayoutStressData"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["log-meal-button"].waitForExistence(timeout: 12))

        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Higher scores mean you’re more likely to go back."].exists)

        let restaurantName = "Mi Mexico Family Mexican Restaurant - Glenwood"
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", restaurantName)
        ).firstMatch
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }

        XCTAssertTrue(row.exists)
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<5 where row.frame.maxY > tabBar.frame.minY { app.swipeUp() }
        XCTAssertTrue(row.label.localizedCaseInsensitiveContains("return score"))
        XCTAssertLessThan(
            row.frame.height,
            150,
            "A long restaurant name must wrap without turning the score into a vertical column."
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Long restaurant ranking row"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRankingComparisonCanBeReviewedModifiedAndUndone() {
        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))
        app.buttons["Overall"].tap()

        let evidence = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                "Normal Ice Cream",
                "review comparisons"
            )
        ).firstMatch
        for _ in 0..<8 where !evidence.isHittable { app.swipeUp() }
        XCTAssertTrue(evidence.waitForExistence(timeout: 3))
        evidence.tap()

        XCTAssertTrue(app.navigationBars["Comparisons"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Normal Ice Cream"].exists)
        let yokoChoice = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Yoko Ramen")
        ).firstMatch
        XCTAssertTrue(yokoChoice.waitForExistence(timeout: 3))
        yokoChoice.tap()
        XCTAssertTrue(yokoChoice.label.localizedCaseInsensitiveContains("selected"))

        let undo = app.buttons.matching(
            NSPredicate(format: "label == %@", "Undo comparison")
        ).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(app.staticTexts["Undo this comparison?"].waitForExistence(timeout: 3))
        app.buttons["Undo comparison"].tap()

        XCTAssertTrue(app.staticTexts["No comparisons"].waitForExistence(timeout: 3))
    }

    func testAppearancePreferenceChangesAndPersists() {
        openAppearanceSettings()

        let appearancePicker = app.segmentedControls["appearance-picker"]
        for _ in 0..<6 where !appearancePicker.exists { app.swipeUp() }
        XCTAssertTrue(appearancePicker.waitForExistence(timeout: 3))
        appearancePicker.buttons["Dark"].tap()
        XCTAssertTrue(appearancePicker.buttons["Dark"].isSelected)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["log-meal-button"].waitForExistence(timeout: 8))
        openAppearanceSettings()

        let persistedPicker = app.segmentedControls["appearance-picker"]
        for _ in 0..<6 where !persistedPicker.exists { app.swipeUp() }
        XCTAssertTrue(persistedPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(persistedPicker.buttons["Dark"].isSelected)
        persistedPicker.buttons["System"].tap()
    }

    func testSettingsFooterShowsVersionAndReleaseDate() {
        openAppearanceSettings()

        let footer = app.staticTexts["app-version-footer"]
        for _ in 0..<10 where !footer.exists { app.swipeUp() }

        XCTAssertTrue(footer.waitForExistence(timeout: 3))
        XCTAssertNotNil(
            footer.label.range(
                of: #"^Big Beautiful Restaurant Log [0-9]+\.[0-9]+(?:\.[0-9]+)? \(build [0-9]+\) • Released August 3, 2026$"#,
                options: .regularExpression
            )
        )
    }

    func testSharingScreenExplainsWhoCanSeeTheLog() {
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))

        app.buttons["open-sharing-button"].tap()

        XCTAssertTrue(app.navigationBars["Circle"].waitForExistence(timeout: 5))
        // Dining profiles are distinct from people who can open a synced copy.
        let accessStatus = app.staticTexts["sharing-access-status"]
        XCTAssertTrue(accessStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(accessStatus.label, "Only this iPhone has a copy")
        XCTAssertFalse(app.staticTexts["Just you"].exists)
        XCTAssertTrue(app.textFields["join-code-field"].exists)
    }

    /// A join code has to be usable without a link, since a link can be blocked
    /// by anything between the two phones.
    func testAJoinCodeCanBeTypedInTheApp() {
        app.tabBars.buttons["More"].tap()
        app.buttons["open-sharing-button"].tap()
        XCTAssertTrue(app.navigationBars["Circle"].waitForExistence(timeout: 5))

        let field = app.textFields["join-code-field"]
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<10 where !field.isHittable { scrollView.swipeUp() }
        XCTAssertTrue(field.isHittable)

        let join = app.buttons["join-circle-button"]
        XCTAssertFalse(join.isEnabled, "An incomplete code must not be submittable")
        field.tap()
        field.typeText("k7m42qpx9wtr")

        XCTAssertEqual(field.value as? String, "K7M4-2QPX-9WTR")
        XCTAssertTrue(join.isEnabled)
    }
    func testDiningAtlasShowsTheFirstOutingTrail() {
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        app.buttons["Open dining atlas"].tap()

        XCTAssertTrue(app.navigationBars["Dining Atlas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 5))
        let legend = app.descendants(matching: .any)["atlas-first-outings-legend"]
        XCTAssertTrue(legend.exists)
        XCTAssertEqual(legend.label, "First outings. Pins are ordered by first outing.")
        XCTAssertTrue(app.staticTexts["9 restaurants mapped"].exists)
        XCTAssertTrue(app.staticTexts["Normal Ice Cream"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Dining Atlas"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testReactionTapSavesOutingAndShowsRanking() {
        chooseOutingRestaurant(named: "Codex Test Kitchen", isNew: true)
        let michelle = app.buttons["Michelle"]
        revealInForm(michelle)
        if !michelle.isSelected { michelle.tap() }
        let reaction = app.buttons["reaction-Liked It"]
        for _ in 0..<6 where !reaction.isHittable { app.swipeDown() }
        reaction.tap()
        XCTAssertTrue(app.staticTexts["Go back?"].waitForExistence(timeout: 4))
        app.buttons["wizard-option-yes"].tap()
        XCTAssertTrue(app.staticTexts["Worth it?"].waitForExistence(timeout: 4))
        app.buttons["wizard-option-Loved It"].tap()
        XCTAssertTrue(app.staticTexts["The service?"].waitForExistence(timeout: 4))
        app.buttons["wizard-rank-it"].tap()

        XCTAssertTrue(app.scrollViews["log-payoff"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["OUTING SAVED"].exists)
        XCTAssertTrue(app.staticTexts["log-score-locked"].exists)
        XCTAssertFalse(app.staticTexts["log-score"].exists, "One outing alone must not unlock a score.")
        app.buttons["log-done"].tap()
        app.tabBars.buttons["History"].tap()
        let loggedVisit = app.staticTexts["Codex Test Kitchen"].firstMatch
        XCTAssertTrue(loggedVisit.waitForExistence(timeout: 4))
        loggedVisit.tap()
        XCTAssertTrue(app.staticTexts["George, Michelle"].waitForExistence(timeout: 3))
    }

    func testPayoffTracksDetailsComparisonsAndReactionEdits() throws {
        // A repeat outing has an earned score; a new restaurant is tested separately.
        logOutingForScoreTest(named: "Yoko Ramen", isNew: false)
        let initialScore = try payoffScore()
        openOutingDetails()
        // Detail changes are diluted across repeat outings and comparisons.
        // Use all four signals so the change exceeds whole-score rounding.
        for title in ["Service", "Atmosphere", "Value"] {
            let detail = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ", ")).firstMatch
            revealInForm(detail)
            detail.tap()
            app.buttons["Loved"].tap()
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@", "Loved"), object: detail
            )
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        }
        let returnPicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Would eat here again")).firstMatch
        revealInForm(returnPicker)
        returnPicker.tap()
        app.buttons["Yes"].tap()
        saveOutingDetails()
        let detailedScore = try payoffScore()
        XCTAssertGreaterThan(detailedScore, initialScore)

        openOutingDetails()
        let reaction = app.buttons["reaction-Not For Me"]
        revealInForm(reaction)
        reaction.tap()
        saveOutingDetails()
        let editedScore = try payoffScore()
        XCTAssertLessThan(editedScore, detailedScore)
        XCTAssertEqual(app.staticTexts["log-rank"].label, "Number 2 in Full Service")
        XCTAssertTrue(app.images["Not for me"].exists || app.images["Not For Me"].exists)

        answerFaceOff(preferringLogged: true)
        let comparisonScore = try payoffScore()
        XCTAssertGreaterThan(comparisonScore, editedScore)
        assertRankingScore(named: "Yoko Ramen", equals: comparisonScore)
    }

    func testPayoffPreservesBeforeScoreWhileUpdatingRepeatOuting() throws {
        let beforeLabel = rankingRow(named: "Yoko Ramen").label
        let beforeScore = try XCTUnwrap(Int(
            beforeLabel.components(separatedBy: "return score ").last?.split(separator: " ").first ?? ""
        ))
        app.tabBars.buttons["Log"].tap()
        logOutingForScoreTest(named: "Yoko Ramen", isNew: false, reaction: "Not For Me")
        let initialScore = try payoffScore()
        XCTAssertLessThan(initialScore, beforeScore)
        XCTAssertTrue(app.staticTexts["log-score"].label.contains("from \(beforeScore)"))

        openOutingDetails()
        let reaction = app.buttons["reaction-Loved It"]
        revealInForm(reaction)
        reaction.tap()
        saveOutingDetails()
        let editedScore = try payoffScore()
        XCTAssertGreaterThan(editedScore, beforeScore)
        XCTAssertTrue(app.staticTexts["log-score"].label.contains("from \(beforeScore)"),
                      "The baseline must remain the score from before logging.")
        assertRankingScore(named: "Yoko Ramen", equals: editedScore)
    }

    func testPayoffFollowsChangedRestaurantAndDropsOldComparisons() throws {
        logOutingForScoreTest(named: "Score Refresh Probe", isNew: true)
        XCTAssertTrue(app.staticTexts["log-score-locked"].exists)
        answerFaceOff(preferringLogged: true)

        openOutingDetails()
        let changeRestaurant = app.buttons["change-visit-restaurant"]
        revealInForm(changeRestaurant)
        changeRestaurant.tap()
        let search = app.textFields["change-visit-restaurant-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Normal Ice Cream")
        let destination = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Normal Ice Cream")).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        destination.tap()
        saveOutingDetails()

        let movedScore = try payoffScore()
        XCTAssertGreaterThan(movedScore, 71)
        XCTAssertEqual(app.staticTexts["log-rank"].label, "Number 1 in Dessert")
        XCTAssertFalse(app.staticTexts["log-score"].label.contains("from "))
        XCTAssertFalse(app.buttons["face-off-logged"].exists)
        XCTAssertFalse(app.buttons["face-off-opponent"].exists)
        assertRankingScore(named: "Normal Ice Cream", equals: movedScore)
    }

    func testTwoFaceOffsUnlockANewRestaurantScore() throws {
        logOutingForScoreTest(named: "Score Unlock Probe", isNew: true)
        XCTAssertTrue(app.staticTexts["log-score-locked"].exists)
        answerFaceOff(preferringLogged: true)
        XCTAssertTrue(app.staticTexts["log-score-locked"].exists)
        answerFaceOff(preferringLogged: true)
        let score = try payoffScore()
        XCTAssertFalse(app.staticTexts["log-score-locked"].exists)
        XCTAssertFalse(app.buttons["face-off-logged"].exists)
        assertRankingScore(named: "Score Unlock Probe", equals: score)
    }

    func testWizardUndoRemovesSavedOutingAndCanClose() {
        logOutingForScoreTest(named: "Undo Probe", isNew: true)
        let undo = app.buttons["log-undo"]
        revealInPayoff(undo)
        undo.tap()
        XCTAssertTrue(app.buttons["reaction-Liked It"].waitForExistence(timeout: 4))
        app.buttons["log-back"].tap()
        XCTAssertTrue(app.textFields["log-place-search"].waitForExistence(timeout: 4))
        app.buttons["log-close"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertFalse(app.staticTexts["Undo Probe"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func chooseOutingRestaurant(named name: String, isNew: Bool) {
        app.buttons["log-meal-button"].tap()
        let search = app.textFields["log-place-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(search.isHittable, "Decorative overlays must not hide the search field from accessibility hit testing.")
        search.tap()
        search.typeText(name + "\n")
        let place = isNew
            ? app.buttons["manual-place-choice"]
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 4))
        for _ in 0..<6 where !place.isHittable { app.scrollViews.firstMatch.swipeUp() }
        place.tap()
        XCTAssertTrue(app.buttons["reaction-Liked It"].waitForExistence(timeout: 4))
    }

    private func logOutingForScoreTest(named name: String, isNew: Bool, reaction: String = "Liked It") {
        chooseOutingRestaurant(named: name, isNew: isNew)
        app.buttons["reaction-\(reaction)"].tap()
        XCTAssertTrue(app.buttons["wizard-rank-it"].waitForExistence(timeout: 4))
        app.buttons["wizard-rank-it"].tap()
        XCTAssertTrue(app.scrollViews["log-payoff"].waitForExistence(timeout: 4))
    }

    private func payoffScore() throws -> Int {
        let payoff = app.scrollViews["log-payoff"]
        XCTAssertTrue(payoff.waitForExistence(timeout: 4))
        let score = app.staticTexts["log-score"]
        for _ in 0..<6 where !score.isHittable { payoff.swipeDown() }
        XCTAssertTrue(score.waitForExistence(timeout: 3))
        let number = score.label.components(separatedBy: "Return score ").last?.split(separator: " ").first
        return try XCTUnwrap(number.flatMap { Int($0) }, score.label)
    }

    private func revealInPayoff(_ element: XCUIElement) {
        let payoff = app.scrollViews["log-payoff"]
        let footer = app.buttons["log-done"]
        for _ in 0..<8 {
            if element.exists, element.isHittable, element.frame.maxY < footer.frame.minY { break }
            payoff.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func answerFaceOff(preferringLogged: Bool) {
        let opponent = app.buttons["face-off-opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 3))
        let oldLabel = opponent.label
        let answer = app.buttons[preferringLogged ? "face-off-logged" : "face-off-opponent"]
        revealInPayoff(answer)
        answer.tap()
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR label != %@", oldLabel), object: opponent
        )
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
    }

    private func openOutingDetails() {
        let details = app.buttons["log-add-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        details.tap()
        XCTAssertTrue(app.navigationBars["Add Outing Details"].waitForExistence(timeout: 3))
    }

    private func revealInForm(_ element: XCUIElement) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    private func saveOutingDetails() {
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.scrollViews["log-payoff"].waitForExistence(timeout: 4))
    }

    private func assertRankingScore(named name: String, equals score: Int) {
        app.buttons["log-done"].tap()
        let row = rankingRow(named: name)
        XCTAssertTrue(row.label.contains("return score \(score) out of 100"), row.label)
    }

    private func rankingRow(named name: String) -> XCUIElement {
        app.tabBars.buttons["Rankings"].tap()
        let overall = app.buttons["Overall"]
        for _ in 0..<6 where !overall.isHittable { app.swipeDown() }
        overall.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        return row
    }

    func testVisibleHomeButtonsMeetMinimumHitTarget() {
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(buttons.isEmpty)
        let undersized = buttons.compactMap { button -> String? in
            // Accessibility frame subtraction can turn exactly 44 into 43.999999999999986.
            let tolerance = 0.001
            guard button.frame.width < 44 - tolerance || button.frame.height < 44 - tolerance else { return nil }
            return "\(button.label.isEmpty ? "Unlabeled button" : button.label): \(button.frame)"
        }
        XCTAssertEqual(undersized, [], "Every visible home button must expose at least a 44×44-point hit target")
    }

    func testDeletingVisitReturnsToHistoryWithoutCrashing() {
        app.tabBars.buttons["History"].tap()
        let visit = app.staticTexts["The Copper Onion"].firstMatch
        XCTAssertTrue(visit.waitForExistence(timeout: 5))
        visit.tap()

        let deleteButton = app.buttons["Delete entire outing"]
        for _ in 0..<8 where !deleteButton.isHittable { app.swipeUp() }
        XCTAssertTrue(deleteButton.isHittable)
        deleteButton.tap()
        XCTAssertTrue(app.otherElements["editorial-prompt"].waitForExistence(timeout: 3))
        let confirmDelete = app.buttons["Delete outing"]
        XCTAssertTrue(confirmDelete.exists)
        confirmDelete.tap()

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    }

    func testLastOutingDeletionCanKeepThenRemoveComparedRestaurant() {
        app.tabBars.buttons["History"].tap()
        let outing = app.staticTexts["Normal Ice Cream"].firstMatch
        XCTAssertTrue(outing.waitForExistence(timeout: 5))
        outing.tap()

        let deleteButton = app.buttons["Delete entire outing"]
        for _ in 0..<8 where !deleteButton.isHittable { app.swipeUp() }
        XCTAssertTrue(deleteButton.isHittable)
        deleteButton.tap()

        XCTAssertTrue(app.staticTexts["Delete the last outing?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete outing and restaurant"].exists)
        let deleteOutingOnly = app.buttons["Delete outing only"]
        XCTAssertTrue(deleteOutingOnly.exists)
        deleteOutingOnly.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))

        app.tabBars.buttons["More"].tap()
        app.staticTexts["Statistics"].tap()
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
        let restaurantsMetric = app.buttons["9 restaurants"]
        XCTAssertTrue(restaurantsMetric.waitForExistence(timeout: 3))
        restaurantsMetric.tap()

        let emptyRestaurant = app.staticTexts["Normal Ice Cream"].firstMatch
        for _ in 0..<8 where !emptyRestaurant.isHittable { app.swipeUp() }
        XCTAssertTrue(emptyRestaurant.isHittable)
        emptyRestaurant.tap()
        XCTAssertTrue(app.navigationBars["Normal Ice Cream"].waitForExistence(timeout: 5))

        app.buttons["Restaurant actions"].tap()
        let removeEmptyRestaurant = app.buttons["remove-empty-restaurant"]
        XCTAssertTrue(removeEmptyRestaurant.waitForExistence(timeout: 3))
        removeEmptyRestaurant.tap()
        XCTAssertTrue(app.staticTexts["Remove Normal Ice Cream from the log?"].waitForExistence(timeout: 3))
        app.buttons["Remove restaurant"].tap()

        XCTAssertTrue(app.navigationBars["Restaurants"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Normal Ice Cream"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testRemovingWantedRestaurantDoesNotCrash() {
        app.tabBars.buttons["More"].tap()
        app.staticTexts["Want to Try"].tap()
        XCTAssertTrue(app.navigationBars["Want to Try"].waitForExistence(timeout: 5))
        app.buttons["Add a restaurant"].firstMatch.tap()

        let restaurant = app.staticTexts["The Copper Onion"].firstMatch
        XCTAssertTrue(restaurant.waitForExistence(timeout: 5))
        restaurant.tap()
        XCTAssertTrue(restaurant.waitForExistence(timeout: 5))

        let remove = app.buttons["Remove The Copper Onion from this log"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()

        XCTAssertTrue(app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testResetAppReturnsToOnboarding() {
        app.tabBars.buttons["More"].tap()
        app.staticTexts["Open settings"].tap()

        let resetButton = app.buttons["reset-app-button"]
        for _ in 0..<6 where !resetButton.exists { app.swipeUp() }
        XCTAssertTrue(resetButton.waitForExistence(timeout: 3))
        for _ in 0..<6 where !resetButton.isHittable { app.swipeUp() }
        XCTAssertTrue(resetButton.isHittable)
        resetButton.tap()
        XCTAssertTrue(app.otherElements["editorial-prompt"].waitForExistence(timeout: 3))
        let eraseEverything = app.buttons["Erase everything"]
        XCTAssertTrue(eraseEverything.exists)
        eraseEverything.tap()

        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    func testSettingsBackupRestoreRequiresDestructiveConfirmation() {
        app.tabBars.buttons["More"].tap()
        app.staticTexts["Open settings"].tap()

        let restoreButton = app.buttons["restore-backup-button"]
        for _ in 0..<10 where !restoreButton.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 3))
        XCTAssertTrue(restoreButton.isHittable)
        restoreButton.tap()

        XCTAssertTrue(app.otherElements["editorial-prompt"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Restore from backup?"].exists)
        let chooseBackupButton = app.buttons["Choose backup and replace everything"]
        XCTAssertTrue(chooseBackupButton.exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        chooseBackupButton.tap()

        XCTAssertTrue(
            app.buttons["Cancel"].waitForExistence(timeout: 3),
            "Confirming the restore must open the system file picker."
        )
    }

    func testOnboardingSupportingTextWrapsAtAccessibilitySize() {
        app.terminate()
        app.launchArguments = [
            "-resetForUITests",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraLarge"
        ]
        app.launch()

        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 8))
        getStarted.tap()

        let detail = app.staticTexts["onboarding-step-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(detail.label, "Your name goes on the outings you log. You can add the people you dine with later.")
        XCTAssertFalse(app.textFields["Partner (optional)"].exists)

        let signIn = app.buttons["onboarding-sign-in-button"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 3))
        for _ in 0..<4 where !signIn.isHittable { app.swipeUp() }
        XCTAssertTrue(signIn.isHittable, "The scrollable step should keep its action reachable at large text sizes")
    }

    func testOnboardingBackupRestoreRequiresDestructiveConfirmation() {
        app.terminate()
        app.launchArguments = [
            "-resetForUITests",
            "-didCompleteGrandOpening", "NO"
        ]
        app.launch()

        let getStarted = app.buttons["Get started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 8))
        getStarted.tap()

        let nameField = app.textFields["Your name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("Backup Tester")
        let continueButton = app.buttons["Continue without signing in"]
        for _ in 0..<6 where !continueButton.isHittable { app.swipeUp() }
        continueButton.tap()

        let restoreAction = app.staticTexts["Restore a full backup"]
        XCTAssertTrue(restoreAction.waitForExistence(timeout: 3))
        restoreAction.tap()

        XCTAssertTrue(app.otherElements["editorial-prompt"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Restore from backup?"].exists)
        XCTAssertTrue(app.buttons["Choose backup and replace everything"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    private func openAppearanceSettings() {
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        app.staticTexts["Open settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
}
