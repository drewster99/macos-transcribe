import XCTest

final class TrackSelectionTests: XCTestCase {

    func testDefaultSelectionUsesTheFirstTrack() {
        XCTAssertEqual(TrackSelection.defaultTrack.resolvedIndex(audioTrackCount: 3), 0)
    }

    func testFirstTrackSelectionUsesTheFirstTrack() {
        XCTAssertEqual(TrackSelection.firstTrackExplicitly.resolvedIndex(audioTrackCount: 3), 0)
    }

    func testExplicitIndexResolvesWithinRange() {
        XCTAssertEqual(TrackSelection.index(2).resolvedIndex(audioTrackCount: 3), 2)
    }

    func testIndexPastTheEndDoesNotResolve() {
        // Returning nil rather than clamping lets the caller report the real track count instead of
        // silently transcribing a track the user did not ask for.
        XCTAssertNil(TrackSelection.index(3).resolvedIndex(audioTrackCount: 3))
        XCTAssertNil(TrackSelection.index(99).resolvedIndex(audioTrackCount: 1))
    }

    func testNegativeIndexDoesNotResolve() {
        XCTAssertNil(TrackSelection.index(-1).resolvedIndex(audioTrackCount: 3))
    }

    func testNothingResolvesWhenThereAreNoAudioTracks() {
        XCTAssertNil(TrackSelection.defaultTrack.resolvedIndex(audioTrackCount: 0))
        XCTAssertNil(TrackSelection.firstTrackExplicitly.resolvedIndex(audioTrackCount: 0))
        XCTAssertNil(TrackSelection.index(0).resolvedIndex(audioTrackCount: 0))
    }

    func testOnlyTheImplicitDefaultWarnsAboutSkippedTracks() {
        // Choosing a track explicitly is not something to be warned about; falling back to the
        // first one silently is.
        XCTAssertTrue(TrackSelection.defaultTrack.warnsAboutUnselectedTracks)
        XCTAssertFalse(TrackSelection.firstTrackExplicitly.warnsAboutUnselectedTracks)
        XCTAssertFalse(TrackSelection.index(1).warnsAboutUnselectedTracks)
    }
}
