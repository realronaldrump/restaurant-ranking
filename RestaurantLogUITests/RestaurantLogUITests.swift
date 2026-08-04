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

    func testRankingHistoryChartOffersMinuteToYearScale() {
        app.tabBars.buttons["Rankings"].tap()
        XCTAssertTrue(app.navigationBars["Rankings"].waitForExistence(timeout: 5))

        let panel = app.descendants(matching: .any)["ranking-history-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        let scaleButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Ranking history scale")
        ).firstMatch
        for _ in 0..<8 where !scaleButton.isHittable { app.swipeUp() }
        XCTAssertTrue(scaleButton.waitForExistence(timeout: 3))
        scaleButton.tap()

        XCTAssertTrue(app.buttons["15 minutes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["1 year"].exists)
        app.buttons["1 year"].tap()
        XCTAssertTrue(scaleButton.label.localizedCaseInsensitiveContains("1 year"))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Ranking history chart"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

    func testManualThreeTapLogCreatesRankingPayoff() {
        app.buttons["log-meal-button"].tap()
        XCTAssertTrue(app.buttons["start-meal-with-photo"].waitForExistence(timeout: 3))
        let search = app.textFields["log-place-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Codex Test Kitchen")

        let searchKey = app.keyboards.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "search")).firstMatch
        if searchKey.waitForExistence(timeout: 2) { searchKey.tap() }

        let manual = app.buttons["manual-place-choice"]
        XCTAssertTrue(manual.waitForExistence(timeout: 4))
        for _ in 0..<6 where !manual.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(manual.isHittable)
        manual.tap()

        let reaction = app.buttons["reaction-Liked It"]
        XCTAssertTrue(reaction.waitForExistence(timeout: 3))
        reaction.tap()
        XCTAssertFalse(app.scrollViews["log-payoff"].exists, "Choosing a reaction should not save before confirmation")

        let scrollView = app.scrollViews.firstMatch
        let optionalDetails = app.buttons["Add people or change details"]
        XCTAssertTrue(optionalDetails.waitForExistence(timeout: 3))
        for _ in 0..<5 where !optionalDetails.isHittable { scrollView.swipeUp() }
        XCTAssertTrue(optionalDetails.isHittable)
        optionalDetails.tap()

        let michelle = app.buttons["Michelle"]
        XCTAssertTrue(michelle.waitForExistence(timeout: 3))
        for _ in 0..<5 where !michelle.isHittable { scrollView.swipeUp() }
        XCTAssertTrue(michelle.isHittable)
        michelle.tap()

        let saveOuting = app.buttons["save-outing"]
        for _ in 0..<5 where !saveOuting.isHittable { scrollView.swipeDown() }
        XCTAssertTrue(saveOuting.isHittable)
        XCTAssertTrue(saveOuting.isEnabled)
        saveOuting.tap()

        XCTAssertTrue(app.scrollViews["log-payoff"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Codex Test Kitchen"].exists)
        XCTAssertTrue(app.staticTexts["OUTING SAVED"].exists)
        XCTAssertTrue(app.buttons["Add outing details"].exists)
        app.buttons["Done"].tap()

        app.tabBars.buttons["History"].tap()
        let loggedVisit = app.staticTexts["Codex Test Kitchen"].firstMatch
        XCTAssertTrue(loggedVisit.waitForExistence(timeout: 6))
        loggedVisit.tap()
        XCTAssertTrue(app.staticTexts["George, Michelle"].waitForExistence(timeout: 3))
    }

    func testVisibleHomeButtonsMeetMinimumHitTarget() {
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(buttons.isEmpty)
        let undersized = buttons.compactMap { button -> String? in
            guard button.frame.width < 44 || button.frame.height < 44 else { return nil }
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
