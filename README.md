# mikko

One native Mac app that shows everything you and your AI agents started and left on this Mac —
processes, ports, simulators, containers, disk space, sessions and spend — and lets you stop,
clean or find it safely.

## Install

Download the signed, notarized disk image from [GitHub Releases](https://github.com/Anemo-Studio/mikko-app/releases/latest), or:

```bash
brew install --cask anemo-studio/tap/mikko
```

mikko is free and open source (MIT). It needs macOS 14 or later.

## Build and run

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
scripts/build.sh            # builds mikko.app with the CLI embedded, ad-hoc signed
TEAM_ID=… scripts/release.sh  # Developer ID archive → notarized, stapled DMG
open .build/xc/Build/Products/Debug/mikko.app
swift test                  # unit tests (no Xcode project needed)
```

The command-line tool on its own:

```bash
swift build -c release --product mikko
.build/release/mikko status        # everything running, grouped, with memory
.build/release/mikko ports         # who holds which port, and who started it
.build/release/mikko stop 3000     # stop the whole process tree on a port
.build/release/mikko wait 3000     # wait until a port answers
.build/release/mikko disk          # reclaimable space (read-only)
.build/release/mikko sessions      # recent agent sessions with API-equivalent cost
.build/release/mikko mcp           # MCP server for agents (stdio)
```

## Layout

| Path | What |
|---|---|
| `Sources/MikkoCore` | All logic, no UI: `Disk`, `Running`, `Simulators`, `Containers`, `Sessions`, `Agents`, `Store`. Covered by `swift test`. |
| `Sources/mikko` | The CLI and MCP server entry point. |
| `App` | The SwiftUI app: one `@Observable` model per module and its views. |
| `project.yml` | XcodeGen definition of the app and `mikko-cli` targets (the CLI is copied to `Contents/Helpers`). The `.xcodeproj` is generated, not committed. |
| `packaging/homebrew` | The Homebrew cask, published from the `Anemo-Studio/homebrew-tap` repository. |

## Safety rules the code enforces

- Files are moved to the Trash, never deleted, and only if at that moment they are still exactly
  a path the scanner would produce (`DiskCleaner`).
- A process is signalled only if its pid **and start time** still match the row (`ProcessStopper`).
- Stop is undoable for 4 seconds: the signal is sent only when the countdown ends.
- Agents (over MCP) can stop only what they started — never a person's or another agent's
  processes, databases, pinned items or running builds — and can never clean the disk (`MCPServer`, `StopPolicy`).
- Session transcripts are only ever read. Nothing about you or the Mac leaves it. The one network call is an optional
  once-a-day check of GitHub Releases for a newer version (`UpdateCheck`, off in Settings › General).

## Not built yet

From the spec's "later" stage (13.8): ⌘K quick search (K-3), notifications (K-5), growth chart (D-5),
automatic clean rules (D-6), session archive copies (S-6) and team view (U-6). mikko is free, so there is no
licensing; updates are a once-a-day "new version" notice. Developer ID signing and notarization are scripted
(`scripts/release.sh`) and need the Developer ID certificate.

Known gaps inside the built stages:

- **Running:** containers are not listed in Running (only in Containers); no "Open in editor" or "Show logs";
  clicking an agent label does not open its session; no "what to stop first" suggestion; processes that
  double-fork away from their parent are not part of the stopped tree.
- **Simulators:** no per-simulator RAM, no installed-apps list, no "Clear simulator caches".
- **Containers:** tested against a mock engine only (no engine was running during development); no logs;
  VM disk shown for Docker Desktop only, with no compaction action; prune size estimates are approximate.
- **Disk:** agent worktrees are flagged but cannot be removed as a whole; no "60+ days" filter; Ollama is one
  row rather than one per model; sizes of hard-linked or cloned files are upper bounds.
- **Sessions:** Cursor is not indexed; export is one session at a time; no tags (notes only); search matches
  whole words and prefixes, not substrings inside a word; lines over 8 MB are skipped.
- **Usage:** Claude limits are not available as percentages (Claude Code exposes them only to its status line); no alerts when a budget
  or limit is crossed; Haiku 5.5 is priced at its lower tier; a project is identified by folder name.
- **Agents:** the CLI and MCP rules are guard-rails, not a security boundary — an agent with a shell can
  still run `kill` itself.

## More from Anemo

- [nokko](https://nokko.dev): projects, time and invoices in plain Markdown, on the [Mac App Store](https://apps.apple.com/app/nokko-plan-track-invoice/id6823214749).
- [kikko](https://kikkonotes.com): private meeting notes, made on your Mac.
- [honmay](https://honmay.app): a teleprompter that keeps your best take.

## License

MIT. See [LICENSE](LICENSE). The name and the 見 mark are Anemo's; forks should use their own.
