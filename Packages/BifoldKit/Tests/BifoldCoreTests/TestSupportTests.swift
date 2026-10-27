import Foundation
import Testing

/// Pomocnicze funkcje testów same nie mogą zawiesić zestawu.
@Suite struct TestSupportTests {
    /// Ciało zablokowane na czymś innym niż FIFO: `finishes` kończy się porażką po ograniczonym czasie.
    @Test func finishesGivesUpWhenBodyBlocksOnSomethingElse() {
        let gate = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        let result = finishes(within: .milliseconds(100), unblocking: "/nieistniejaca-kolejka-bifold", unblockLimit: .milliseconds(300)) {
            gate.wait()
        }
        #expect(!result)
        #expect(ContinuousClock.now - start < .seconds(3))
        gate.signal()
    }
}
