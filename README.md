# mikko

One native Mac app that shows everything you and your AI agents started and left on this Mac —
processes, ports, simulators, containers, disk space, sessions and spend — and lets you stop,
clean or find it safely.

## Install

Download the signed, notarized app (ZIP) from [GitHub Releases](https://github.com/Anemo-Studio/mikko-app/releases/latest), or:

```bash
brew install --cask anemo-studio/tap/mikko
```

mikko is free and open source (MIT). It needs macOS 14 or later.

## Build and run

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
scripts/build.sh            # builds mikko.app with the CLI embedded, ad-hoc signed
scripts/release.sh          # Developer ID archive → notarized, stapled ZIP (Xcode account, team ANEMO STUDIJA)
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
.build/release/mikko containers    # containers on every engine and their disk use (read-only)
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

Left for later on purpose: ⌘K quick search (K-3), notifications (K-5) and automatic clean rules (D-6), only if
people ask. Dropped: team view (U-6), the growth chart (D-5), usage alerts and Claude limits as percentages
(Claude Code exposes them only to its status line, and the vendors and free tools already show them).

Known gaps:

- **Running:** containers are listed under Containers, not Running; no "Open in editor" or "Show logs"; a
  daemon that calls `setsid` leaves its process group and cannot be linked back to the tree that started it.
- **Containers:** no logs; VM disk shown for Docker Desktop only, with no compaction action.
- **Disk:** sizes of hard-linked or cloned files are upper bounds; Ollama rows are per model, LM Studio and
  Hugging Face per folder.
- **Sessions:** Cursor sessions have no cost (Cursor keeps spend on its servers) and no resume command; no
  tags (notes only); lines over 8 MB are skipped.
- **Agents:** the CLI and MCP rules are guard-rails, not a security boundary — an agent with a shell can
  still run `kill` itself.

## More from Anemo

- [nokko](https://nokko.dev): projects, time and invoices in plain Markdown, on the [Mac App Store](https://apps.apple.com/app/nokko-plan-track-invoice/id6823214749).
- [kikko](https://kikkonotes.com): private meeting notes, made on your Mac.
- [honmay](https://honmay.app): a teleprompter that keeps your best take.

## License

MIT. See [LICENSE](LICENSE). The name and the 見 mark are Anemo's; forks should use their own.
