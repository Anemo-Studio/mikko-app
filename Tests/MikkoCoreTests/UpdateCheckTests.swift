import Foundation
import Testing
@testable import MikkoCore

@Test func versionsCompareNumerically() {
    #expect(UpdateCheck.isNewer("v1.10.0", than: "1.9.3"))
    #expect(UpdateCheck.isNewer("1.0.1", than: "1.0"))
    #expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
    #expect(!UpdateCheck.isNewer("v0.9", than: "1.0"))
}

@Test func parsesLatestReleaseAndPicksTheDiskImage() throws {
    let json = """
    {"tag_name":"v1.2.0","html_url":"https://github.com/Anemo-Studio/mikko-app/releases/tag/v1.2.0","draft":false,"prerelease":false,
     "assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/c.txt"},
               {"name":"mikko-1.2.0.dmg","browser_download_url":"https://example.com/mikko-1.2.0.dmg"}]}
    """
    let r = try #require(UpdateCheck.parse(Data(json.utf8)))
    #expect(r.version == "1.2.0")
    #expect(r.downloadURL?.lastPathComponent == "mikko-1.2.0.dmg")
}

@Test func neverOffersPrereleases() {
    let json = #"{"tag_name":"v2.0.0-beta","html_url":"https://github.com/x","prerelease":true,"assets":[]}"#
    #expect(UpdateCheck.parse(Data(json.utf8)) == nil)
}
