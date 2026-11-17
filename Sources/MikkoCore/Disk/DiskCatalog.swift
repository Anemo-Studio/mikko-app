import Foundation

/// Where a category's data lives and how it splits into reviewable items.
public struct DiskLocation: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        /// The directory itself is one item.
        case whole
        /// Each entry `depth` levels below is its own item (1 = direct children).
        case children(depth: Int)
    }
    public var path: String
    public var mode: Mode
    public init(_ path: String, _ mode: Mode = .whole) { self.path = path; self.mode = mode }
}

public struct DiskCategory: Sendable, Identifiable, Hashable {
    public var id: String
    public var group: String
    public var title: String
    public var risk: RiskLevel
    /// P-5: one sentence on what cleaning costs the user.
    public var whatYouLose: String
    public var locations: [DiskLocation]
    /// Bundle IDs / process names that make cleaning unsafe while running (D-3).
    public var blockedBy: [String]

    public init(id: String, group: String, title: String, risk: RiskLevel, whatYouLose: String,
                locations: [DiskLocation], blockedBy: [String] = []) {
        self.id = id; self.group = group; self.title = title; self.risk = risk
        self.whatYouLose = whatYouLose; self.locations = locations; self.blockedBy = blockedBy
    }
}

public enum DiskCatalog {
    public static let agentTempID = "ai.temp"
    /// D-2: known developer-tool locations only — never a general Mac cleaner.
    public static func standard(home: String = NSHomeDirectory(), uid: UInt32 = getuid(),
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [DiskCategory] {
        let lib = "\(home)/Library"
        let caches = "\(lib)/Caches"
        let xcode = "\(lib)/Developer/Xcode"
        let appSup = "\(lib)/Application Support"
        let androidSDK = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "\(lib)/Android/sdk"
        let xcodeApps = ["com.apple.dt.Xcode", "com.apple.iphonesimulator", "xcodebuild", "swift-build", "swift-frontend"]
        let claudeApps = ["com.anthropic.claudefordesktop", "claude"]
        let jetbrains = ["idea", "webstorm", "pycharm", "goland", "rubymine", "phpstorm", "clion", "rider", "datagrip",
                         "studio", "com.google.android.studio"]

        func editorCaches(_ name: String) -> [DiskLocation] {
            ["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                .map { DiskLocation("\(appSup)/\(name)/\($0)") }
        }

        return [
            DiskCategory(id: "xcode.deriveddata", group: "Xcode", title: "DerivedData", risk: .safe,
                         whatYouLose: "Xcode rebuilds from scratch; the first build of each project is slower.",
                         locations: [DiskLocation("\(xcode)/DerivedData", .children(depth: 1))], blockedBy: xcodeApps),
            DiskCategory(id: "xcode.caches", group: "Xcode", title: "Previews, caches and logs", risk: .safe,
                         whatYouLose: "Previews and indexes are regenerated the next time you open Xcode.",
                         locations: [DiskLocation("\(xcode)/UserData/Previews"), DiskLocation("\(caches)/com.apple.dt.Xcode"),
                                     DiskLocation("\(lib)/Logs/CoreSimulator"),
                                     DiskLocation("\(lib)/Developer/CoreSimulator/Caches")],
                         blockedBy: xcodeApps),
            DiskCategory(id: "xcode.devicesupport", group: "Xcode", title: "Device support files", risk: .safe,
                         whatYouLose: "Xcode copies symbols again the next time you connect a device with that OS version.",
                         locations: ["iOS", "watchOS", "tvOS", "visionOS"].map {
                             DiskLocation("\(xcode)/\($0) DeviceSupport", .children(depth: 1))
                         }, blockedBy: xcodeApps),
            DiskCategory(id: "xcode.archives", group: "Xcode", title: "Archives", risk: .caution,
                         whatYouLose: "You can no longer symbolicate crash reports or re-export these builds.",
                         locations: [DiskLocation("\(xcode)/Archives", .children(depth: 2))]),

            DiskCategory(id: "android.gradle", group: "Android", title: "Gradle caches", risk: .safe,
                         whatYouLose: "Gradle downloads dependencies again; the next build is slower.",
                         locations: [DiskLocation("\(home)/.gradle/caches"), DiskLocation("\(home)/.gradle/daemon"),
                                     DiskLocation("\(home)/.gradle/wrapper/dists", .children(depth: 1))],
                         blockedBy: ["GradleDaemon", "gradle", "com.google.android.studio"]),
            DiskCategory(id: "android.images", group: "Android", title: "SDK system images", risk: .caution,
                         whatYouLose: "Emulators using an image stop working until you download it again.",
                         locations: [DiskLocation("\(androidSDK)/system-images", .children(depth: 3))]),

            DiskCategory(id: "node.caches", group: "Node", title: "npm, pnpm, Yarn and Bun caches", risk: .safe,
                         whatYouLose: "Packages are downloaded again on the next install.",
                         locations: [DiskLocation("\(home)/.npm/_cacache"), DiskLocation("\(home)/.npm/_logs"),
                                     DiskLocation("\(lib)/pnpm/store"), DiskLocation("\(caches)/pnpm"),
                                     DiskLocation("\(caches)/Yarn"), DiskLocation("\(home)/.yarn/berry/cache"),
                                     DiskLocation("\(home)/.bun/install/cache")],
                         blockedBy: ["npm", "pnpm", "yarn", "bun"]),
            DiskCategory(id: "node.npx", group: "Node", title: "npx package cache", risk: .caution,
                         whatYouLose: "Tools run with npx are downloaded again. MCP servers started through npx may need a restart.",
                         locations: [DiskLocation("\(home)/.npm/_npx", .children(depth: 1))]),
            DiskCategory(id: "python.caches", group: "Python", title: "pip, uv and Poetry download caches", risk: .safe,
                         whatYouLose: "Packages are downloaded again on the next install.",
                         // Poetry keeps virtualenvs next to its cache — only the cache folders are listed.
                         locations: [DiskLocation("\(caches)/pip"), DiskLocation("\(home)/.cache/uv"),
                                     DiskLocation("\(caches)/pypoetry/cache"), DiskLocation("\(caches)/pypoetry/artifacts")],
                         blockedBy: ["pip", "pip3", "uv", "poetry"]),
            DiskCategory(id: "python.conda", group: "Python", title: "conda package cache", risk: .caution,
                         whatYouLose: "Environments link into this cache, so little space may be freed, and environments installed with soft links can break.",
                         locations: [DiskLocation("\(home)/miniconda3/pkgs"), DiskLocation("\(home)/anaconda3/pkgs"),
                                     DiskLocation("\(home)/miniforge3/pkgs")],
                         blockedBy: ["conda", "mamba"]),
            DiskCategory(id: "lang.caches", group: "Other languages", title: "Cargo, Go, CocoaPods, SwiftPM, Pub and more",
                         risk: .safe, whatYouLose: "Dependencies are downloaded or compiled again on the next build.",
                         locations: [DiskLocation("\(home)/.cargo/registry"), DiskLocation("\(home)/.cargo/git"),
                                     DiskLocation("\(home)/go/pkg/mod"), DiskLocation("\(caches)/go-build"),
                                     DiskLocation("\(caches)/CocoaPods"), DiskLocation("\(caches)/org.swift.swiftpm"),
                                     // Only downloaded packages — not globally activated tools or credentials.
                                     DiskLocation("\(home)/.pub-cache/hosted"), DiskLocation("\(home)/.pub-cache/git"),
                                     DiskLocation("\(caches)/composer"), DiskLocation("\(caches)/deno")],
                         blockedBy: ["cargo", "rustc", "go", "pod", "swift-build", "dart", "flutter", "composer", "deno"]),
            DiskCategory(id: "lang.maven", group: "Other languages", title: "Maven local repository", risk: .caution,
                         whatYouLose: "Downloaded dependencies return on the next build, but artifacts you installed locally or fetched from private repositories may not.",
                         locations: [DiskLocation("\(home)/.m2/repository")], blockedBy: ["mvn", "java"]),
            DiskCategory(id: "homebrew.cache", group: "Homebrew", title: "Download cache", risk: .safe,
                         whatYouLose: "Homebrew downloads bottles again when you reinstall or upgrade.",
                         locations: [DiskLocation("\(caches)/Homebrew")]),
            DiskCategory(id: "browsers.automation", group: "Browser automation", title: "Playwright and Puppeteer browsers",
                         risk: .safe, whatYouLose: "Browsers are downloaded again the next time tests run.",
                         locations: [DiskLocation("\(caches)/ms-playwright", .children(depth: 1)),
                                     DiskLocation("\(home)/.cache/puppeteer", .children(depth: 1))]),
            DiskCategory(id: "editors.caches", group: "Editors", title: "VS Code and Cursor caches", risk: .safe,
                         whatYouLose: "Editors rebuild their caches on next launch.",
                         locations: editorCaches("Code") + editorCaches("Cursor"),
                         blockedBy: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]),
            DiskCategory(id: "editors.jetbrains", group: "Editors", title: "JetBrains IDE caches", risk: .caution,
                         whatYouLose: "Indexes are rebuilt, and each IDE's Local History — its undo record for uncommitted edits — is lost.",
                         locations: [DiskLocation("\(caches)/JetBrains", .children(depth: 1))], blockedBy: jetbrains),

            DiskCategory(id: "ai.caches", group: "AI tools", title: "Agent caches and logs", risk: .safe,
                         whatYouLose: "Caches are rebuilt on next use. Sessions are not touched.",
                         locations: [DiskLocation("\(caches)/claude-cli-nodejs"), DiskLocation("\(lib)/Logs/Claude"),
                                     DiskLocation("\(home)/.claude/debug"), DiskLocation("\(appSup)/Claude/Cache"),
                                     DiskLocation("\(appSup)/Claude/Code Cache")],
                         blockedBy: ["com.anthropic.claudefordesktop"]),
            // One item per past session; sessions that are still running are left out by the scanner.
            DiskCategory(id: DiskCatalog.agentTempID, group: "AI tools", title: "Temporary files of past agent sessions", risk: .caution,
                         whatYouLose: "Scratch files and task output of agent sessions that have ended.",
                         locations: [DiskLocation("/private/tmp/claude-\(uid)", .children(depth: 2))]),
            DiskCategory(id: "ai.vm", group: "AI tools", title: "Claude local VM", risk: .risky,
                         whatYouLose: "The VM image is rebuilt on next use, but session data stored inside the VM is lost for good.",
                         locations: [DiskLocation("\(appSup)/Claude/vm_bundles", .children(depth: 1)),
                                     DiskLocation("\(appSup)/Claude/claude-code-vm", .children(depth: 1))],
                         blockedBy: claudeApps),
            DiskCategory(id: "models.local", group: "Local models", title: "Ollama, LM Studio and Hugging Face models",
                         risk: .caution, whatYouLose: "Each model must be downloaded again — often several GB.",
                         locations: [DiskLocation("\(home)/.ollama/models"),
                                     DiskLocation("\(home)/.lmstudio/models", .children(depth: 2)),
                                     DiskLocation("\(home)/.cache/huggingface/hub", .children(depth: 1))]),
        ]
    }
}
