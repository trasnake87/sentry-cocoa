#if !SDK_V10
@_spi(Private) import SentryTestUtils
#if SWIFT_PACKAGE
@_spi(Private) @testable import SentrySwift
#else
@_spi(Private) @testable import Sentry
#endif
import UIKit
import XCTest

#if os(iOS) || os(tvOS)
final class SentryANRTrackerV2Tests: XCTestCase {

    private let waitTimeout: TimeInterval = 10.0
    private var timeoutInterval: TimeInterval = 2

    private func getSut() throws -> (SentryANRTracker, TestCurrentDateProvider, TestDisplayLinkWrapper, TestSentryApplicationStateProvider, SentryTestThreadWrapper, SentryFramesTracker) {

        let currentDate = TestCurrentDateProvider()

        let applicationStateProvider = TestSentryApplicationStateProvider()
        let dispatchQueue = TestSentryDispatchQueueWrapper()
        let threadWrapper = SentryTestThreadWrapper()

        let displayLinkWrapper = TestDisplayLinkWrapper(dateProvider: currentDate)

        SentryDependencyContainer.sharedInstance().dateProvider = currentDate

        let framesTracker = SentryFramesTracker(displayLinkWrapper: displayLinkWrapper, dateProvider: currentDate, dispatchQueueWrapper: dispatchQueue, notificationCenter: TestNSNotificationCenterWrapper(), delayedFramesTracker: TestDelayedWrapper(keepDelayedFramesDuration: 30, dateProvider: currentDate))

        framesTracker.start()

        // Add a couple of normal frames, so that querying for frame delay
        // has enough data to not return -1.
        for _ in 0..<1_000 {
            displayLinkWrapper.normalFrame()
        }

        return (SentryANRTracker(helper: SentryANRTrackerV2(
            timeoutInterval: timeoutInterval,
            applicationStateProvider: applicationStateProvider,
            dispatchQueueWrapper: dispatchQueue,
            threadWrapper: threadWrapper,
            framesTracker: framesTracker)), currentDate, displayLinkWrapper, applicationStateProvider, threadWrapper, framesTracker)
    }

    /// When no frame gets rendered its a fully blocking app hang.
    ///
    /// [||||--------------]
    /// - means no frame rendered
    /// | means a rendered frame
    func testFullyBlockingAppHang_Reported() throws {
        let (sut, currentDate, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: listener)

        // The app must hang for slightly over the timeoutInterval to report an app hang
        var advanced = 0.0
        while advanced < timeoutInterval + 0.1 {
            advanced += 0.01
            currentDate.advance(by: 0.01)
        }

        wait(for: [listener.anrDetectedExpectation], timeout: timeoutInterval)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        for _ in 0..<20 {
            displayLinkWrapper.normalFrame()
        }

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)
        XCTAssertLessThanOrEqual(2.0, actual.minDuration)
        XCTAssertGreaterThanOrEqual(4.0, actual.maxDuration)
        XCTAssertEqual(0.8, actual.maxDuration - actual.minDuration, accuracy: 0.01)
    }

    func testFullyBlockingAppHangWithLargeTimeoutInterval_ReportsCorrectResult() throws {
        timeoutInterval = 5.0
        let (sut, currentDate, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: listener)

        // The app must hang for slightly over the timeoutInterval to report an app hang
        var advanced = 0.0
        while advanced < timeoutInterval + 0.1 {
            advanced += 0.01
            currentDate.advance(by: 0.01)
        }

        wait(for: [listener.anrDetectedExpectation], timeout: timeoutInterval)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        for _ in 0..<20 {
            displayLinkWrapper.normalFrame()
        }

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)
        XCTAssertLessThanOrEqual(5.0, actual.minDuration)
        XCTAssertGreaterThanOrEqual(8.0, actual.maxDuration)
        XCTAssertEqual(2.0, actual.maxDuration - actual.minDuration, accuracy: 0.01)
    }

    func testFullyBlockingAppHangWithSmallTimeoutInterval_ReportsCorrectResult() throws {
        timeoutInterval = 0.5
        let (sut, currentDate, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: listener)

        // The app must hang for slightly over the timeoutInterval to report an app hang
        var advanced = 0.0
        while advanced < timeoutInterval + 0.1 {
            advanced += 0.01
            currentDate.advance(by: 0.01)
        }

        wait(for: [listener.anrDetectedExpectation], timeout: timeoutInterval)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        for _ in 0..<20 {
            displayLinkWrapper.normalFrame()
        }

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)
        XCTAssertLessThanOrEqual(timeoutInterval, actual.minDuration)
        XCTAssertGreaterThanOrEqual(2.0, actual.maxDuration)
        XCTAssertEqual(0.2, actual.maxDuration - actual.minDuration, accuracy: 0.01)
    }

    /// For a non fully blocking app hang at least one frame must be rendered during the hang.
    ///
    /// [||||------|--------]
    /// - means no frame rendered
    /// | means a rendered frame
    func testNonFullyBlockingAppHang_Reported() throws {
        let (sut, _, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()

        sut.add(listener: listener)

        triggerNonFullyBlockingAppHang(displayLinkWrapper)

        wait(for: [listener.anrDetectedExpectation], timeout: waitTimeout)
        XCTAssertEqual(listener.anrsDetected.last, .nonFullyBlocking)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)
        XCTAssertLessThanOrEqual(2.0, actual.minDuration)
        XCTAssertGreaterThanOrEqual(4.0, actual.maxDuration)
        XCTAssertEqual(0.8, actual.maxDuration - actual.minDuration, accuracy: 0.01)
    }

    /// 3 frozen frames aren't enough for a non fully blocking app hang.
    ///
    /// [||||---|------|-----]
    /// - means no frame rendered
    /// | means a rendered frame
    func testAlmostNonFullyBlockingAppHang_NoneReported() throws {
        let (sut, _, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        sut.add(listener: listener)

        displayLinkWrapper.frameWith(delay: 0.7)
        displayLinkWrapper.frameWith(delay: 0.7)
        displayLinkWrapper.frameWith(delay: 0.7)

        wait(for: [listener.anrDetectedExpectation], timeout: waitTimeout)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)
    }

    /// [||||------------]
    /// - means no frame rendered
    /// | means a rendered frame
    func testAlmostFullyBlockingAppHang_NoneReported() throws {
        let (sut, dateProvider, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        sut.add(listener: listener)

        for _ in 0..<100 {
            displayLinkWrapper.normalFrame()
        }
        // The app must hang for slightly over the timeoutInterval to report an app hang
        dateProvider.advance(by: timeoutInterval - 0.1)

        wait(for: [listener.anrDetectedExpectation], timeout: waitTimeout)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)
    }

    /// One fully blocking app hang followed by non fully blocking
    ///
    /// [||||-----------------|--------]
    /// - means no frame rendered
    /// | means a rendered frame
    func testFullyBlockingFollowedByNonFullyBlocking_OnlyFirstReported() throws {
        let (sut, dateProvider, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()

        sut.add(listener: listener)

        triggerFullyBlockingAppHang(dateProvider)

        wait(for: [listener.anrDetectedExpectation], timeout: waitTimeout)

        triggerNonFullyBlockingAppHang(displayLinkWrapper)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)
        XCTAssertLessThanOrEqual(4.0, actual.minDuration)
        XCTAssertGreaterThanOrEqual(6.0, actual.maxDuration)
        XCTAssertEqual(0.8, actual.maxDuration - actual.minDuration, accuracy: 0.01)
    }

    /// Fully blocking app hang, app hang stops, again fully blocking app hang
    ///
    /// [||||-----------------||||||||---------------]
    /// - means no frame rendered
    /// | means a rendered frame
    func testFullyBlockingFollowedByFullyBlocking_BothReported() throws {
        let (sut, currentDate, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        // We use multiple listeners here, because we can't reset the XCTestExpectation
        let secondHangDuration = timeoutInterval + 0.1
        let firstListener = SentryANRTrackerV2TestDelegate(blockOnFirstANRStopped: { [currentDate, secondHangDuration] in
            // TestSentryDispatchQueueWrapper executes async blocks synchronously. Advancing the
            // clock here deterministically starts the second hang before stop notification returns.
            currentDate.advance(by: secondHangDuration)
        })
        firstListener.anrDetectedExpectation.expectedFulfillmentCount = 2
        firstListener.anrStoppedExpectation.expectedFulfillmentCount = 2
        sut.add(listener: firstListener)

        let secondListener = SentryANRTrackerV2TestDelegate()
        secondListener.anrDetectedExpectation.assertForOverFulfill = false
        secondListener.anrStoppedExpectation.assertForOverFulfill = false
        sut.add(listener: secondListener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [secondListener.anrDetectedExpectation], timeout: waitTimeout)

        let thirdListener = SentryANRTrackerV2TestDelegate()
        thirdListener.anrStoppedExpectation.expectedFulfillmentCount = 2
        sut.add(listener: thirdListener)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [secondListener.anrStoppedExpectation], timeout: waitTimeout)
        wait(for: [thirdListener.anrDetectedExpectation], timeout: waitTimeout)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [thirdListener.anrStoppedExpectation], timeout: waitTimeout)

        wait(for: [firstListener.anrDetectedExpectation, firstListener.anrStoppedExpectation], timeout: waitTimeout)
    }

    /// Long fully blocking app hang, app hang stops, no non fully blocking gets falsely reported
    ///
    /// [||||--------------------------------------|||||||]
    /// - means no frame rendered
    /// | means a rendered frame
    func testFullyBlockingFollowedByNormalFrames_OneReported() throws {
        let (sut, currentDate, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let firstListener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: firstListener)

        let secondListener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: secondListener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [secondListener.anrDetectedExpectation], timeout: waitTimeout)

        let thirdListener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false)
        sut.add(listener: thirdListener)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [firstListener.anrDetectedExpectation, firstListener.anrStoppedExpectation, thirdListener.anrStoppedExpectation, thirdListener.anrDetectedExpectation], timeout: waitTimeout)

        let firstActual = try XCTUnwrap(firstListener.anrStoppedResults.last)
        XCTAssertGreaterThanOrEqual(firstActual.minDuration, 2.0, "minDuration should be greater than or equal to 2.0")
        XCTAssertLessThanOrEqual(firstActual.maxDuration, 5.0, "maxDuration should be less than or equal to 5.0")
        XCTAssertEqual(0.8, firstActual.maxDuration - firstActual.minDuration, accuracy: 0.01)

        let secondActual = try XCTUnwrap(secondListener.anrStoppedResults.last)
        XCTAssertGreaterThanOrEqual(secondActual.minDuration, 2.0, "minDuration should be greater than or equal to 2.0")
        XCTAssertLessThanOrEqual(secondActual.maxDuration, 5.0, "maxDuration should be less than or equal to 5.0")
        XCTAssertEqual(0.8, secondActual.maxDuration - secondActual.minDuration, accuracy: 0.01)

        let thirdActual = try XCTUnwrap(thirdListener.anrStoppedResults.last)
        XCTAssertGreaterThanOrEqual(thirdActual.minDuration, 2.0, "minDuration should be greater than or equal to 2.0")
        XCTAssertLessThanOrEqual(thirdActual.maxDuration, 5.0, "maxDuration should be less than or equal to 5.0")
        XCTAssertEqual(0.8, thirdActual.maxDuration - thirdActual.minDuration, accuracy: 0.01)
    }

    func testTwoListeners_FullyBlocking_ReportedToBothListeners() throws {
        let (sut, currentDate, displayLinkWrapper, _, _, _) = try getSut()
        defer { sut.clear() }

        let firstListener = SentryANRTrackerV2TestDelegate()

        sut.add(listener: firstListener)

        let secondListener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: secondListener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [firstListener.anrDetectedExpectation, secondListener.anrDetectedExpectation], timeout: waitTimeout)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [firstListener.anrStoppedExpectation, secondListener.anrStoppedExpectation], timeout: waitTimeout)
    }

    func testFullyBlockingAppHang_ButAppInBackground_NoneReported() throws {
        let (sut, currentDate, displayLinkWrapper, applicationStateProvider, _, _) = try getSut()
        defer { sut.clear() }

        applicationStateProvider.isApplicationInForeground = false

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        sut.add(listener: listener)

        triggerFullyBlockingAppHang(currentDate)

        renderNormalFramesToStopAppHang(displayLinkWrapper)

        wait(for: [listener.anrDetectedExpectation, listener.anrStoppedExpectation], timeout: waitTimeout)
    }

    func testClear_WhenWorkerWakesInBackground_DoesNotLogAfterStopping() throws {
        // -- Arrange --
        let (sut, _, _, applicationStateProvider, threadWrapper, _) = try getSut()
        let oldDebug = SentrySDKLog.isDebug
        let oldLevel = SentrySDKLog.diagnosticLevel
        let oldOutput = SentrySDKLog.getLogOutput()
        let logOutput = TestLogOutput(logsToConsole: false)
        let sleepStarted = expectation(description: "ANR worker started sleeping")
        let allowSleepToFinish = DispatchSemaphore(value: 0)

        defer {
            SentrySDKLogSupport.configure(oldDebug, diagnosticLevel: oldLevel)
            SentrySDKLog.setOutput(oldOutput)
        }

        SentrySDKLog.setLogOutput(logOutput)
        SentrySDKLogSupport.configure(true, diagnosticLevel: .debug)
        applicationStateProvider.isApplicationInForeground = false
        threadWrapper.blockWhenSleeping = {
            sleepStarted.fulfill()
            allowSleepToFinish.wait()
        }

        // -- Act --
        sut.add(listener: SentryANRTrackerV2TestDelegate())
        wait(for: [sleepStarted], timeout: waitTimeout)
        sut.clear()
        allowSleepToFinish.signal()
        wait(for: [threadWrapper.threadFinishedExpectation], timeout: waitTimeout)

        // -- Assert --
        XCTAssertFalse(logOutput.loggedMessages.contains {
            $0.contains("Ignoring potential app hangs because the app is in the background")
        })
    }

    func testAppSuspended_NoAppHang() throws {
        let (sut, currentDate, _, _, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        // When the app is suspended the thread sleep can take way longer
        // than expected.
        threadWrapper.blockWhenSleeping = {
            let delta = self.timeoutInterval * 2

            currentDate.setDate(date: currentDate.date().addingTimeInterval(delta))
        }

        sut.add(listener: listener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [listener.anrDetectedExpectation, listener.anrStoppedExpectation], timeout: waitTimeout)
    }

    /// Background time should be excluded from hang duration.
    ///
    /// [||||------BACKGROUND------||||]
    /// | means a rendered frame
    /// - means no frame rendered
    func testFullyBlockingAppHang_whenAppGoesToBackgroundDuringHang_shouldNotIncludeBackgroundTimeInDuration() throws {
        timeoutInterval = 0.5
        let (sut, currentDate, displayLinkWrapper, applicationStateProvider, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: listener)

        let backgroundDuration = 3.0
        var backgroundIterations = 0
        let iterationsInBackground = 3
        let backgroundCompleted = expectation(description: "Background iterations completed")

        threadWrapper.blockWhenSleeping = {
            guard listener.anrsDetected.count > 0 else { return }

            switch backgroundIterations {
            case 0:
                applicationStateProvider.isApplicationInForeground = false
                fallthrough
            case 1..<iterationsInBackground:
                currentDate.advance(by: backgroundDuration / Double(iterationsInBackground))
                backgroundIterations += 1
            case iterationsInBackground:
                applicationStateProvider.isApplicationInForeground = true
                backgroundIterations += 1
                backgroundCompleted.fulfill()
            default:
                break
            }
        }

        triggerFullyBlockingAppHang(currentDate)
        wait(for: [listener.anrDetectedExpectation], timeout: waitTimeout)

        wait(for: [backgroundCompleted], timeout: waitTimeout)
        threadWrapper.blockWhenSleeping = {}

        renderNormalFramesToStopAppHang(displayLinkWrapper)
        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)

        XCTAssertLessThan(actual.maxDuration, backgroundDuration)
    }

    /// Multiple background periods should all be excluded.
    ///
    /// [||||---BG---||---BG---||||]
    /// | means a rendered frame
    /// - means no frame rendered
    func testFullyBlockingAppHang_whenAppGoesToBackgroundMultipleTimes_shouldExcludeAllBackgroundTime() throws {
        timeoutInterval = 0.5
        let (sut, currentDate, displayLinkWrapper, applicationStateProvider, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: listener)

        let backgroundDurationPerCycle = 3.0
        let numberOfBackgroundCycles = 2
        let iterationsPerCycle = 2
        let totalBackgroundDuration = backgroundDurationPerCycle * Double(numberOfBackgroundCycles)
        var iteration = 0
        let totalIterations = numberOfBackgroundCycles * (iterationsPerCycle + 1)
        let backgroundCompleted = expectation(description: "Background iterations completed")

        threadWrapper.blockWhenSleeping = {
            guard listener.anrsDetected.count > 0 else { return }
            guard iteration < totalIterations else { return }

            let cycleIteration = iteration % (iterationsPerCycle + 1)

            if cycleIteration == 0 {
                applicationStateProvider.isApplicationInForeground = false
            }

            if cycleIteration < iterationsPerCycle {
                currentDate.advance(by: backgroundDurationPerCycle / Double(iterationsPerCycle))
            } else {
                applicationStateProvider.isApplicationInForeground = true
            }

            iteration += 1

            if iteration == totalIterations {
                backgroundCompleted.fulfill()
            }
        }

        triggerFullyBlockingAppHang(currentDate)
        wait(for: [listener.anrDetectedExpectation], timeout: waitTimeout)

        wait(for: [backgroundCompleted], timeout: waitTimeout)
        threadWrapper.blockWhenSleeping = {}

        renderNormalFramesToStopAppHang(displayLinkWrapper)
        wait(for: [listener.anrStoppedExpectation], timeout: waitTimeout)

        let actual = try XCTUnwrap(listener.anrStoppedResults.last)

        XCTAssertLessThan(actual.maxDuration, totalBackgroundDuration)
    }

    /// Background time from previous hang should not affect the next hang.
    ///
    /// [||||---BG---||||||||||---BG---||||]
    /// | means a rendered frame
    /// - means no frame rendered
    func testFullyBlockingAppHang_whenSecondHangAfterBackgroundedHang_shouldNotIncludePreviousBackgroundTime() throws {
        timeoutInterval = 0.5
        let (sut, currentDate, displayLinkWrapper, applicationStateProvider, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let firstListener = SentryANRTrackerV2TestDelegate()
        firstListener.anrDetectedExpectation.assertForOverFulfill = false
        firstListener.anrStoppedExpectation.assertForOverFulfill = false
        sut.add(listener: firstListener)

        let firstHangBackgroundDuration = 3.0
        var firstHangBackgroundIterations = 0
        let firstIterationsInBackground = 3
        let firstBackgroundCompleted = expectation(description: "First background completed")

        threadWrapper.blockWhenSleeping = {
            guard firstListener.anrsDetected.count > 0 else { return }

            switch firstHangBackgroundIterations {
            case 0:
                applicationStateProvider.isApplicationInForeground = false
                fallthrough
            case 1..<firstIterationsInBackground:
                currentDate.advance(by: firstHangBackgroundDuration / Double(firstIterationsInBackground))
                firstHangBackgroundIterations += 1
            case firstIterationsInBackground:
                applicationStateProvider.isApplicationInForeground = true
                firstHangBackgroundIterations += 1
                firstBackgroundCompleted.fulfill()
            default:
                break
            }
        }

        triggerFullyBlockingAppHang(currentDate)
        wait(for: [firstListener.anrDetectedExpectation], timeout: waitTimeout)

        wait(for: [firstBackgroundCompleted], timeout: waitTimeout)
        threadWrapper.blockWhenSleeping = {}

        renderNormalFramesToStopAppHang(displayLinkWrapper)
        wait(for: [firstListener.anrStoppedExpectation], timeout: waitTimeout)

        let secondListener = SentryANRTrackerV2TestDelegate()
        sut.add(listener: secondListener)

        let secondHangBackgroundDuration = 3.0
        var secondHangBackgroundIterations = 0
        let secondIterationsInBackground = 3
        let secondBackgroundCompleted = expectation(description: "Second background completed")

        threadWrapper.blockWhenSleeping = {
            guard secondListener.anrsDetected.count > 0 else { return }

            switch secondHangBackgroundIterations {
            case 0:
                applicationStateProvider.isApplicationInForeground = false
                fallthrough
            case 1..<secondIterationsInBackground:
                currentDate.advance(by: secondHangBackgroundDuration / Double(secondIterationsInBackground))
                secondHangBackgroundIterations += 1
            case secondIterationsInBackground:
                applicationStateProvider.isApplicationInForeground = true
                secondHangBackgroundIterations += 1
                secondBackgroundCompleted.fulfill()
            default:
                break
            }
        }

        triggerFullyBlockingAppHang(currentDate)
        wait(for: [secondListener.anrDetectedExpectation], timeout: waitTimeout)

        wait(for: [secondBackgroundCompleted], timeout: waitTimeout)
        threadWrapper.blockWhenSleeping = {}

        renderNormalFramesToStopAppHang(displayLinkWrapper)
        wait(for: [secondListener.anrStoppedExpectation], timeout: waitTimeout)

        let secondHangDuration = try XCTUnwrap(secondListener.anrStoppedResults.last)
        XCTAssertLessThan(secondHangDuration.maxDuration, firstHangBackgroundDuration)
    }

    func testRemoveListener_StopsReporting() throws {
        let (sut, currentDate, _, _, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        let mainBlockExpectation = expectation(description: "Main Block")

        threadWrapper.blockWhenSleeping = {
            sut.remove(listener: listener)
            mainBlockExpectation.fulfill()
        }

        triggerFullyBlockingAppHang(currentDate)

        sut.add(listener: listener)

        wait(for: [listener.anrDetectedExpectation, listener.anrStoppedExpectation, mainBlockExpectation], timeout: waitTimeout)
    }

    func testClear_StopsReporting() throws {
        let (sut, currentDate, _, _, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let firstListener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)
        let secondListener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        let mainBlockExpectation = expectation(description: "Main Block")

        //Having a second Listener may cause the tracker to execute more than once before the end of the test
        mainBlockExpectation.assertForOverFulfill = false

        threadWrapper.blockWhenSleeping = {
            sut.clear()
            mainBlockExpectation.fulfill()
        }

        sut.add(listener: secondListener)
        sut.add(listener: firstListener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [firstListener.anrDetectedExpectation, firstListener.anrStoppedExpectation, mainBlockExpectation, secondListener.anrStoppedExpectation, secondListener.anrDetectedExpectation], timeout: waitTimeout)
    }

    func testNotRemovingDeallocatedListener_DoesNotRetainListener_AndStopsTracking() throws {
        let (sut, currentDate, _, _, _, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        weak var releasedListener: DelegateWrapper?
        autoreleasepool {
            let wrapper = DelegateWrapper(helper: listener)
            releasedListener = wrapper
            sut.helper.addListener(wrapper)
        }
        XCTAssertNil(releasedListener, "The tracker must not retain its listeners")

        sut.add(listener: listener)
        sut.remove(listener: listener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [listener.anrDetectedExpectation, listener.anrStoppedExpectation], timeout: self.waitTimeout)
    }

    func testClearStopsThread() throws {
        let (sut, _, _, _, threadWrapper, _) = try getSut()

        sut.add(listener: SentryANRTrackerV2TestDelegate())

        sut.clear()

        wait(for: [threadWrapper.threadFinishedExpectation], timeout: 5)
        XCTAssertEqual(0, threadWrapper.threads.count)
    }

    func testClearDirectlyAfterStart_FullyBlocking_NotReported() throws {
        let (sut, currentDate, _, _, threadWrapper, _) = try getSut()
        defer { sut.clear() }

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        let invocations = 10
        for _ in 0..<invocations {
            sut.add(listener: listener)
            sut.clear()
        }

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [listener.anrDetectedExpectation, listener.anrStoppedExpectation], timeout: self.waitTimeout)

        XCTAssertEqual(0, threadWrapper.threads.count)
        // As it can take a while until a new thread is started, the thread tracker may start
        // and finish multiple times. Most importantly, the code covers every start with one finish.
        XCTAssertEqual(threadWrapper.threadStartedInvocations.count, threadWrapper.threadFinishedInvocations.count, "The number of started and finished threads should be equal, otherwise the ANR tracker could run.")
    }

    func testNoFrameDelayData_FullyBlocking_NotReported() throws {
        let (sut, currentDate, _, _, _, framesTracker) = try getSut()
        defer { sut.clear() }

        framesTracker.stop()

        let listener = SentryANRTrackerV2TestDelegate(shouldANRBeDetected: false, shouldStoppedBeCalled: false)

        sut.add(listener: listener)

        triggerFullyBlockingAppHang(currentDate)

        wait(for: [listener.anrDetectedExpectation, listener.anrStoppedExpectation], timeout: waitTimeout)
    }

    private func renderNormalFramesToStopAppHang(_ displayLinkWrapper: TestDisplayLinkWrapper) {

        // We need to render normal frames until we reach the
        // required healthy non frames delay threshold for the tracker to
        // mark the app hang as stopped
        let requiredNormalFrameDuration = timeoutInterval / 5 * 2 * 0.80 + displayLinkWrapper.currentFrameRate.tickDuration

        var advanced = 0.0
        while advanced <= requiredNormalFrameDuration {
            advanced += displayLinkWrapper.currentFrameRate.tickDuration
            displayLinkWrapper.normalFrame()
        }
    }

    private func triggerFullyBlockingAppHang(_ currentDate: TestCurrentDateProvider) {
        // The app must hang for slightly over the timeoutInterval to report an app hang
        var advanced = 0.0
        while advanced < timeoutInterval + 0.1 {
            advanced += 0.01
            currentDate.advance(by: 0.01)
        }
    }

    private func triggerNonFullyBlockingAppHang(_ displayLinkWrapper: TestDisplayLinkWrapper) {
        displayLinkWrapper.frameWith(delay: 1.0)
        displayLinkWrapper.frameWith(delay: 1.0)
    }

}

class SentryANRTrackerV2TestDelegate: NSObject, SentryANRTrackerDelegate {

    let anrDetectedExpectation = XCTestExpectation(description: "Test Delegate ANR Detection")
    let anrStoppedExpectation  = XCTestExpectation(description: "Test Delegate ANR Stopped")
    let anrsDetected = Invocations<SentryANRType>()
    let anrStoppedResults = Invocations<SentryANRStoppedResult>()
    private let blockOnFirstANRStopped: (() -> Void)?

    init(shouldANRBeDetected: Bool = true, shouldStoppedBeCalled: Bool = true, blockOnFirstANRStopped: (() -> Void)? = nil) {
        self.blockOnFirstANRStopped = blockOnFirstANRStopped

        if !shouldANRBeDetected {
            anrDetectedExpectation.isInverted = true
        }

        if !shouldStoppedBeCalled {
            anrStoppedExpectation.isInverted = true
        }

        anrDetectedExpectation.assertForOverFulfill = true
        anrStoppedExpectation.assertForOverFulfill = true
    }

    func anrStopped(result: SentryANRStoppedResult?) {
        guard let nonNilResult = result else {
            XCTFail("ANRStopped result is nil")
            return
        }

        anrStoppedResults.record(nonNilResult)

        if anrStoppedResults.count == 1 {
            blockOnFirstANRStopped?()
        }

        anrStoppedExpectation.fulfill()
    }

    func anrDetected(type: SentryANRType) {
        anrsDetected.record(type)
        anrDetectedExpectation.fulfill()
    }
}

// MARK: - Expensify/App#106340 runtime evidence (T1)

/// Deterministic, time-stepped simulation of the V2 watchdog at the SDK default timeout (2 s).
///
/// `SentryTestThreadWrapper.sleep(forTimeInterval:)` does not sleep; it calls `blockWhenSleeping`.
/// The hook below turns every watchdog sleep into exactly one sleep interval (timeout / 5 = 0.4 s)
/// of simulated time, advanced in 1/60 s display-link ticks on a `TestCurrentDateProvider`. On every
/// tick in which the scenario delivers frames, the display-link callback of the real
/// `SentryFramesTracker` runs. Lifecycle notifications go through one `TestNSNotificationCenterWrapper`
/// shared by the real `SentryFramesTracker` (pauses on willResignActive, unpauses on didBecomeActive)
/// and the real `SentryThreadsafeApplication` (the production `SentryApplicationStateProvider`).
final class SentryANRTrackerV2Issue106340Tests: XCTestCase {

    private let timeoutInterval: TimeInterval = 2 // SDK default appHangTimeoutInterval
    private static let ticksPerSecond = 60.0
    private static let ticksPerSleep = 24 // 0.4 s = timeoutInterval / 5 at 60 Hz

    private struct Stall {
        /// Simulated second of the last frame before the stall.
        let lastFrameAt: Double
        /// Seconds until the next frame is delivered.
        let length: Double
    }

    private struct Scenario {
        var name: String
        var endAt: Double
        var stalls: [Stall] = []
        var notifications: [(at: Double, name: Notification.Name)] = []
        /// A watchdog sleep that starts inside start..<end returns only at `end` (suspended process).
        var suspensions: [(start: Double, end: Double)] = []
        var probeMainThreadAt: Double?
        var captureMainThreadStackOnDetection = false
        /// When set, every watchdog sleep lasts 24 + uniform(0...maxJitterTicks) ticks (seeded, deterministic).
        var jitterSeed: UInt64?
        var maxJitterTicks = 0
        /// Capture SDK debug logs and count the watchdog/frames-tracker skip messages.
        var captureLogs = false
    }

    private static let watchedLogMessages = [
        "Ignoring potential app hangs because the app is in the background",
        "Ignoring App Hang because the delta is too big",
        "Not calculating frames delay because frames tracker isn't running",
        "Not calculating frames delay because no frames yet recorded",
        "Not calculating frames delay because the record of delayed frames",
        "Ignoring app hang cause one happened recently"
    ]

    private final class Outcome {
        var detected: [(type: SentryANRType, at: Double)] = []
        var stopped: [(minDuration: Double, maxDuration: Double, at: Double)] = []
        var polls = 0
        var mainThreadProbe: (at: Double, ran: Bool, latencyMs: Double)?
        var mainThreadStackAtDetection: [String] = []
        var logCounts: [String: Int] = [:]

        var messages: [String] {
            stopped.map { String(format: "between %.1f and %.1f seconds", $0.minDuration, $0.maxDuration) }
        }
    }

    private final class Recorder: NSObject, SentryANRTrackerDelegate {
        let outcome: Outcome
        let now: () -> Double
        let onDetected: () -> Void

        init(outcome: Outcome, now: @escaping () -> Double, onDetected: @escaping () -> Void) {
            self.outcome = outcome
            self.now = now
            self.onDetected = onDetected
        }

        func anrDetected(type: SentryANRType) {
            outcome.detected.append((type, now()))
            onDetected()
        }

        func anrStopped(result: SentryANRStoppedResult?) {
            guard let result else {
                XCTFail("anrStopped with nil result")
                return
            }
            outcome.stopped.append((result.minDuration, result.maxDuration, now()))
        }
    }

    private static func typeName(_ type: SentryANRType) -> String {
        switch type {
        case .fullyBlocking: return "fullyBlocking"
        case .nonFullyBlocking: return "nonFullyBlocking"
        case .fatalFullyBlocking: return "fatalFullyBlocking"
        case .fatalNonFullyBlocking: return "fatalNonFullyBlocking"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }

    private func log(_ scenario: Scenario, _ outcome: Outcome) {
        let detected = outcome.detected.map { "\(Self.typeName($0.type))@t=\(String(format: "%.3f", $0.at))" }
        let stopped = outcome.stopped.map {
            String(format: "min=%.3f max=%.3f @t=%.3f", $0.minDuration, $0.maxDuration, $0.at)
        }
        print("[T1-106340] \(scenario.name) | polls=\(outcome.polls) | detected=\(detected) | stopped=\(stopped) | message=\(outcome.messages)")
        if let probe = outcome.mainThreadProbe {
            print(String(format: "[T1-106340] \(scenario.name) | main-queue probe at t=%.3f ran=%@ latency=%.2f ms", probe.at, probe.ran ? "YES" : "NO", probe.latencyMs))
        }
        if !outcome.logCounts.isEmpty {
            let counts = Self.watchedLogMessages.map { "\"\($0)\": \(outcome.logCounts[$0] ?? 0)" }
            print("[T1-106340] \(scenario.name) | SDK debug log counts: \(counts)")
        }
        if !outcome.mainThreadStackAtDetection.isEmpty {
            print("[T1-106340] \(scenario.name) | main thread stack at detection (top first): \(outcome.mainThreadStackAtDetection)")
        }
    }

    private static func mainThreadStack() -> [String] {
        let threads = SentryThreadInspector(options: Options()).getCurrentThreadsWithStackTrace()
        guard let main = threads.first, main.isMain?.boolValue == true else { return ["<main thread not found>"] }
        let frames = main.stacktrace?.frames ?? []
        return frames.reversed().prefix(16).map { frame -> String in
            if let function = frame.function, function != "<redacted>" { return function }
            guard let address = frame.instructionAddress,
                  let value = UInt(address.replacingOccurrences(of: "0x", with: ""), radix: 16),
                  let pointer = UnsafeRawPointer(bitPattern: value) else { return "?" }
            var info = Dl_info()
            if dladdr(pointer, &info) != 0, let symbol = info.dli_sname {
                return String(cString: symbol)
            }
            return address
        }
    }

    private func run(_ scenario: Scenario) throws -> Outcome {
        let dateProvider = TestCurrentDateProvider()
        SentryDependencyContainer.sharedInstance().dateProvider = dateProvider
        let notificationCenter = TestNSNotificationCenterWrapper()
        let dispatchQueue = TestSentryDispatchQueueWrapper()
        let threadWrapper = SentryTestThreadWrapper()
        let displayLink = TestDisplayLinkWrapper(dateProvider: dateProvider)
        let application = TestSentryUIApplication()
        application.unsafeApplicationState = .active
        let appState = SentryThreadsafeApplication(applicationProvider: { application }, notificationCenter: notificationCenter, dispatchQueueWrapper: dispatchQueue)
        // keepDelayedFramesDuration 500 s is what SentryDependencyContainer uses in production.
        let framesTracker = SentryFramesTracker(displayLinkWrapper: displayLink, dateProvider: dateProvider, dispatchQueueWrapper: dispatchQueue, notificationCenter: notificationCenter, delayedFramesTracker: TestDelayedWrapper(keepDelayedFramesDuration: 500, dateProvider: dateProvider))
        framesTracker.start()
        // 10 s of normal 60 Hz frames before the watchdog starts, like getSut() above.
        for _ in 0..<600 {
            displayLink.normalFrame()
        }
        XCTAssertTrue(appState.isApplicationInForeground)
        XCTAssertEqual(appState.applicationState, .active)

        let tracker = SentryANRTracker(helper: SentryANRTrackerV2(
            timeoutInterval: timeoutInterval,
            applicationStateProvider: appState,
            dispatchQueueWrapper: dispatchQueue,
            threadWrapper: threadWrapper,
            framesTracker: framesTracker))

        let outcome = Outcome()
        func tickOf(_ seconds: Double) -> Int { Int((seconds * Self.ticksPerSecond).rounded()) }
        var tick = 0 // simulated time since the watchdog started = tick / 60 s
        let endTick = tickOf(scenario.endAt)
        let noFrameTicks: [ClosedRange<Int>] = scenario.stalls.map {
            (tickOf($0.lastFrameAt) + 1)...(tickOf($0.lastFrameAt + $0.length) - 1)
        }
        var pendingNotifications = scenario.notifications.map { (tick: tickOf($0.at), name: $0.name) }.sorted { $0.tick < $1.tick }
        let suspensions = scenario.suspensions.map { (start: tickOf($0.start), end: tickOf($0.end)) }
        let probeTick = scenario.probeMainThreadAt.map(tickOf)
        let finished = expectation(description: "scenario \(scenario.name) finished")
        let release = DispatchSemaphore(value: 0)
        var isFinished = false
        var rngState: UInt64 = scenario.jitterSeed ?? 0
        func nextJitter() -> Int {
            guard scenario.jitterSeed != nil, scenario.maxJitterTicks > 0 else { return 0 }
            rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((rngState >> 33) % UInt64(scenario.maxJitterTicks + 1))
        }

        let oldDebug = SentrySDKLog.isDebug
        let oldLevel = SentrySDKLog.diagnosticLevel
        let oldOutput = SentrySDKLog.getLogOutput()
        let logOutput = TestLogOutput(logsToConsole: false)
        if scenario.captureLogs {
            SentrySDKLog.setLogOutput(logOutput)
            SentrySDKLogSupport.configure(true, diagnosticLevel: .debug)
        }
        defer {
            if scenario.captureLogs {
                SentrySDKLogSupport.configure(oldDebug, diagnosticLevel: oldLevel)
                SentrySDKLog.setOutput(oldOutput)
            }
        }

        threadWrapper.blockWhenSleeping = {
            if isFinished || tick >= endTick {
                if !isFinished {
                    isFinished = true
                    finished.fulfill()
                }
                release.wait()
                return
            }
            outcome.polls += 1
            var target = tick + Self.ticksPerSleep + nextJitter()
            for suspension in suspensions where tick >= suspension.start && tick < suspension.end {
                target = max(target, suspension.end)
            }
            while tick < target {
                tick += 1
                dateProvider.advance(by: 1.0 / Self.ticksPerSecond)
                while let next = pendingNotifications.first, next.tick <= tick {
                    pendingNotifications.removeFirst()
                    notificationCenter.post(Notification(name: next.name))
                }
                if tick == probeTick {
                    let ran = DispatchSemaphore(value: 0)
                    let start = DispatchTime.now().uptimeNanoseconds
                    DispatchQueue.main.async { ran.signal() }
                    let didRun = ran.wait(timeout: .now() + 2) == .success
                    let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    outcome.mainThreadProbe = (Double(tick) / Self.ticksPerSecond, didRun, latencyMs)
                }
                let framesDelivered = !noFrameTicks.contains { $0.contains(tick) }
                if framesDelivered && displayLink.target != nil {
                    displayLink.call()
                }
            }
        }

        let recorder = Recorder(outcome: outcome, now: { Double(tick) / Self.ticksPerSecond }, onDetected: {
            if scenario.captureMainThreadStackOnDetection && outcome.mainThreadStackAtDetection.isEmpty {
                outcome.mainThreadStackAtDetection = Self.mainThreadStack()
            }
        })
        tracker.add(listener: recorder)

        wait(for: [finished], timeout: 60)
        tracker.clear()
        release.signal()
        wait(for: [threadWrapper.threadFinishedExpectation], timeout: 10)
        if scenario.captureLogs {
            let logged = logOutput.loggedMessages
            for message in Self.watchedLogMessages {
                outcome.logCounts[message] = logged.filter { $0.contains(message) }.count
            }
        }
        log(scenario, outcome)
        return outcome
    }

    // MARK: A - background round trip without a stall (claim i)

    /// willResignActive -> didEnterBackground -> background -> willEnterForeground -> didBecomeActive,
    /// frames delivered whenever the app is active. Several wake-up orders of the watchdog are covered.
    func testIssue106340_A_backgroundRoundTripWithoutStall_reportsNoHang() throws {
        let resign = UIApplication.willResignActiveNotification
        let background = UIApplication.didEnterBackgroundNotification
        let foreground = UIApplication.willEnterForegroundNotification
        let active = UIApplication.didBecomeActiveNotification
        let roundTrip: [(at: Double, name: Notification.Name)] = [(5.0, resign), (5.3, background), (35.0, foreground), (35.1, active)]

        let scenarios = [
            Scenario(name: "A1 suspended 8-35.5 s, watchdog wakes after didBecomeActive with frames running", endAt: 45, notifications: roundTrip, suspensions: [(8.0, 35.5)]),
            Scenario(name: "A2 suspended 8-34.9 s, watchdog wakes still in background", endAt: 45, notifications: roundTrip, suspensions: [(8.0, 34.9)]),
            Scenario(name: "A3 suspended 8-35.05 s, watchdog wakes between willEnterForeground and didBecomeActive", endAt: 45, notifications: roundTrip, suspensions: [(8.0, 35.05)]),
            Scenario(name: "A4 background 30 s without suspension (watchdog keeps polling)", endAt: 45, notifications: roundTrip),
            Scenario(name: "A5 inactive only (resignActive 5.0 s -> didBecomeActive 9.0 s, no background)", endAt: 20, notifications: [(5.0, resign), (9.0, active)])
        ]
        for var scenario in scenarios {
            scenario.captureLogs = true
            let outcome = try run(scenario)
            XCTAssertEqual(outcome.detected.count, 0, "\(scenario.name): unexpected app hang \(outcome.detected)")
            XCTAssertEqual(outcome.stopped.count, 0, "\(scenario.name): unexpected anrStopped \(outcome.messages)")
        }
    }

    // MARK: B - foreground stall around 2.5 s (claim iii)

    func testIssue106340_B_foregroundStall_reportedButNeverBetween2_0And2_8() throws {
        let band = "between 2.0 and 2.8 seconds"

        let primary = Scenario(name: "B frames stopped 2.5 s at t=5.0, app active", endAt: 12, stalls: [Stall(lastFrameAt: 5.0, length: 2.5)])
        let outcome = try run(primary)
        XCTAssertEqual(outcome.detected.map { Self.typeName($0.type) }, ["fullyBlocking"])
        XCTAssertEqual(outcome.stopped.count, 1)
        XCTAssertFalse(outcome.messages.contains(band), "primary: \(outcome.messages)")

        // Sweep: fully-blocking stalls 2.05-4.00 s at four poll phases, plus two-segment stalls
        // (one frame in between, the non-fully-blocking shape), all while the app stays active.
        var histogram: [String: Int] = [:]
        var minElapsed = Double.greatestFiniteMagnitude
        var runs = 0
        var sweep: [Scenario] = []
        for step in 0..<40 {
            let length = 2.05 + Double(step) * 0.05
            for phase in [0.0, 0.1, 0.2, 0.3] {
                sweep.append(Scenario(name: String(format: "B-sweep full %.2f s phase %.1f", length, phase), endAt: 5.0 + phase + length + 4, stalls: [Stall(lastFrameAt: 5.0 + phase, length: length)]))
            }
        }
        for (first, second) in [(0.5, 1.7), (1.0, 1.2), (1.2, 1.0), (1.5, 0.8), (1.0, 1.5), (0.8, 2.0), (1.6, 1.6)] {
            for phase in [0.0, 0.1, 0.2, 0.3] {
                sweep.append(Scenario(name: String(format: "B-sweep split %.1f+%.1f s phase %.1f", first, second, phase), endAt: 5.0 + phase + first + second + 4, stalls: [Stall(lastFrameAt: 5.0 + phase, length: first), Stall(lastFrameAt: 5.0 + phase + first, length: second)]))
            }
        }
        // Jittered polling: every watchdog sleep lasts 0.400-0.600 s (seeded), stall shapes randomised.
        var seed: UInt64 = 106_340
        func nextUnit() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        for index in 0..<320 {
            // First 160 runs: sleeps 0.400-0.600 s. Next 160 runs: sleeps 0.400-1.000 s (heavily loaded device).
            let maxJitter = index < 160 ? 12 : 36
            let phase = (nextUnit() * 0.4 * 60).rounded() / 60
            if index % 2 == 0 {
                let length = ((2.05 + nextUnit() * 1.95) * 60).rounded() / 60
                sweep.append(Scenario(name: String(format: "B-jitter(+%d ticks) #%d full %.3f s phase %.3f", maxJitter, index, length, phase), endAt: 5.0 + phase + length + 5, stalls: [Stall(lastFrameAt: 5.0 + phase, length: length)], jitterSeed: UInt64(index + 1), maxJitterTicks: maxJitter))
            } else {
                let first = ((0.4 + nextUnit() * 1.4) * 60).rounded() / 60
                let second = ((2.1 - first + nextUnit() * 1.0) * 60).rounded() / 60
                sweep.append(Scenario(name: String(format: "B-jitter(+%d ticks) #%d split %.3f+%.3f s phase %.3f", maxJitter, index, first, second, phase), endAt: 5.0 + phase + first + second + 5, stalls: [Stall(lastFrameAt: 5.0 + phase, length: first), Stall(lastFrameAt: 5.0 + phase + first, length: second)], jitterSeed: UInt64(index + 1), maxJitterTicks: maxJitter))
            }
        }
        var notDetected = 0
        for scenario in sweep {
            let result = try run(scenario)
            runs += 1
            if result.detected.isEmpty { notDetected += 1 }
            for (index, stop) in result.stopped.enumerated() {
                let key = "\(result.detected.count > index ? Self.typeName(result.detected[index].type) : "?") \(result.messages[index])"
                histogram[key, default: 0] += 1
                minElapsed = min(minElapsed, (stop.minDuration + stop.maxDuration) / 2 - timeoutInterval)
            }
            XCTAssertFalse(result.messages.contains(band), "\(scenario.name): \(result.messages)")
        }
        print("[T1-106340] B sweep runs=\(runs) (exact 0.4 s polls + jittered 0.4-0.6 s and 0.4-1.0 s polls) not-detected=\(notDetected) min elapsed-since-detection e=\(String(format: "%.3f", minElapsed)) s")
        for (key, count) in histogram.sorted(by: { $0.key < $1.key }) {
            print("[T1-106340] B sweep histogram: \(key) x\(count)")
        }
        XCTAssertEqual(histogram.filter { $0.key.hasSuffix(band) }.count, 0)
    }

    // MARK: C - frames stop while the app stays active and the main thread is idle (claim ii)

    func testIssue106340_C_framesStopWhileActiveAndMainThreadIdle_reportsFullyBlockingHang() throws {
        for length in [3.0, 5.0, 10.0, 16.5] {
            let scenario = Scenario(
                name: String(format: "C frames stopped %.1f s at t=5.0, app active, main thread idle", length),
                endAt: 5.0 + length + 5,
                stalls: [Stall(lastFrameAt: 5.0, length: length)],
                probeMainThreadAt: 5.0 + length - 0.5,
                captureMainThreadStackOnDetection: true)
            let outcome = try run(scenario)

            XCTAssertEqual(outcome.detected.map { Self.typeName($0.type) }, ["fullyBlocking"], scenario.name)
            XCTAssertEqual(outcome.stopped.count, 1, scenario.name)
            let probe = try XCTUnwrap(outcome.mainThreadProbe, scenario.name)
            XCTAssertTrue(probe.ran, "\(scenario.name): main queue did not run a block during the reported hang")
            if let detectedAt = outcome.detected.first?.at {
                XCTAssertGreaterThan(probe.at, detectedAt, "\(scenario.name): probe should run after detection")
            }
            XCTAssertTrue(outcome.mainThreadStackAtDetection.contains { $0.contains("mach_msg") }, "\(scenario.name): \(outcome.mainThreadStackAtDetection)")
            if let stop = outcome.stopped.first {
                XCTAssertGreaterThanOrEqual(stop.minDuration, length - 0.4, scenario.name)
                XCTAssertLessThanOrEqual(stop.maxDuration, length + 1.6, scenario.name)
            }
        }
    }

    // MARK: D - how a "between 2.0 and 2.8 seconds" result can be produced (bears on claim iii)

    /// Same stall as B, but the app resigns active and enters the background right after detection.
    func testIssue106340_D_stallThenBackground_firstPollBandOnlyWithBackgroundSubtraction() throws {
        let resign = UIApplication.willResignActiveNotification
        let background = UIApplication.didEnterBackgroundNotification
        let foreground = UIApplication.willEnterForegroundNotification
        let active = UIApplication.didBecomeActiveNotification
        let stall = [Stall(lastFrameAt: 5.0, length: 2.3)]

        let notSuspended = try run(Scenario(name: "D1 stall 2.3 s, background 7.4-10.05 s (not suspended)", endAt: 15, stalls: stall, notifications: [(7.35, resign), (7.4, background), (10.05, foreground), (10.1, active)], captureLogs: true))
        let suspended = try run(Scenario(name: "D2 stall 2.3 s, background 7.4-13.05 s, suspended 7.6-13.3 s", endAt: 18, stalls: stall, notifications: [(7.35, resign), (7.4, background), (13.05, foreground), (13.1, active)], suspensions: [(7.6, 13.3)], captureLogs: true))
        let inactiveOnly = try run(Scenario(name: "D3 stall 2.3 s, inactive 7.35-10.1 s (no background)", endAt: 15, stalls: stall, notifications: [(7.35, resign), (10.1, active)], captureLogs: true))

        XCTAssertEqual(notSuspended.messages, ["between 2.0 and 2.8 seconds"])
        XCTAssertEqual(suspended.stopped.count, 1)
        XCTAssertEqual(inactiveOnly.stopped.count, 1)
        XCTAssertFalse(inactiveOnly.messages.contains("between 2.0 and 2.8 seconds"))

        // D4/D5: the stall ends 1/60 s before the detecting poll (t=7.2), so the 2 s window holds one
        // rendered frame -> non-fully-blocking. D4 then backgrounds before the next poll; D5 stays active.
        let shortStall = [Stall(lastFrameAt: 5.0, length: 131.0 / 60.0)]
        let endedThenBackground = try run(Scenario(name: "D4 stall ends t=7.183, background 7.3-10.05 s (not suspended)", endAt: 15, stalls: shortStall, notifications: [(7.25, resign), (7.3, background), (10.05, foreground), (10.1, active)], captureLogs: true))
        let endedStayActive = try run(Scenario(name: "D5 stall ends t=7.183, app stays active", endAt: 15, stalls: shortStall))
        XCTAssertEqual(endedThenBackground.detected.map { Self.typeName($0.type) }, ["nonFullyBlocking"])
        XCTAssertEqual(endedThenBackground.messages, ["between 2.0 and 2.8 seconds"])
        XCTAssertEqual(endedStayActive.detected.map { Self.typeName($0.type) }, ["nonFullyBlocking"])
        XCTAssertFalse(endedStayActive.messages.contains("between 2.0 and 2.8 seconds"))
    }

    // MARK: F - how many rendered frames a non-fully-blocking detection allows (bears on claim ii/iii wording)

    /// Back-to-back stalls of equal length with exactly one frame between consecutive stalls (so the
    /// frame spacing equals the stall length), app active throughout. Records which spacings are detected
    /// at all, and as which type. With spacing <= 0.95 s every 2 s window holds >= 2 rendered frames.
    func testIssue106340_F_nonFullyBlocking_requiresAtMostOneFrameInTheWindow() throws {
        var detectedBySpacing: [String: [String]] = [:]
        for segments in [2, 3, 4, 6, 12] {
            for total in [2.4, 3.0, 4.0] {
                let length = ((total / Double(segments)) * 60).rounded() / 60
                let key = String(format: "spacing %.3f s x %d", length, segments)
                for phase in [0.0, 0.1, 0.2, 0.3] {
                    let stalls = (0..<segments).map { Stall(lastFrameAt: 5.0 + phase + Double($0) * length, length: length) }
                    let outcome = try run(Scenario(name: String(format: "F %d stalls x %.3f s (one frame between) phase %.1f", segments, length, phase), endAt: 5.0 + phase + Double(segments) * length + 4, stalls: stalls))
                    detectedBySpacing[key, default: []].append(contentsOf: outcome.detected.map { Self.typeName($0.type) })
                    if length <= 0.95 {
                        XCTAssertEqual(outcome.detected.count, 0, "\(segments) stalls of \(length) s: \(outcome.detected)")
                    }
                }
            }
        }
        for (key, types) in detectedBySpacing.sorted(by: { $0.key < $1.key }) {
            print("[T1-106340] F \(key) (4 phases): detections=\(types.count) types=\(Dictionary(grouping: types, by: { $0 }).mapValues(\.count))")
        }
    }
}
#endif
#endif
