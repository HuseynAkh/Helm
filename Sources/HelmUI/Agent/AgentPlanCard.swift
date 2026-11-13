#if os(macOS)
import Foundation

/// A plan the person approved: its id and the groups they left ticked. Only this file can make one, and only from
/// the card's Apply, so nothing else can approve a plan on the person's behalf.
struct AgentApprovedPlan {
    let planID: UUID
    let ticked: Set<Int>
    fileprivate init(tickedByPerson ticked: Set<Int>, planID: UUID) {
        self.planID = planID; self.ticked = ticked
    }
}
#endif
