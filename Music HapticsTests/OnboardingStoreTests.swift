import XCTest
@testable import Music_Haptics

final class OnboardingStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OnboardingStore.reset()
    }

    override func tearDown() {
        OnboardingStore.reset()
        super.tearDown()
    }

    func testOnboardingStartsIncomplete() {
        // Keep this assertion independent of test-method scheduling and any
        // persisted defaults left by another test process.
        OnboardingStore.reset()
        XCTAssertFalse(OnboardingStore.isComplete)
    }

    func testMarkCompletePersistsCompletion() {
        OnboardingStore.markComplete()
        XCTAssertTrue(OnboardingStore.isComplete)
    }

    func testFutureVersionDoesNotMakeCurrentFlowAppearComplete() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "onboarding.alpha1.completed")
        defaults.set(OnboardingStore.currentVersion + 1, forKey: "onboarding.alpha1.version")
        XCTAssertFalse(OnboardingStore.isComplete)
    }
}
