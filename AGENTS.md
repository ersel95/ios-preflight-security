# AGENTS.md — preflight for LLM agents

Machine-readable usage guide for AI coding agents (Claude Code, Cursor, etc.).

## What this tool is

`preflight` is a **deterministic static analysis CLI** for iOS (Swift) projects.
22 rules covering release-readiness: console logs, force-unwraps, ATS, privacy
manifest, hardcoded secrets, deprecated APIs, retain-cycle risks, sensitive
data on pasteboard, etc.

- **No network, no AI, no LLM calls.** Pure regex/grep + xcodebuild introspection.
- Runs offline. Idempotent. Cache lives at `<repo>/.preflight/`.

## Install (once per machine)

```bash
brew tap ersel95/tap
brew install preflight
```

## Invocation contract

Run from the iOS project root (directory containing `*.xcodeproj`):

```bash
preflight                                    # default = scan, terminal output
preflight scan --strict --json out.json      # CI/agent mode (machine-readable)
preflight dashboard                          # interactive web UI (humans)
preflight doctor                             # dependency check
preflight --help                             # full options
preflight --version                          # → "preflight 0.1.0"
```

### Recommended agent flow

```bash
cd /path/to/ios/project
preflight scan --strict --json /tmp/preflight.json --skip git
echo "exit=$?"
# Parse /tmp/preflight.json → identify findings → fix in code → re-run
```

`--skip git` recommended for agents: the `git` rule reports uncommitted/untracked
state which is noise during agent sessions.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Clean (or only WARN/INFO without `--strict`) — release-ready |
| `1`  | At least one ERROR (or WARN with `--strict`) — release blocked |
| `2`  | CLI usage error (bad flag, missing dir) |

## JSON schema (`--json FILE`)

```jsonc
{
  "meta": {
    "repo": "/abs/path/to/project",
    "src": "AppSourceFolder",         // detected source dir
    "generatedAt": "2026-04-28T15:35:08",
    "strict": false,
    "target": "MyApp",                // null if not specified
    "config": "Release",              // null if not specified
    "activeMacros": ["PROD"],         // Swift compilation conditions for this config
    "totals": { "error": 0, "warn": 3, "info": 1 },
    "verdict": "pass"                 // "pass" | "warn" | "fail"
  },
  "sections": [
    {
      "id": "rule-section-id",                    // stable, lowercase
      "title": "Human-readable section title",
      "findings": [
        {
          "severity": "ERR",                      // "ERR" | "WARN" | "INFO"
          "rule": "print",                        // see rule list below
          "file": "Sources/Foo.swift",            // null for whole-project findings
          "line": 42,                             // null if N/A
          "message": "print() detected outside #if DEBUG"
        }
      ]
    }
  ]
}
```

## Rule IDs (use with `--only` / `--skip`)

```
print, unsafe, todo, http, secrets, mock, ats, env, commented, lint,
plist, config, assets, privacy-manifest, sdk, weak-self, weak-delegate,
pasteboard, sensitive-log, deprecated, hardcoded-string, git
```

Severity per rule documented in repo README.md table.

## Common agent tasks → recipes

### "Is this branch release-ready?"
```bash
preflight scan --strict --json /tmp/p.json --skip git
test "$(jq -r .meta.verdict /tmp/p.json)" = "pass"
```

### "List all ERRORs"
```bash
preflight scan --json /tmp/p.json
jq '.sections[].findings[] | select(.severity=="ERR")' /tmp/p.json
```

### "Fix all `print` violations"
```bash
preflight scan --only print --json /tmp/p.json
jq -r '.sections[].findings[] | select(.severity=="ERR") | "\(.file):\(.line)"' /tmp/p.json
# Then read each file, wrap print(...) calls in #if !PROD ... #endif
preflight scan --only print  # verify
```

### "Check before commit (CI parity)"
```bash
preflight scan --strict
```

## Side effects (what changes on disk)

- Creates `<repo>/.preflight/data.json` (last scan result, for dashboard).
- Creates `<repo>/.preflight/project.json` (xcodebuild introspection cache).
- **Add `.preflight/` to the project's `.gitignore`** if not already there.
- Does NOT modify any source file. `scan` is read-only on the repo source.

## What it will NOT do

- Will not call any external API or LLM.
- Will not auto-fix findings (no AI Fix). Returns diagnostics; agents do the fixing.
- Will not modify `.xcodeproj`, `Info.plist`, or any source file.
- Does not require network beyond `xcodebuild` (which runs locally).

## Environment variables

| Var | Effect |
|-----|--------|
| `PREFLIGHT_REPO_ROOT` | Override repo root (default: `$PWD`). Useful when calling from a wrapper. |
| `PREFLIGHT_PORT` | Dashboard port (default `7474`). |

## Debugging

- `preflight doctor` — verifies python3 / ripgrep / xcodebuild / xed presence.
- Cache stale? `rm -rf <repo>/.preflight && preflight`.
- Dashboard frozen? Server log → terminal stdout where you launched it.

## Versioning

- `preflight --version` returns `preflight X.Y.Z`.
- Releases tagged on https://github.com/ersel95/ios-preflight-security/releases.
- Update: `brew upgrade preflight`.
