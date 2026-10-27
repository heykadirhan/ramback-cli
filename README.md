# ramback

A command-line tool and MCP server that shows your Mac's dev stack and its RAM, and stops what you don't need.

It finds iOS simulators (Xcode Previews too), Android emulators, Gradle and Kotlin daemons, Xcode helpers, Docker
containers grouped by Compose project, bundlers like Metro, dev servers, tunnels, local databases, and coding agents
(Claude Code, Codex, Cursor Agent, Gemini CLI) with the servers they started. Memory is counted the way Activity
Monitor counts it, and each process belongs to one row, so nothing is counted twice.

Stopping uses each tool's own command: `xcrun simctl shutdown`, `adb emu kill`, `docker stop`, or SIGTERM to the
process tree, then a 5-second wait.

This is the engine of [Ramback](https://ramback.app), a menu bar app for the same job. The app is closed source and
compiles these same sources.

```
$ ramback status
Dev stack 2.5 GB · pressure warning · swap 4.4 GB · scanned in 181 ms

Simulators
  iPhone 17 Pro                        1.8 GB  simulator · started by Xcode · 1 proc · sim:4F1A…
shop
  next dev                             0.7 GB  server · started by Claude Code · 2 proc · server:48213
```

## Install

**Homebrew.** The CLI ships inside the Ramback app, and the cask links it onto your PATH:

```bash
brew install --cask heykadirhan/tap/ramback
```

The CLI and MCP server are free and need no account or license.

**From source.** Needs macOS 14 or later and Swift 6.2 (Xcode 26):

```bash
git clone https://github.com/heykadirhan/ramback-cli
cd ramback-cli
swift build -c release
cp .build/release/ramback /usr/local/bin/
```

`swift test` runs the tests.

## Commands

```
ramback status [--json]          What's running, by project, with RAM, ports and ids
ramback stop <id|port|project>   Stop one row by id or port, or a project's rows
       [--yes] [--force] [--dry-run] [--json]
ramback free <GB>                Stop idle simulators, emulators and daemons until about GB are freed
       [--dry-run] [--json]
ramback mcp                      MCP server over stdio, for coding agents
```

`stop <project>` and `free` leave pinned rows, databases and anything building alone. To stop a pinned row or a
database, pick it by id or port and pass `--yes`. `--force` kills right away instead of waiting.

Exit codes: `0` done, `1` something failed or is still running, `2` nothing matched or nothing to stop,
`3` pinned or a database (pass `--yes`), `64` usage.

Pins are set in the Ramback app; the CLI reads them from its settings. Without the app, nothing is pinned. Every stop
is logged to `~/Library/Application Support/Ramback/activity.jsonl`. Nothing leaves your Mac: the CLI makes no
network requests.

## MCP server

`ramback mcp` speaks MCP over stdio. Agents can use it to check what's running before they boot another simulator,
find a free port before starting a server, and stop their own servers when they're done.

The paths below are for the Homebrew install. If you built from source, use the path you copied the binary to.

**Claude Code:**

```bash
claude mcp add --scope user ramback -- /Applications/Ramback.app/Contents/Helpers/ramback mcp
```

**Cursor:** add this to `~/.cursor/mcp.json`. Any other client that takes an `mcpServers` JSON config works the
same way.

```json
{
  "mcpServers": {
    "ramback": {
      "command": "/Applications/Ramback.app/Contents/Helpers/ramback",
      "args": ["mcp"]
    }
  }
}
```

### Tools

| Tool | What it does |
| --- | --- |
| `list_running` | Everything running, with RAM, ports, project, who started it, whether it's building, and whether the calling agent may stop it (`can_stop`, `why_not`). |
| `stop` | Stops one row by id or port, or a project's rows. |
| `free_memory` | Stops idle simulators, emulators and daemons, biggest first, until about `gb` gigabytes are freed. `dry_run` only lists them. |
| `find_free_port` | The first TCP port from `start` (default 3000) that nothing listens on, over IPv4 and IPv6. |

### What an agent can't do

The server checks these limits itself, whatever the agent was told:

- **Stop a pinned row.** Pins are yours.
- **Stop a database.** Postgres, MySQL, Redis and Mongo stay up.
- **Stop anything mid-build.** A build that's using CPU is left alone.
- **Stop what another agent started.** Ownership goes by process id: the agent on the other end of `ramback mcp`
  may stop only what it started. A server started by an agent Ramback can't identify belongs to no one.
- **Force a stop.** Agents only stop politely. If something is still running after 5 seconds, it's reported and
  left for you.
- **Stop a coding agent.** Agents are listed, never stopped.
- **Touch the disk.** Cleanup isn't part of the MCP server.

## License

MIT
