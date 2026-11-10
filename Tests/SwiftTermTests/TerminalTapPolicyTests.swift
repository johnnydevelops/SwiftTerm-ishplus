import Testing
@testable import SwiftTerm

struct TerminalTapPolicyTests {
    /// Double and triple taps are multi-clicks for a mouse-tracking application (vim, mc);
    /// local selection uses the long press there instead.
    @Test func multiTapsForwardToMouseTrackingApplications() {
        #expect(TerminalTapPolicy.action(tapCount: 2, hasActiveSelection: false, mouseReportingActive: true) == .forwardClick)
        #expect(TerminalTapPolicy.action(tapCount: 3, hasActiveSelection: false, mouseReportingActive: true) == .forwardClick)
    }

    @Test func multiTapsSelectWithoutMouseReporting() {
        #expect(TerminalTapPolicy.action(tapCount: 2, hasActiveSelection: false, mouseReportingActive: false) == .selectWord)
        #expect(TerminalTapPolicy.action(tapCount: 3, hasActiveSelection: false, mouseReportingActive: false) == .selectLine)
    }

    /// With mouse reporting active, a tap can still clear local selection.
    @Test func singleTapDismissesSelectionUnderMouseReporting() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: true, mouseReportingActive: true) == .dismissSelection)
    }

    @Test func singleTapAfterSelectionCanRouteLocally() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: true, mouseReportingActive: false) == .localSingleTap)
    }

    @Test func tapThatClearsSelectionDoesNotOpenContextMenu() {
        #expect(!TerminalTapPolicy.showsContextMenu(nearCursor: true, clearedSelection: true))
        #expect(TerminalTapPolicy.showsContextMenu(nearCursor: true, clearedSelection: false))
        #expect(!TerminalTapPolicy.showsContextMenu(nearCursor: false, clearedSelection: false))
    }

    /// With nothing selected and reporting on, a single tap forwards the click so the application
    /// stays usable.
    @Test func singleTapForwardsClickWhenReportingAndNoSelection() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: false, mouseReportingActive: true) == .forwardClick)
    }

    /// With nothing selected and no reporting, a single tap is handled locally.
    @Test func singleTapIsLocalWhenNoReportingAndNoSelection() {
        #expect(TerminalTapPolicy.action(tapCount: 1, hasActiveSelection: false, mouseReportingActive: false) == .localSingleTap)
    }
}
