import Darwin

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

@main
enum CapacityNotchTestRunner {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("Dictation.replacements", dictationReplacesPhrasesWithoutSubstringsOrCascades),
            ("Dictation.history", dictationHistoryIsOptInBoundedAndPersistent),
            ("Dictation.session", dictationStopsOnceAndRejectsCancelledResults),
            ("Translator.direction", cyrillicGoesToEnglishAndLatinToRussian),
            ("Translator.flip", aFlipHoldsWhileTypingAndIsForgottenWhenEmptied),
            ("Translator.readiness", theTranslatorIsReadyOnlyWithBothWaysDownloaded),
            ("Translator.onceAtATime", theShortcutRunsOnceAtATime),
            ("Translator.accessibilityReplaces", aSelectionReadThroughAccessibilityIsReplacedAndTheClipboardPutBack),
            ("Translator.copyFallback", whereAccessibilityCannotReadTheSelectionItIsCopiedAndTheClipboardPutBack),
            ("Translator.notInPlace", aTranslationThatCannotBePutInPlaceStaysOnTheClipboard),
            ("Translator.newerCopyKept", somethingCopiedMeanwhileIsNotOverwrittenByTheRestore),
            ("Translator.nothingSelected", nothingSelectedLeavesTheClipboardUntouched),
            ("Translator.refusals", passwordFieldsAndUnreadyTranslatorsReadNothing),
            ("Translator.statesNeverText", theTranslatorTellsTheLogAndDiagnosticsStatesNeverText),
            ("Translator.offAndShortcut", theTranslatorIsOffUntilTurnedOnWithItsOwnShortcut),
            ("Translator.pageOrder", theTranslatorsPageComesLast),
            ("Translator.russian", theTranslatorSpeaksRussian),
            ("Translator.nothingReplacedUnasked", theShortcutReplacesNothingUntilThePersonAsks),
            ("Translator.selectionInAField", aSelectionInAFieldOffersPastingInPlaceFirst),
            ("Translator.selectionToRead", aSelectionToReadOffersOnlyCopying),
            ("Translator.returnChooses", returnChoosesThePrimaryAction),
            ("Translator.problemsOnThePage", shortcutProblemsAreSaidOnThePage),
            ("Translator.languageLogChangesOnly", askingForLanguagesLogsOnlyChanges),
            ("Localization.translationsKeepTheirArguments", everyTranslationKeepsItsSentencesNumbersAndNames),
            ("Localization.systemFollowsTheMac", systemLanguageFollowsTheMacsFirstLanguage),
            ("Localization.missingFallsBackToEnglish", aSentenceWithoutATranslationIsShownAsWritten),
            ("Localization.choiceIsRemembered", theLanguageChoiceIsRemembered),
            ("Localization.russianAlert", aRussianAlertSaysItAllInRussian),
            ("CompactStrip.oneProvider", theStripShowsTheOnlyProvidersShortWindowLeftAndLongRight),
            ("CompactStrip.bothProviders", theStripShowsEachProvidersFiveHoursWhenBothAreOn),
            ("CompactStrip.nothingConnected", nothingConnectedLeavesTheStripEmpty),
            ("CompactStrip.oneOrder", providersStandInOneOrderWhateverOrderTheyArrive),
            ("CompactStrip.twoAtMost", atMostTwoProvidersCanBeOn),
            ("CompactStrip.onlyUnreadDashLeft", theOnlyProviderNotReadYetHasItsDashOnTheLeft),
            ("OpenCode.openCodesRollingAndWeeklyAreItsTwoWindows", openCodesRollingAndWeeklyAreItsTwoWindows),
            ("OpenCode.aRateLimitedWindowHasNothingLeft", aRateLimitedWindowHasNothingLeft),
            ("OpenCode.aMonthUsedUpIsSaidOverGreenWindows", aMonthUsedUpIsSaidOverGreenWindows),
            ("OpenCode.eachWayOpenCodeCannotBeReadSaysWhatToDo", eachWayOpenCodeCannotBeReadSaysWhatToDo),
            ("OpenCode.onlyTheGoKeyIsTakenFromOpenCodesOwnFile", onlyTheGoKeyIsTakenFromOpenCodesOwnFile),
            ("OpenCode.openCodeIsAskedAtMostEveryFiveMinutesUnlessAPersonAsks", openCodeIsAskedAtMostEveryFiveMinutesUnlessAPersonAsks),
            ("OpenCode.aFailureAfterAReadingKeepsItAsStale", aFailureAfterAReadingKeepsItAsStale),
            ("Codex.chatGPTBundled", theCodexInChatGPTIsFoundWhereNewerReleasesKeepIt),
            ("Codex.environment", codexRunsWithThePathATerminalWouldGiveIt),
            ("Shelf.newestFirstAndTwenty", theShelfKeepsTheNewestFirstAndAtMostTwenty),
            ("Shelf.droppedAgainRises", aFileDroppedAgainRisesInsteadOfAppearingTwice),
            ("Shelf.removeAndClear", aFileIsRemovedAloneAndClearingEmptiesItsTab),
            ("Shelf.fileKinds", aFileIsDrawnByWhatKindItIs),
            ("Shelf.diagnostics", theShelfTellsDiagnosticsHowManyNeverWhich),
            ("Shelf.pageOrder", pagesRunCapacityMusicTeleprompterShelf),
            ("Calendar.rowTenMinutesBefore", theRowAppearsTenMinutesBeforeAnEventAndLeavesFiveAfter),
            ("Calendar.comingOutranksStarted", anEventStillToComeOutranksOneAlreadyStarted),
            ("Calendar.allDay", anAllDayEventNeverTakesTheRowButLeadsTheDay),
            ("Calendar.declinedAndCancelled", declinedAndCancelledEventsAreNotComing),
            ("Calendar.nextEventAndRestOfToday", theDayFeaturesTheNextEventAndListsTheRestOfToday),
            ("Calendar.crossingMidnight", anEventCrossingMidnightBelongsToBothDays),
            ("Calendar.nextChange", theApplicationWakesWhenTheRowCouldChange),
            ("Calendar.callLinks", aCallLinkIsFoundWhereverTheCalendarPutsIt),
            ("Calendar.offReadsNothing", whileOffNothingIsAskedOrRead),
            ("Calendar.refusalShowsNothing", aRefusalShowsNothingOnTheSurface),
            ("Calendar.launchNeverPrompts", atLaunchTheModuleNeverPrompts),
            ("Calendar.pageOrder", calendarComesLastAmongThePages),
            ("Calendar.compactRow", anEventAboutToStartOutranksMusicButNotTheTeleprompter),
            ("Calendar.diagnostics", diagnosticsSayHowManyEventsAndNeverWhich),
            ("Calendar.russian", theCalendarSpeaksRussian),
            ("Calendar.hideFromRow", theRowsCrossHidesThatOccurrenceAndNotTheNext),
            ("Calendar.weekFromToday", theWeekIsSevenDaysStartingToday),
            ("Calendar.weekChips", theWeeksChipsAreTwoAtMostAndTheRestAreCounted),
            ("Calendar.weekFree", aWeekWithNothingSaysWhenTheNextEventIs),
            ("Calendar.dayNothingLeft", aDayWithNothingLeftSaysWhatComesNext),
            ("Calendar.kapaFreeTime", kapaWearsSunglassesOnlyInAnEmptyDayOrWeek),
            ("Calendar.monthOctober", octoberIsFiveWeeksFromTheTwentyEighthOfSeptember),
            ("Calendar.monthMarch", marchTwentyTwentySixIsSixWeeks),
            ("Calendar.monthRows", everyMonthsGridFillsTheView),
            ("Calendar.monthFreeDay", aFreeDayChosenInTheMonthSaysWhatComesAfterIt),
            ("Calendar.monthChosenDay", aDayInTheMonthCanBeChosenAndTodayIsTheDefault),
            ("Calendar.weekendsAndHolidays", weekendsAndHolidaysAreRed),
            ("Calendar.monthDots", theMonthsDotsAreItsCalendarsColoursThreeAtMost),
            ("Calendar.rememberedTab", thePageOpensOnTheTabLastUsed),
            ("Calendar.readInterval", theWeekAndTheMonthWidenWhatIsReadAndNothingElse),
            ("Calendar.headings", theCalendarsHeadingsSpeakBothLanguages),
            ("Calendar.callService", theComingEventSaysWhatItsCallIsOn),
            ("Shelf.fileCount", theShelfCountsItsFilesAsEachLanguageDoes),
            ("Shelf.imageInMemory", anImageWithoutAFileIsHeldInMemory),
            ("Shelf.threeTabs", theShelfHasThreeTabsInOrder),
            ("Shelf.copiedLandsByKind", whatIsCopiedLandsInTheTabForItsKind),
            ("Shelf.limitPerTab", eachTabKeepsItsOwnLimit),
            ("Shelf.clearOneTab", clearEmptiesOnlyTheTabItIsAskedFor),
            ("Shelf.screenshotCount", theShelfCountsScreenshotsAsEachLanguageDoes),
            ("Shelf.screenshotFolderLocation", theScreenshotFolderIsWhereMacOSSavesScreenshots),
            ("Shelf.screenshotFolderNewOnly", onlyScreenshotsSavedAfterTheSwitchWasTurnedOnAreTaken),
            ("Shelf.screenshotFolderNameAndType", aScreenshotIsKnownByTheNameAndTypeMacOSWasToldToUse),
            ("Shelf.screenshotFolderSettings", theScreenshotSettingsAreReadFromMacOSsOwnKeys),
            ("Shelf.screenshotFolderTarget", theFolderIsLookedAtOnlyWhileMacOSSavesScreenshotsToOne),
            ("ClaudeMod.copiedSettingsUntouched", theModIsCopiedIntoTheSkillsFolderAndSettingsAreNotTouched),
            ("ClaudeMod.refreshSaysWhereTheNextReadingComesFrom", aRefreshWithNothingNewerSaysWhereTheNextReadingComesFrom),
            ("ClaudeMod.nextReadingInBothLanguages", whereTheNextReadingComesFromIsSaidInBothLanguages),
            ("ClaudeMod.noReadingWaitsForAnyReply", withTheModNoReadingYetWaitsForAnyReply),
            ("ClaudeMod.buildBundlesWhatIsInstalled", theBuildBundlesExactlyWhatIsInstalled),
            ("ClaudeMod.followsTheBridgeKeepsTypes", anInstalledModFollowsTheBridgeAndKeepsClaudeCodesTypes),
            ("ClaudeMod.notOursNeverTouched", aFolderCapaTheNotchDidNotMakeIsNeverTouched),
            ("ClaudeMod.turnOffRemovesOnlyIt", turningOffRemovesTheModAndNothingElse),
            ("ClaudeMod.incompleteInstallsNothing", aBundleMissingAFileInstallsNothing),
            ("ClaudeMod.versions", modsAreUsedOnlyWhereClaudeCodeRunsThem),
            ("ClaudeMod.diagnostics", copyDiagnosticsSaysTheModsStateInOneWord),
            ("ClaudeMod.newestOfTwoWritersWins", theModAndTheStatusLineShareOneFileAndTheNewestWins),
            ("ClaudeMod.noCredentialsCross", theBridgeIsRunWithNoneOfClaudeCodesCredentials),
            ("ClaudeMod.validatesToItsTwoCalls", theModHooksAndCallsNothingButItsOwnTwo),
            ("ClaudeSettings.rowsForEachState", theClaudeCardShowsOneRowSetForEachStateOfTheMod),
            ("ClaudeSettings.wordsAsDrawn", theClaudeCardSaysWhatTheMockupsSay),
            ("ClaudeSettings.addAndRemoveShowAtOnce", addingAndRemovingTheModShowsAtOnce),
            ("ClaudeSettings.newestVersionNamed", theNewestClaudeCodeFoundIsTheOneNamed),
            ("ClaudeSettings.terminalStartsClaude", theTerminalButtonStartsClaudeWithNothingSent),
            ("Preferences.chosenPaceSetsTheSchedule", theChosenPaceSetsTheClosedSurfacesSchedule),
            ("ClaudeBridgeMove.toTheRenamedApplication", theBridgeMovesToTheRenamedApplication),
            ("ClaudeBridgeMove.passedStatusLineKept", aStatusLinePassedToTheBridgeIsKept),
            ("ClaudeBridgeMove.wholeOldPath", theWholeOldPathMovesWhereverTheBundleWas),
            ("ClaudeBridgeMove.nothingToMove", settingsWithoutTheOldBridgeAreLeftAlone),
            ("ClaudeBridgeMove.writtenAsJSON", aBridgePathIsWrittenAsJSON),
            ("ClaudeBridgeMove.inPlace", theSettingsFileIsRewrittenInPlaceKeepingItsLinkAndPermissions),
            ("OldGrantReset.onceUnderTheCertificate", theOldGrantsAreResetOnceAndOnlyUnderTheCertificate),
            ("OldGrantReset.exactlyTheFour", exactlyTheFourGrantsAreResetForCapaTheNotch),
            ("OldGrantReset.failureTriedAgain", aResetThatFailsIsSaidAndTriedAgainAtTheNextLaunch),
            ("OldGrantReset.whatOpens", onboardingSaysWhyItAsksAgainOnlyToSomeoneWhoGrantedBefore),
            ("OldGrantReset.firstRunResetsNothing", aFirstRunResetsNothingThenOrLater),
            ("OldGrantReset.removedByHand", grantsRemovedByHandEndTheAsking),
            ("OldGrantReset.askedAtTheRelaunch", aResetDoneWhileRunningAsksAgainAtTheRelaunchOnce),
            ("CapacityAlert.recoveryAfterAlert", aWindowThatRecoversAfterItsAlertIsGoodNews),
            ("Sound.recipesRing", everySoundRecipeDecodesAndRings),
            ("Sound.layerDelayAndRamp", aLayerStartsAtItsDelayAndRampsFromTheFloor),
            ("Sound.onlyTheEcho", onlyTheEchoIsPlayed),
            ("Sound.writtenForListening", soundsCanBeWrittenForListening),
            ("Kapa.capacity", kapaReadsCapacityOffTheWindowWithTheLeastLeft),
            ("Kapa.noOldNumbers", kapaJudgesNoOldNumbers),
            ("Kapa.oneAPage", oneKapaAPageOnTheCardThatNeedsALook),
            ("Kapa.blink", kapaBlinksEveryTwoToFiveSecondsAndSometimesTwice),
            ("Kapa.gaze", kapasEyesSitAsDrawnAndTurnWithTheHead),
            ("Kapa.moreThanColour", everyKapaPoseSaysItWithMoreThanColour),
            ("Kapa.frameRate", kapaFollowsATargetTheSameAtAnyFrameRate),
            ("Kapa.music", kapaNodsOnEveryBeatOfTheMusic),
            ("Kapa.lid", kapaBlinksShutAndOpenInAFifthOfASecond),
            ("Kapa.appetite", kapaOpensWiderTheNearerAFileIsHeld),
            ("Kapa.gulp", kapaEatsADroppedFileAndSettles),
            ("Kapa.movementsEnd", kapasMovementsEndWhereTheyBegan),
            ("Clipping.newestFirst", clippingsAreNewestFirstAndARepeatRises),
            ("Clipping.limit", clippingsKeepTwentyOrFiftyOrAHundred),
            ("Clipping.expiry", aClippingGoesAfterADayUnlessThatIsSwitchedOff),
            ("Clipping.length", aTextTooLongOrEmptyIsNotKeptAtAll),
            ("Clipping.remove", aClippingIsRemovedAloneAndClearingEmptiesThem),
            ("Clipping.whatIsKept", onlyPlainTextCopiedElsewhereAndUnmarkedIsKept),
            ("Clipping.outOfCapture", theSurfaceStaysOutOfCaptureWhileItHoldsAClipping),
            ("Clipping.diagnostics", theShelfTellsDiagnosticsHowManyClippingsNeverWhich),
            ("Clipping.preferences", textIntakeIsOffUntilAskedForAndKeepsADay),
            ("Clipping.count", theClipboardTabCountsItsClippingsAsEachLanguageDoes),
            ("Clipping.trim", fewerChosenTheOldestGoAtOnceAndTheRestStayAsTheyWere),
            ("Shelf.screenshotClipboard", aScreenshotOnTheClipboardIsOnePNGAndNothingElse),
            ("Shelf.screenshotName", aScreenshotIsNamedAsMacOSNamesOne),
            ("Shelf.clipboard", whatIsCopiedLandsOnTheShelfExceptFromFinder),
            ("CompactStrip.choice", theStripShowsTheWindowChosenInSettings),
            ("CompactStrip.choiceByLength", theChosenWindowIsTheOneOfThatLengthNotTheShortestOrLongest),
            ("CompactStrip.claudeFiveHoursMissing", claudeCodesFiveHoursNotSentShowAsADashInTheStrip),
            ("StatusLineSetup.keepsTheRest", theStatusLineIsAddedAndTheRestOfTheFileKeptByteForByte),
            ("StatusLineSetup.wrapsAnExistingLine", aStatusLineAlreadyThereRunsAfterTheBridge),
            ("StatusLineSetup.alreadyThere", aBridgeAlreadySetUpIsLeftAsItIs),
            ("StatusLineSetup.newFile", noSettingsFileYetGetsOneWithTheStatusLineAlone),
            ("StatusLineSetup.turnOffRestores", turningOffPutsBackWhatWasThere),
            ("StatusLineSetup.notJSON", aFileThatIsNotJSONIsNotTouched),
            ("StatusLineSetup.remembered", whatTheStatusLineReplacedIsRememberedToPutBack),
            ("StatusLineSetup.oldBundle", aBridgeFromTheOldBundleIsPointedAtThisOne),
            ("StatusLineSetup.twoStatusLines", aFileWithTwoStatusLinesIsNotTouched),
            ("Diagnostics.dictationStatesReachTheReport", dictationStatesReachTheReportWhole),
            ("Diagnostics.logLinesCarryCodes", aLogLineCarriesCodesAndNeverDescriptions),
            ("TrackpadTap.twoTaps", twoQuickTapsOfOneFingerOpenTheSurface),
            ("TrackpadTap.twoFingers", twoFingersAreNotOneFingerTapping),
            ("TrackpadTap.dragAndHold", aDragOrAPressAndHoldIsNotATap),
            ("TrackpadTap.palm", aPalmIsNotATap),
            ("TrackpadTap.farApart", tapsTooFarApartInTimeOrPlaceAreTwoSingleTaps),
            ("TrackpadTap.press", aTouchThatClicksIsAClickNotATap),
            ("TrackpadTap.thirdTap", aThirdTapStartsOver),
            ("TrackpadTap.silence", aTrackpadThatStopsAnsweringIsNoticed),
            ("TrackpadTap.offAndFailures", theTrackpadTapIsOffUntilAskedForAndSaysWhenItCannotWork),
            ("TrackpadTap.typing", twoTapsWhileTypingAreAHandOnTheTrackpad),
            (
                "TeleprompterTests.aScriptTakesAMinuteAtLeastAndRoundsToTheNearest",
                aScriptTakesAMinuteAtLeastAndRoundsToTheNearest
            ),
            (
                "TeleprompterTests.aScriptKeepsItsLineBreaksAndBlankLinesAndWrapsTheRest",
                aScriptKeepsItsLineBreaksAndBlankLinesAndWrapsTheRest
            ),
            (
                "TeleprompterTests.draggingTheProgressOfAStoppedScriptChoosesWhereItStarts",
                draggingTheProgressOfAStoppedScriptChoosesWhereItStarts
            ),
            (
                "TeleprompterTests.aScriptCountsItsWordsAcrossLinesAndSpaces",
                aScriptCountsItsWordsAcrossLinesAndSpaces
            ),
            (
                "TeleprompterTests.pastingReplacesTheScriptAndOnlyTheOneBeforeComesBack",
                pastingReplacesTheScriptAndOnlyTheOneBeforeComesBack
            ),
            (
                "TeleprompterTests.theTeleprompterIsOffWithQuietDefaults",
                theTeleprompterIsOffWithQuietDefaults
            ),
            (
                "TeleprompterTests.aRecordedKeyIsNamedAsTheKeycapShowsIt",
                aRecordedKeyIsNamedAsTheKeycapShowsIt
            ),
            (
                "TeleprompterTests.startingHoldsTheFirstLineThenMovesAtTheChosenSpeed",
                startingHoldsTheFirstLineThenMovesAtTheChosenSpeed
            ),
            (
                "TeleprompterTests.anEmptyScriptDoesNotStart",
                anEmptyScriptDoesNotStart
            ),
            (
                "TeleprompterTests.pauseHoldsThePlaceAndResumeGoesOnFromIt",
                pauseHoldsThePlaceAndResumeGoesOnFromIt
            ),
            (
                "TeleprompterTests.stopClearsTheRowAndStartsOver",
                stopClearsTheRowAndStartsOver
            ),
            (
                "TeleprompterTests.fasterAndSlowerChangeTheSpeedInQuarters",
                fasterAndSlowerChangeTheSpeedInQuarters
            ),
            (
                "TeleprompterTests.fingersMoveTheScriptAndPauseIt",
                fingersMoveTheScriptAndPauseIt
            ),
            (
                "TeleprompterTests.draggingTheProgressGoesAnywhereInTheScript",
                draggingTheProgressGoesAnywhereInTheScript
            ),
            (
                "TeleprompterTests.atTheEndItStopsOnTheLastLineAndTheRowLeavesAfterThreeSeconds",
                atTheEndItStopsOnTheLastLineAndTheRowLeavesAfterThreeSeconds
            ),
            (
                "TeleprompterTests.timeSpentAndLeftFollowThePlace",
                timeSpentAndLeftFollowThePlace
            ),
            (
                "TeleprompterTests.aNewLayoutKeepsThePlaceInTheScript",
                aNewLayoutKeepsThePlaceInTheScript
            ),
            (
                "TeleprompterTests.theTeleprompterRowTakesThePlaceOfTheMusicRow",
                theTeleprompterRowTakesThePlaceOfTheMusicRow
            ),
            (
                "TeleprompterTests.whileItShowsTheSurfaceStaysOutOfCaptureAndHoverDoesNotOpenIt",
                whileItShowsTheSurfaceStaysOutOfCaptureAndHoverDoesNotOpenIt
            ),
            (
                "TeleprompterTests.pagesRunCapacityMusicTeleprompter",
                pagesRunCapacityMusicTeleprompter
            ),
            (
                "TeleprompterTests.diagnosticsSayHowLongTheScriptIsAndNeverWhatItSays",
                diagnosticsSayHowLongTheScriptIsAndNeverWhatItSays
            ),
            ("ScriptFollower.theScriptsWordsKnowTheirLineAndPlace", theScriptsWordsKnowTheirLineAndPlace),
            ("ScriptFollower.followingMovesWithTheWordsReadInOrder", followingMovesWithTheWordsReadInOrder),
            ("ScriptFollower.aWordCutOffByTheWindowStillCounts", aWordCutOffByTheWindowStillCounts),
            ("ScriptFollower.aRepeatOrAStumbleDoesNotMoveThePlaceBack", aRepeatOrAStumbleDoesNotMoveThePlaceBack),
            ("ScriptFollower.skippingALineJumpsAheadOnceTheVoiceIsSure", skippingALineJumpsAheadOnceTheVoiceIsSure),
            ("ScriptFollower.talkOffTheScriptMovesNothing", talkOffTheScriptMovesNothing),
            ("ScriptFollower.whenTheVoiceStopsTheScriptHolds", whenTheVoiceStopsTheScriptHolds),
            ("ScriptFollower.aCommonShortWordAloneDoesNotJump", aCommonShortWordAloneDoesNotJump),
            ("ScriptFollower.readingAgainFromEarlierGoesBackOnlyOnALongRun", readingAgainFromEarlierGoesBackOnlyOnALongRun),
            ("ScriptFollower.theLastWordSaidIsTheEnd", theLastWordSaidIsTheEnd),
            ("ScriptFollower.aNewestWordNotYetMadeOutDoesNotPullThePlaceBack", aNewestWordNotYetMadeOutDoesNotPullThePlaceBack),
            ("ScriptFollower.followingTheVoiceTheScriptMovesOnlyWhereTheVoiceIs", followingTheVoiceTheScriptMovesOnlyWhereTheVoiceIs),
            ("ScriptFollower.theVoiceReadingTheLastWordFinishesTheScript", theVoiceReadingTheLastWordFinishesTheScript),
            ("ScriptFollower.turningFollowingOffGoesOnAtTheSetSpeedFromThePlace", turningFollowingOffGoesOnAtTheSetSpeedFromThePlace),
            (
                "CapacitySnapshotTests.quotaWindowReportsThirtyPercentLeftAfterSeventyPercentIsUsed",
                quotaWindowReportsThirtyPercentLeftAfterSeventyPercentIsUsed
            ),
            (
                "CapacitySnapshotTests.disconnectedCapacityCarriesGuidanceAndNoWindows",
                disconnectedCapacityCarriesGuidanceAndNoWindows
            ),
            (
                "MockCapacityCatalogTests.mockCatalogProvidesBothInitialProviders",
                mockCatalogProvidesBothInitialProviders
            ),
            (
                "MockCapacityCatalogTests.mockCatalogMarksCapacityAsMock",
                mockCatalogMarksCapacityAsMock
            ),
            (
                "CapacityNotchStoreTests.storeMovesBetweenCompactAndExpandedPresentation",
                storeMovesBetweenCompactAndExpandedPresentation
            ),
            (
                "CapacityNotchStoreTests.storeReplacesTheCapacityOfTheProviderItDescribes",
                storeReplacesTheCapacityOfTheProviderItDescribes
            ),
            (
                "CodexAppServerProtocolTests.inboundParserSeparatesResponsesFailuresAndNotifications",
                inboundParserSeparatesResponsesFailuresAndNotifications
            ),
            (
                "CodexAppServerProtocolTests.outboundRequestsAreOneJSONLine",
                outboundRequestsAreOneJSONLine
            ),
            (
                "CodexAppServerProtocolTests.codexWindowsBecomeQuotaWindowsWithRemainingCapacity",
                codexWindowsBecomeQuotaWindowsWithRemainingCapacity
            ),
            (
                "CodexAppServerProtocolTests.windowLabelsCoverTheDurationsCodexReports",
                windowLabelsCoverTheDurationsCodexReports
            ),
            (
                "CodexAppServerProtocolTests.rollingUpdatesKeepWindowsTheyOmit",
                rollingUpdatesKeepWindowsTheyOmit
            ),
            (
                "CodexAppServerProtocolTests.codexBinaryIsFoundOnlyWhereItIsExecutable",
                codexBinaryIsFoundOnlyWhereItIsExecutable
            ),
            (
                "DiagnosticsTests.aProvidersOwnWordsNeverReachTheReport",
                aProvidersOwnWordsNeverReachTheReport
            ),
            (
                "DiagnosticsTests.scrubbingCatchesWhatGetsInFromOutside",
                scrubbingCatchesWhatGetsInFromOutside
            ),
            (
                "DiagnosticsTests.aBugReportCanTellWhyTheBridgeFileCannotBeRead",
                aBugReportCanTellWhyTheBridgeFileCannotBeRead
            ),
            (
                "DiagnosticsTests.theReportStaysUsefulForEveryFailureWorthReporting",
                theReportStaysUsefulForEveryFailureWorthReporting
            ),
            (
                "DiagnosticsTests.theReportSaysWhatAMaintainerNeedsToKnow",
                theReportSaysWhatAMaintainerNeedsToKnow
            ),
            (
                "CapacityAlertTests.aWindowFallingBelowTenPercentIsWorthSaying",
                aWindowFallingBelowTenPercentIsWorthSaying
            ),
            (
                "CapacityAlertTests.aWindowSaysItOnceAndThenKeepsQuiet",
                aWindowSaysItOnceAndThenKeepsQuiet
            ),
            (
                "CapacityAlertTests.aWindowThatRecoversIsNewsWhenItFallsAgain",
                aWindowThatRecoversIsNewsWhenItFallsAgain
            ),
            (
                "CapacityAlertTests.aWindowThatTurnsOverIsANewWindow",
                aWindowThatTurnsOverIsANewWindow
            ),
            (
                "CapacityAlertTests.onlyAFreshReadingSpeaks",
                onlyAFreshReadingSpeaks
            ),
            (
                "CapacityAlertTests.aSilencedProviderIsSilentAndStaysCaughtUp",
                aSilencedProviderIsSilentAndStaysCaughtUp
            ),
            (
                "CapacityAlertTests.disconnectingAProviderForgetsWhatWasSaid",
                disconnectingAProviderForgetsWhatWasSaid
            ),
            (
                "CapacitySpeechTests.aWindowSaysEverythingTheCardShows",
                aWindowSaysEverythingTheCardShows
            ),
            (
                "CapacitySpeechTests.aWindowWithNoResetSaysSoRatherThanInventingOne",
                aWindowWithNoResetSaysSoRatherThanInventingOne
            ),
            (
                "CapacitySpeechTests.aProviderSaysWhoItIsAndHowItsReadingStands",
                aProviderSaysWhoItIsAndHowItsReadingStands
            ),
            (
                "CapacitySpeechTests.anUnreadableProviderSaysTheOneThingThatWouldFixIt",
                anUnreadableProviderSaysTheOneThingThatWouldFixIt
            ),
            (
                "CapacitySpeechTests.theClosedStripSaysTheWindowItIsShowing",
                theClosedStripSaysTheWindowItIsShowing
            ),
            (
                "CapacitySpeechTests.theStatesAreTellableApartWithoutColour",
                theStatesAreTellableApartWithoutColour
            ),
            (
                "PreferencesTests.nothingIsEnabledOnAnybodysBehalf",
                nothingIsEnabledOnAnybodysBehalf
            ),
            (
                "PreferencesTests.codexStartsConnectedAndClaudeDoesNot",
                codexStartsConnectedAndClaudeDoesNot
            ),
            (
                "PreferencesTests.onboardingIsOfferedOnlyToSomeoneWhoHasConnectedNothing",
                onboardingIsOfferedOnlyToSomeoneWhoHasConnectedNothing
            ),
            (
                "PreferencesTests.aDeliberateDisconnectOutlivesTheLaunchItWasMadeIn",
                aDeliberateDisconnectOutlivesTheLaunchItWasMadeIn
            ),
            (
                "PreferencesTests.preferencesRefuseAProviderPastTheLimit",
                preferencesRefuseAProviderPastTheLimit
            ),
            (
                "PreferencesTests.aChoiceMadeAnywhereIsTheSameChoice",
                aChoiceMadeAnywhereIsTheSameChoice
            ),
            (
                "PreferencesTests.theBackgroundPaceFallsBackToTheScheduleItCameFrom",
                theBackgroundPaceFallsBackToTheScheduleItCameFrom
            ),
            (
                "CapacityArchiveTests.whatWasSeenLastComesBackAsStale",
                whatWasSeenLastComesBackAsStale
            ),
            (
                "CapacityArchiveTests.aProviderWithNothingToShowIsNotRemembered",
                aProviderWithNothingToShowIsNotRemembered
            ),
            (
                "CapacityArchiveTests.anUnreadableArchiveCostsNothing",
                anUnreadableArchiveCostsNothing
            ),
            (
                "CapacityArchiveTests.aRestartOpensOnWhatWasThereAndAsksForTheRest",
                aRestartOpensOnWhatWasThereAndAsksForTheRest
            ),
            (
                "CapacityArchiveTests.theWaitStretchesWhileAProviderIsFailing",
                theWaitStretchesWhileAProviderIsFailing
            ),
            (
                "CapacityArchiveTests.aFailureWorthRetryingIsToldFromOneThatIsNot",
                aFailureWorthRetryingIsToldFromOneThatIsNot
            ),
            (
                "PreferencesTests.theAppearanceFollowsTheMacUntilChosen",
                theAppearanceFollowsTheMacUntilChosen
            ),
            (
                "SwitchedOffTests.aProviderSwitchedOffIsNotRestoredFromTheArchive",
                aProviderSwitchedOffIsNotRestoredFromTheArchive
            ),
            (
                "SwitchedOffTests.onlyTheProvidersSwitchedOnHaveCards",
                onlyTheProvidersSwitchedOnHaveCards
            ),
            (
                "SwitchedOffTests.nothingConnectedOffersEveryProvidersMarkInOrder",
                nothingConnectedOffersEveryProvidersMarkInOrder
            ),
            (
                "SurfacePlacementTests.theBuiltInDisplayIsTheDefaultAndOneIsAlwaysChosen",
                theBuiltInDisplayIsTheDefaultAndOneIsAlwaysChosen
            ),
            (
                "SurfacePlacementTests.aDisplayThatIsUnpluggedDoesNotStrandTheSurface",
                aDisplayThatIsUnpluggedDoesNotStrandTheSurface
            ),
            (
                "SurfacePlacementTests.aFullscreenApplicationIsToldApartFromAZoomedWindow",
                aFullscreenApplicationIsToldApartFromAZoomedWindow
            ),
            (
                "SurfacePlacementTests.onMacOS27WindowManagerHoldsWhatTheDockHeld",
                onMacOS27WindowManagerHoldsWhatTheDockHeld
            ),
            (
                "SurfacePlacementTests.aSlideBetweenFullscreenSpacesStaysFullscreen",
                aSlideBetweenFullscreenSpacesStaysFullscreen
            ),
            (
                "SurfacePlacementTests.enteringFullscreenIsToldFromTheFirstFrame",
                enteringFullscreenIsToldFromTheFirstFrame
            ),
            (
                "SurfacePlacementTests.leavingFullscreenIsToldOnceTheApplicationHasGone",
                leavingFullscreenIsToldOnceTheApplicationHasGone
            ),
            (
                "SurfacePlacementTests.aZoomedWindowOverASettledDesktopIsNotFullscreen",
                aZoomedWindowOverASettledDesktopIsNotFullscreen
            ),
            (
                "SurfacePlacementTests.aPinnedSurfaceStaysUntilItIsDismissed",
                aPinnedSurfaceStaysUntilItIsDismissed
            ),
            (
                "CapacityPaceTests.theStateIsReadOffWhatIsLeft",
                theStateIsReadOffWhatIsLeft
            ),
            (
                "CapacityPaceTests.theClockDoesNotChangeTheColour",
                theClockDoesNotChangeTheColour
            ),
            (
                "CapacityPaceTests.theHeadlineIsTheScarcestWindow",
                theHeadlineIsTheScarcestWindow
            ),
            (
                "CapacityPaceTests.theCountdownSaysHowLongInTheFewestWords",
                theCountdownSaysHowLongInTheFewestWords
            ),
            (
                "CapacityPaceTests.aGaugeSaysWhenItResetsInOneShortThing",
                aGaugeSaysWhenItResetsInOneShortThing
            ),
            (
                "UnreadCapacityTests.anUnreadSurfaceShowsNoNumbersAtAll",
                anUnreadSurfaceShowsNoNumbersAtAll
            ),
            (
                "NotchGeometryTests.everyOpenPageIsTheSameHeight",
                everyOpenPageIsTheSameHeight
            ),
            (
                "NotchGeometryTests.theCompactSurfaceTakesItsHeightFromTheMenuBar",
                theCompactSurfaceTakesItsHeightFromTheMenuBar
            ),
            (
                "CodexCapacityServiceTests.connectingCodexPublishesFreshCapacityFromTheAppServer",
                connectingCodexPublishesFreshCapacityFromTheAppServer
            ),
            (
                "CodexCapacityServiceTests.connectingTwiceDoesNotStartASecondAppServer",
                connectingTwiceDoesNotStartASecondAppServer
            ),
            (
                "CodexCapacityServiceTests.rollingUpdatesReachTheSurfaceWithoutReconnecting",
                rollingUpdatesReachTheSurfaceWithoutReconnecting
            ),
            (
                "CodexCapacityServiceTests.disconnectingEndsOnlyTheAppServerCapacityNotchStarted",
                disconnectingEndsOnlyTheAppServerCapacityNotchStarted
            ),
            (
                "CodexCapacityServiceTests.missingCodexProducesAnActionableDisconnectedState",
                missingCodexProducesAnActionableDisconnectedState
            ),
            (
                "CodexCapacityServiceTests.anIncompatibleCodexProducesAnActionableDisconnectedState",
                anIncompatibleCodexProducesAnActionableDisconnectedState
            ),
            (
                "CodexCapacityServiceTests.anUnauthenticatedCodexProducesAnActionableDisconnectedState",
                anUnauthenticatedCodexProducesAnActionableDisconnectedState
            ),
            (
                "CodexCapacityServiceTests.anAppServerThatStopsLeavesADisconnectedProviderNotZeroCapacity",
                anAppServerThatStopsLeavesADisconnectedProviderNotZeroCapacity
            ),
            (
                "CodexCapacityServiceTests.capacityNotchOnlyEverSendsCodexReadMethods",
                capacityNotchOnlyEverSendsCodexReadMethods
            ),
            (
                "CodexCapacityServiceTests.aClientRefusesToSendAMethodOutsideTheReadSet",
                aClientRefusesToSendAMethodOutsideTheReadSet
            ),
            (
                "CapacityNotchStoreTests.askingForTheStateAlreadyHeldAnnouncesNothing",
                askingForTheStateAlreadyHeldAnnouncesNothing
            ),
            (
                "CodexCapacityServiceTests.aFailedRefreshKeepsTheLastCapacityAsStale",
                aFailedRefreshKeepsTheLastCapacityAsStale
            ),
            (
                "CodexCapacityServiceTests.aCodexAnswerInAShapeNotKnownKeepsTheLastCapacityAndSaysWhy",
                aCodexAnswerInAShapeNotKnownKeepsTheLastCapacityAndSaysWhy
            ),
            (
                "CodexCapacityServiceTests.aFirstCodexAnswerInAShapeNotKnownSaysWhy",
                aFirstCodexAnswerInAShapeNotKnownSaysWhy
            ),
            (
                "CodexCapacityServiceTests.staleCodexCapacityKeepsTheMomentItWasRead",
                staleCodexCapacityKeepsTheMomentItWasRead
            ),
            (
                "CodexCapacityServiceTests.aCodexThatAnswersWithAnErrorSaysSoOverItsStaleCapacity",
                aCodexThatAnswersWithAnErrorSaysSoOverItsStaleCapacity
            ),
            (
                "CodexCapacityServiceTests.anAccountAnswerOutsideTheSchemaIsNotReadAsSignedOut",
                anAccountAnswerOutsideTheSchemaIsNotReadAsSignedOut
            ),
            (
                "CodexCapacityServiceTests.anAccountAnswerWithNoAccountIsSignedOutAsTheSchemaAllows",
                anAccountAnswerWithNoAccountIsSignedOutAsTheSchemaAllows
            ),
            (
                "CodexCapacityServiceTests.aFirstReadThatFailsHasNoCapacityToHold",
                aFirstReadThatFailsHasNoCapacityToHold
            ),
            (
                "LiveArchiveTests.liveArchiveReadsBackWhatTheAppWrote",
                liveArchiveReadsBackWhatTheAppWrote
            ),
            (
                "LiveCodexTests.liveCodexPublishesFreshCapacity",
                liveCodexPublishesFreshCapacity
            ),
            (
                "ClaudeCapacityServiceTests.connectingClaudeReadsFreshCapacityPublishedByClaudeCode",
                connectingClaudeReadsFreshCapacityPublishedByClaudeCode
            ),
            (
                "ClaudeCapacityServiceTests.anOldClaudeStatusLineReadingIsStaleCapacity",
                anOldClaudeStatusLineReadingIsStaleCapacity
            ),
            (
                "ClaudeCapacityServiceTests.aFailedClaudeBridgeRefreshKeepsTheLastCapacityAsStale",
                aFailedClaudeBridgeRefreshKeepsTheLastCapacityAsStale
            ),
            (
                "ClaudeCapacityServiceTests.publishingClaudeStatusLineWritesOnlyCapacitySnapshot",
                publishingClaudeStatusLineWritesOnlyCapacitySnapshot
            ),
            (
                "ClaudeCapacityServiceTests.fileClaudeCapacitySourceReadsPublishedQuotaWindows",
                fileClaudeCapacitySourceReadsPublishedQuotaWindows
            ),
            (
                "ClaudeCapacityServiceTests.aWindowClaudeCodeDoesNotSendIsNoDataNotWhole",
                aWindowClaudeCodeDoesNotSendIsNoDataNotWhole
            ),
            (
                "ClaudeCapacityServiceTests.theSessionWhoseLimitsChangedLastIsBelieved",
                theSessionWhoseLimitsChangedLastIsBelieved
            ),
            (
                "ClaudeCapacityServiceTests.missingClaudeStatusLineSnapshotIsActionableAndDisconnected",
                missingClaudeStatusLineSnapshotIsActionableAndDisconnected
            ),
            (
                "ClaudeCapacityServiceTests.disconnectingClaudeClearsFreshCapacityFromTheSurface",
                disconnectingClaudeClearsFreshCapacityFromTheSurface
            ),
            (
                "MusicTests.theSpeakerIsStruckThroughWhenNothingIsHeard",
                theSpeakerIsStruckThroughWhenNothingIsHeard
            ),
            (
                "MusicTests.mutingEmptiesTheBarAndKeepsTheLevel",
                mutingEmptiesTheBarAndKeepsTheLevel
            ),
            (
                "MusicTests.aFullLineFromTheAdapterSaysWhatIsPlaying",
                aFullLineFromTheAdapterSaysWhatIsPlaying
            ),
            (
                "MusicTests.aDiffLineUpdatesTheLastFullOne",
                aDiffLineUpdatesTheLastFullOne
            ),
            (
                "MusicTests.theArtworkOutlivesAFullLineForTheSameTrackOnly",
                theArtworkOutlivesAFullLineForTheSameTrackOnly
            ),
            (
                "MusicTests.aMusicModuleThatCannotReadSaysSoInTheReport",
                aMusicModuleThatCannotReadSaysSoInTheReport
            ),
            (
                "MusicTests.eachControlIsTheCommandTheAdapterExpects",
                eachControlIsTheCommandTheAdapterExpects
            ),
            (
                "MusicTests.thePositionMovesOnFromWhenItWasReported",
                thePositionMovesOnFromWhenItWasReported
            ),
            (
                "MusicTests.aLineTheAdapterDidNotWriteIsNotAReading",
                aLineTheAdapterDidNotWriteIsNotAReading
            ),
            (
                "MusicTests.theRowShowsWhilePlayingAndLingersBrieflyOnPause",
                theRowShowsWhilePlayingAndLingersBrieflyOnPause
            ),
            (
                "MusicTests.nothingPlayingOrUnreadableShowsNoRow",
                nothingPlayingOrUnreadableShowsNoRow
            ),
            (
                "MusicTests.aTrackChangeThroughNothingKeepsThePage",
                aTrackChangeThroughNothingKeepsThePage
            ),
            (
                "MusicTests.aTrackChangeKeepsTheLastCoverUntilItsOwnArrives",
                aTrackChangeKeepsTheLastCoverUntilItsOwnArrives
            ),
            (
                "MusicTests.aTrackInABrowserTabIsTheBrowsers",
                aTrackInABrowserTabIsTheBrowsers
            ),
            (
                "MusicTests.theLastTrackIsRememberedAfterItGoes",
                theLastTrackIsRememberedAfterItGoes
            ),
        ]
        let selection = CommandLine.arguments.dropFirst().first
        let selected = tests.filter { selection == nil || $0.0 == selection }

        guard !selected.isEmpty else {
            print("No test matched \(selection ?? "")")
            exit(2)
        }

        var failures = 0
        for (name, test) in selected {
            do {
                try await test()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        exit(failures == 0 ? 0 : 1)
    }
}
