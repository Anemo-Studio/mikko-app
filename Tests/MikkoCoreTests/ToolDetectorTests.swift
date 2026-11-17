import Foundation
import Testing
@testable import MikkoCore

@Test func detectsOnlyToolsWhosePathsExist() {
    let home = URL(fileURLWithPath: "/Users/t")
    let present: Set<String> = ["/Users/t/.claude/projects", "/opt/homebrew/bin/brew", "/sdk"]
    let d = ToolDetector(home: home, environment: ["ANDROID_HOME": "/sdk"], exists: { present.contains($0) })
    #expect(d.detect() == [.claudeCode, .homebrew, .androidSDK])
}

@Test func diskSpaceIsReadable() {
    let d = DiskSpace.current()
    #expect(d != nil && d!.total > d!.free && d!.free > 0)
}
