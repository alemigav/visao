# Visao — Command Center Notes

Plain-language reference for the setup on this machine. Last revised 2026-10-30
(second revision: analysis engine switched from Hopper to Ghidra).
If something looks wrong later, section 11 has exact commands to check each piece.

---

## 1. What this directory is

`/Users/alemigav/Visao` is not a normal app repo. It is the home base for a
reverse-engineering toolchain plus the session that drives it.

```
/Users/alemigav/Visao/
├── .toolchain/          # everything private to this workspace
│   ├── node-v24.22.2-darwin-arm64/   # runtime for REA
│   ├── jdk-25.0.5/                   # Java 25, required by Ghidra 12.2
│   └── ghidra_12.2_PUBLIC/           # the analysis engine (Apache-2.0)
├── rea/                 # REA source checkout, built, 118 MB + 54 MB dist
├── .brain/              # session DB snapshots (last 5, ~13 MB each)
├── .toolchain/lima-home/core/  # the Linux nanocore VM (3 GB)
└── README.md            # this file
```

`/Users/alemigav/projects/` is the "other projects" root the agent may write to
without prompting.

---

## 2. The three commands you actually type

| Command | What happens |
|---|---|
| `visao` | Opens the **brain** session (pinned command center) in `/Users/alemigav/Visao` |
| `proj <path>` | Opens the most recent session in that project |
| `proj <path> run "task"` | Headless run in that project, result printed in your terminal |
| `rea <args>` | Runs the REA reverse-engineering CLI from any directory |

All three are shell scripts in `/Users/alemigav/.local/bin/`:

`visao` — the **command-center dashboard**. Typing it renders a live status header and
a menu; picking `1` (or just Enter) opens the pinned brain session, and when that
session exits you land back on the dashboard rather than at a bare shell prompt.

```
VISÃO · command center
──────────────────────────────────────────────────────────
 brain     ses_ffe5e723f1db8ffeKLXcfJU7Fw
 host      rea 6.8.0 · Ghidra 12.2 · macOS
 nanocore  ● up · rea-linux :7391
──────────────────────────────────────────────────────────
 [1] Open brain session  (default)     [5] Tool inventory
 [2] Health report                     [6] Setup notes  (README)
 [3] Engine status (Ghidra)            [7] Closed-work ledger
 [4] Enter nanocore  (Linux shell)     [q] Quit
```

Status is gathered with cheap probes only (`nc` on the port, a `sed` on
`package.json`) so the menu appears instantly.

Under the hood it also: snapshots the session DB at most once a day (atomic
`sqlite3 .backup`, ~45 ms, newest 5 in `.brain/`), and **retries up to 3×** when mimo
dies within 20 s of starting (the stale-worker race in §10).

Non-interactive callers — scripts, `launchd`, anything without a TTY — skip the menu
and go straight into the session, so automation is unaffected.

`visao-doctor` prints the same health data as a one-shot report: entry points, brain
session presence, DB integrity, snapshots, workers, and a **port probe** for
`rea-linux`.

**Never make this probe an MCP call.** An earlier version of `visao-doctor` sent a
real `initialize` to `127.0.0.1:7391` to check reachability — which silently *evicted
the agent's own session* (REA's HTTP transport holds one session). It now uses
`nc -z 127.0.0.1 7391`. Any future health check must do the same, or run only while
no client is attached.

`proj` — launcher for everything else:
```sh
#!/bin/sh
if [ -z "$1" ]; then printf 'usage: proj <path> [mimo args...]\n' >&2; exit 2; fi
target="$1"; shift
cd "$target" || exit 1
if [ $# -eq 0 ]; then set -- --continue; fi
exec /Users/alemigav/.mimocode/bin/mimo "$@"
```

`rea` — pinned interpreter **and** pinned analysis engine:
```sh
#!/bin/sh
export JAVA_HOME=/Users/alemigav/Visao/.toolchain/jdk-25.0.5/Contents/Home
export GHIDRA_INSTALL_DIR=/Users/alemigav/Visao/.toolchain/ghidra_12.2_PUBLIC
export REA_ANALYSIS_PROVIDER=ghidra
exec /Users/alemigav/Visao/.toolchain/node-v24.22.2-darwin-arm64/bin/node \
  /Users/alemigav/Visao/rea/scripts/rea.mjs "$@"
```

`REA_ANALYSIS_PROVIDER=ghidra` is not decoration: it forces provider selection so
`auto` can never pick Hopper (see section 4).

Two details that look arbitrary otherwise:

- **`mimo` is called by absolute path.** `~/.mimocode/bin` reaches `PATH` via
  `~/.zshrc`, which only runs for *interactive* shells. Scripts, subagents and MCP
  launches never see it, so the wrappers hardcode `/Users/alemigav/.mimocode/bin/mimo`.
- **`~/.local/bin` is exported from `~/.zshenv`, not `.zshrc`,** for the same reason.

---

## 3. Why there is a private toolchain instead of installed software

Three separate reasons, all resolved the same way — everything lives in
`/Users/alemigav/Visao/.toolchain/` so it is removable with `rm -rf` and cannot
break other tools on the machine.

**Node v24.22.2** — the machine default is v25.5.0, which REA refuses:
`rea/.npmrc` sets `engine-strict=true`, `package.json#engines.node` allows
`^22.23.4 || ^24.22.1 || >=26.12.1`, and v25.5.0 is in none of those ranges.
(`/usr/local/bin/node` is v22.15.0 — also too old.)

**Temurin JDK 25** — Ghidra 12.2 requires Java 25; its `application.properties`
says `application.java.min=25`. The machine had only **Java 1.8**, which is
useless for modern Ghidra. Installed from Adoptium, checksum-verified.

**Ghidra 12.2** — the open-source analysis engine (section 4).

---

## 4. The analysis engine: Ghidra 12.2 (open-source only)

**Why not Hopper.** Hopper is what REA auto-detects on this machine, and it was
evaluated first. Two independent reasons it is out:

1. **Licensing.** Hopper is commercial software. The project rule is that every
   analysis engine must be fully open-source; Hopper violates it.
2. **It did not work.** REA launched Hopper (the process came up, `ExternalAPI.xpc`
   loaded) but REA's bridge script never loaded, so `open_binary` timed out after
   120 s at `stage: launch` with `provider_state: not_started`. Every subsequent
   operation returned `ProviderAdapterError`. `close_binary` also failed
   (`cleanup_incomplete`), retaining the document and `/private/tmp/rea-*`. Root
   cause, per REA's own docs: an unanswered Hopper demo/license dialog. Nothing
   bypasses it — no timeout setting, no CLI flag.

Hopper is still installed on the machine but is **neutered at the OS level**: the
execute bit was removed from all three binaries in
`~/Applications/Hopper Disassembler.app/Contents/MacOS/` (`hopper`,
`Hopper Disassembler`, `HopperMCPServer`). The kernel refuses to exec them, so the
app cannot launch and REA reports the provider as `missing_analysis_engine`.
Files remain readable and intact — nothing was deleted or modified in content.

Restore it (only if you ever change your mind):
```sh
chmod +x "/Users/alemigav/Applications/Hopper Disassembler.app/Contents/MacOS/"*
```
Re-apply the `chmod a-x` after any Hopper update or reinstall, since that can
restore the execute bit.

**Sanctioned engines:**

| Engine | License | Role |
|---|---|---|
| **Ghidra 12.2** | Apache-2.0 | Installed deep provider: decompiler, CFG, xrefs, data types, byte search, load-image verification |
| Kuna `Noelo-Lab/kuna` | Apache-2.0 | Acceptable lighter alternative: one binary, decompiler only |
| rizin / Cutter | LGPL-3.0 / GPL-3.0 | Command-level passthrough (`execute_rizin_command`) |
| binutils `objdump` | GPL-3.0 | Quick read-only disassembly (`inspect_with_objdump`) |

Never configure Hopper, IDA, or JEB — even though Hopper is present.

### The decompiler binary is hand-built, and you will have to rebuild it

**Ghidra 12.2 PUBLIC ships native decompiler binaries for `linux_x86_64` and
`win_x86_64` only. There is no macOS binary.** Without one, REA reports
`config_drift: Matching native decompiler for darwin/arm64 was not found` and
decompilation fails (analysis still works).

It was compiled from Ghidra's bundled C++ source with clang. The bundled Makefile
is stale — it hardcodes `-arch x86_64` and `mac_x86_64`, and a source comment
admits arm64 is unsupported — so the variables must be overridden:

```sh
cd /Users/alemigav/Visao/.toolchain/ghidra_12.2_PUBLIC/Ghidra/Features/Decompiler/src/decompile/cpp
make OS=Darwin ARCH_TYPE="" OSDIR=mac_arm_64 CXX="clang++ -std=c++11" ADDITIONAL_FLAGS="-w" -j8 ghidra_opt
cp ghidra_opt ../../os/mac_arm_64/decompile
chmod +x ../../os/mac_arm_64/decompile
```

`ADDITIONAL_FLAGS="-w"` matters: the Makefile's own `-mmacosx-version-min=10.6`
is invalid for arm64. Takes a few minutes. **Repeat this after any Ghidra upgrade.**

### Universal binaries must be thinned

Both Ghidra and Kuna refuse FAT Mach-O: *"cannot enforce the selected architecture
when importing a universal Mach-O; analyze a thinned Mach-O slice instead."*

```sh
lipo -thin arm64e /usr/bin/true -output /tmp/true-arm64e
rea analyze /tmp/true-arm64e --provider ghidra
```

This is a real capability Hopper had and the open-source stack does not.

### What Ghidra cannot do on this host

Ghidra is fine with thinned slices. It cannot read FAT containers directly, and
some REA operations are Linux-only regardless of engine (firmware `binwalk`/
`unblob`, pwntools layout inspection, EVM, sigrok, `adb`, `apktool`).

---

## 5. REA — what it is and how it was built

**REA = Reverse Engineer Anything** (`morluto/rea`, MIT, https://rea.tools). An
agent/MCP toolkit that orchestrates real engines behind 233 MCP tools. It is not
itself a decompiler.

- Checkout `/Users/alemigav/Visao/rea`, version **6.8.0**, commit `675d407`, shallow clone
- 5 submodules: `binwalk`, `ghidra-nativeaot`, `jadx-headless-mcp`, `unblob`, `wakaru`
- Build: `npm ci` (730 packages) → `npm run build:cached` (~6 s, turbo runs
  `metadata:check`, `compile`, `artifacts:skills`); output `rea/dist/` 54 MB

Rebuild after source changes:
```sh
cd /Users/alemigav/Visao/rea
PATH="/Users/alemigav/Visao/.toolchain/node-v24.22.2-darwin-arm64/bin:$PATH" npm run build:cached
```

Harmless noise: `npm ci` warns that install scripts for `esbuild@0.28.2`,
`esbuild@0.25.12`, `fsevents@2.3.3` were blocked by `allowScripts`, and reports
1 moderate advisory. The build still passes 3/3.

---

## 6. The "brain" session

- Session ID `ses_ffe5e723f1db8ffeKLXcfJU7Fw`, title "Turning On the Assistant"
- Project `/Users/alemigav/Visao`, entry point the `visao` command

**Why pinned instead of "resume latest":** `--continue` means "most recent session
in this project" — any new session started here would silently take over and
`visao` would open the wrong thing.

**There is no "save" command and you do not need one.** MiMoCode continuously writes:

```
~/.local/share/mimocode/memory/sessions/ses_ffe5e723f1db8ffeKLXcfJU7Fw/
├── checkpoint.md   # structured state: intent, task tree, decisions, files
└── notes.md        # free-form scratch notes
```

On resume, that plus the project `MEMORY.md` is rebuilt into context. The only
thing to get right is *which* session you open.

| In-TUI command | Effect |
|---|---|
| `/sessions` (aka `/resume`, `/continue`) | Pick any session |
| `/new` | Fresh session in this project |
| `/rebuild` | Re-derive context from the latest checkpoint |

Project knowledge lives in
`~/.local/share/mimocode/memory/projects/global/MEMORY.md` — including the rule that
`visao` must land on the brain session and the no-proprietary-engines rule.

**Honest limit:** a TUI session occupies one terminal. Switching to a sub-project
parks the brain — state intact, not watching. Concurrency comes from background
subagents and headless `proj <path> run "..."`.

---

## 7. How MiMoCode gets REA's tools (MCP)

Global config `~/.config/mimocode/mimocode.jsonc`:

```jsonc
{
  "$schema": "https://mimo.xiaomi.com/mimocode/config.json",
  "mcp": {
    "rea": {
      "type": "local",
      "command": [
        "/Users/alemigav/Visao/.toolchain/node-v24.22.2-darwin-arm64/bin/node",
        "/Users/alemigav/Visao/rea/scripts/rea.mjs",
        "mcp"
      ],
      "environment": {
        "GHIDRA_INSTALL_DIR": "/Users/alemigav/Visao/.toolchain/ghidra_12.2_PUBLIC",
        "JAVA_HOME": "/Users/alemigav/Visao/.toolchain/jdk-25.0.5/Contents/Home",
        "REA_ANALYSIS_PROVIDER": "ghidra"
      },
      "timeout": 600000
    }
  }
}
```

Points to understand:

- **`timeout: 600000` (10 min)** is deliberate. MiMoCode defaults to **5000 ms**;
  Ghidra analysis takes seconds to minutes.
- **The command is the local checkout**, not `npx rea-agents` (an npx cache path can
  vanish).
- **MCP servers only load when `mimo` starts.** Config edits never affect a running
  session — restart `mimo`.
- **`mimo mcp list`** shows what is registered and its source. MiMoCode also imports
  Claude Code's servers from `~/.claude.json` (`claude:` label); our native entry is
  `opencode:` and wins by name.
- `mimo mcp add` takes no flags and is interactive; editing the file is scriptable.
- REA is also registered with Claude Code, Claude Desktop, Cursor and VS Code by
  `rea setup`. **Those registrations do not carry the Ghidra environment** — they
  predate the switch and still auto-detect Hopper. Either re-run `rea setup` with
  the new env or ignore them and use MiMoCode.

---

## 8. Permissions — what the agent may touch without asking

```jsonc
"permission": {
  "external_directory": {
    "*": "ask",
    "/Users/alemigav/projects/**": "allow"
  }
}
```

Under `/Users/alemigav/projects/` access is open; `/Users/alemigav/Visao` is the
project directory and always open; **everything else prompts**, including `/tmp`
and the rest of your home directory.

**Critical editing detail:** rules are evaluated in insertion order and **the last
matching rule wins**. That is why `"*": "ask"` is written first. A catch-all placed
last silently overrides every rule above it and the `allow` becomes dead code.

Values are `allow`, `ask`, `deny`. Permissions cannot be overridden by plugins.

`~/projects/` did not exist before this setup and was created empty. Repoint the
glob if your real projects live elsewhere.

---

## 9. Every file this setup touched

Configuration:

| Path | Change |
|---|---|
| `~/.config/mimocode/mimocode.jsonc` | REA MCP server (Ghidra env) + `external_directory` roots |
| `~/.zshenv` | adds `~/.local/bin` to `PATH` (created) |
| `~/.zshrc` | unchanged — still only adds `~/.mimocode/bin` |
| `~/.claude.json` | `rea` MCP entry (backup `~/.claude.json.rea.backup`) |
| `~/Library/Application Support/Claude/claude_desktop_config.json` | `rea` entry (backup `….json.rea.backup`) |
| `~/.cursor/mcp.json` | `rea` entry (new file) |
| `~/Library/Application Support/Code/User/mcp.json` | `rea` entry (new file) |
| `~/.claude/skills/reverse-engineer-anything/` | REA's agent skill |

Created:

| Path | Purpose | Size |
|---|---|---|
| `~/.local/bin/visao` | opens the brain session | — |
| `~/.local/bin/proj` | opens another project | — |
| `~/.local/bin/rea` | REA CLI with pinned Node + Ghidra env | — |
| `/Users/alemigav/Visao/.toolchain/node-v24.22.2-darwin-arm64/` | Node for REA | ~90 MB |
| `/Users/alemigav/Visao/.toolchain/jdk-25.0.5/` | Java 25 for Ghidra | ~350 MB |
| `/Users/alemigav/Visao/.toolchain/ghidra_12.2_PUBLIC/` | analysis engine | ~1.5 GB |
| `…/Ghidra/Features/Decompiler/os/mac_arm_64/decompile` | **hand-compiled** decompiler | 3.2 MB |
| `/Users/alemigav/Visao/rea/` | REA checkout + build | ~172 MB |
| `/Users/alemigav/projects/` | pre-authorized projects root | empty |

---

## 10. Gotchas that will bite you

1. **`visao` opens a session, not a project.** For a clean slate use `/new` inside it.
2. **Hopper is disabled on disk, not just in config.** Its binaries have no execute
   bit, so any tool that ignores `REA_ANALYSIS_PROVIDER` still cannot launch it. If
   you ever `chmod +x` it back, remember `auto` selection would then see it again.
3. **Rebuilding Ghidra or upgrading it deletes the macOS decompiler.** Recompile
   (section 4) or pseudocode silently stops working while analysis still succeeds.
4. **Universal binaries fail** until thinned with `lipo -thin`.
5. **MCP config changes need a `mimo` restart.** No exceptions.
6. **This macOS host has no `timeout`/`gtimeout` binary.** Scripts assuming otherwise
   exit 127 with no output. Bound processes with an in-process timer.
7. **Node v25.5.0 is the default and REA rejects it.** The `rea` wrapper handles it.
8. **Claude Desktop rewrites its own config from memory** — quit it before any tool
   edits that file.
9. **`--continue` follows the newest session.** Only `visao`'s explicit `--session`
   pin is stable; `proj` uses `--continue` on purpose.
10. **Shallow clone.** `git log` in `rea/` shows one commit.
11. **A failed Hopper attempt leaves debris**: `/private/tmp/rea-*` plus a stuck
    document. Quit Hopper, remove the temp dir, restart `mimo`.
12. **`~/.local/bin` must stay on `PATH`** — exported only from `~/.zshenv`.
13. **The "`visao` did nothing" race.** mimo runs a *main* (TUI) process and a *worker*
    (server) process. When it starts while the previous worker is still shutting
    down, the new main waits only **5 seconds** for the handshake and then aborts with
    `service=server-proxy error=Operation timed out after 5000ms ... worker shutdown
    failed`. This is not corruption — retrying a few seconds later works, which is why
    typing any unrelated command first "fixed" it once. The launcher now retries
    automatically. If it still fails after 3 attempts, run `visao-doctor`.
14. **Recovering from a damaged database.** Snapshots live in
    `/Users/alemigav/Visao/.brain/mimocode-*.db` (atomic `sqlite3 .backup`, taken on
    launch at most once a day, newest 5 kept). To restore: quit mimo, then
    `cp .brain/mimocode-<stamp>.db ~/.local/share/mimocode/mimocode.db` and delete the
    stale `mimocode.db-wal` / `mimocode.db-shm`. Nothing else on the machine depends on
    that file.

---

## 11. Verifying it still works

```sh
# wrappers exist and are executable
command -v rea visao proj

# one-shot health report: entry points, brain session, DB integrity, snapshots
visao-doctor

# REA CLI + engine identity (expect 6.8.0)
rea --version

# The important one: Ghidra readiness incl. the compiled decompiler.
# Expect healthy: true and every ghidra-* check ok.
rea doctor --provider ghidra

# Java the engine will use
"$JAVA_HOME/bin/java" -version

# What MiMoCode has registered (expect: rea, connected)
mimo mcp list

# Resolved MiMoCode config incl. permissions
mimo debug config

# Brain session still exists
mimo session list
```

End-to-end analysis check (headless, no GUI):

```sh
lipo -thin arm64e /usr/bin/true -output /tmp/true-arm64e
rea analyze /tmp/true-arm64e --provider ghidra
rea decompile /tmp/true-arm64e 0x100000368 --provider ghidra   # -> return 0
```

After a restart, inside the brain session REA appears as `rea_*` MCP tools. If a
tool search finds none, the MCP config was not loaded — restart `mimo`.

---

## 12. Undoing things

```sh
# launchers
rm ~/.local/bin/visao ~/.local/bin/proj ~/.local/bin/rea

# engines and runtimes (each is independent)
rm -rf /Users/alemigav/Visao/.toolchain/ghidra_12.2_PUBLIC
rm -rf /Users/alemigav/Visao/.toolchain/jdk-25.0.5
rm -rf /Users/alemigav/Visao/.toolchain/node-v24.22.2-darwin-arm64

# REA itself
rm -rf /Users/alemigav/Visao/rea
#   then delete the "rea" block from ~/.config/mimocode/mimocode.jsonc

# restore agent configs rea setup edited
cp ~/.claude.json.rea.backup ~/.claude.json
cp "$HOME/Library/Application Support/Claude/claude_desktop_config.json.rea.backup" \
   "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
rm ~/.cursor/mcp.json "$HOME/Library/Application Support/Code/User/mcp.json"
```

Deleting the brain session is not recommended — it holds this project's context.
To start over anyway: `mimo session delete ses_ffe5e723f1db8ffeKLXcfJU7Fw`.

---

## 13. Where the deeper documentation lives

- MiMoCode docs (bundled, matches the installed version):
  `~/.local/share/mimocode/builtin_skills/0.1.16/skills/mimocode-docs/reference/`
  — `commands.md`, `config.md`, `permissions.md`, `guide.md`, `providers.md`
- MiMoCode config schema: https://mimo.xiaomi.com/mimocode/config.json
- REA docs: `/Users/alemigav/Visao/rea/docs/` — `installation.md` (Hopper/Ghidra
  startup sections), `ghidra-provider.md`, `kuna-provider.md`, `cli.md`
- Agent memory: `~/.local/share/mimocode/memory/projects/global/MEMORY.md`
- **House-hacking playbook**: `/Users/alemigav/Visao/PLAYBOOK.md` — inventory via mDNS,
  traffic attribution, firmware acquisition and extraction, UART/SPI/JTAG with the exact
  commands, radios, app/daemon analysis, shopping list, and a first-night checklist that
  needs no hardware.
- **Operating protocol**: `/Users/alemigav/Visao/PROTOCOL.md` — how the brain keeps a
  long-lived context: the three tiers, the drop gate (verified + documented + not
  load-bearing), thresholds (consolidate at 50 %, hand off at 65 %, rebuild at 85 %),
  the close-out ritual, and a **closed-work ledger** listing every finished endeavour
  with a pointer and a "do not redo" note. Say **"scratch"** or **"consolidate"** to
  have it run.

---

## 14. The Linux nanocore (Lima VM)

REA refuses several capabilities on macOS by design — it needs `prlimit` memory
ceilings or `/proc` descriptor readback, neither of which macOS provides. Those
tools therefore live in a small Linux VM.

**Engine**: Lima v2.2.1 (Apache-2.0, CNCF), installed from its release tarball into
`.toolchain/lima/` (not Homebrew). The VM uses Apple's Virtualization.framework
(`vz`), boots in ~10 s, and needs no GUI.

| Property | Value |
|---|---|
| Instance | `core` |
| Guest | Debian 13 (trixie) arm64, kernel 6.12 |
| Resources | 4 CPU · 4 GiB RAM · 10 GiB disk (2.4 GB used) |
| Instance dir | `.toolchain/lima-home/core` (~3 GB) |
| Download cache | `~/Library/Caches/lima` (~1.7 GB, safe to delete while stopped) |

### Commands

`limactl` is a wrapper that pins `LIMA_HOME` into the toolchain; `nanocore` enters
the VM or runs one command in it.

```sh
nanocore                          # interactive shell
nanocore bash -c 'tshark -v'      # run a command (argv is passed raw — no shell
                                  #   metacharacters unless you add bash -c)
limactl list                      # instance status
limactl stop core                 # shut down (frees 4 GiB RAM)
limactl start core                # boot again
```

**Gotcha**: the guest shell starts in your **host** working directory, which is a
read-only mount. Tools that write to the cwd (unblob writes `unblob.log`) fail with
`Read-only file system`. `cd /tmp` first. The flip side is useful: the guest can read
`/Users/alemigav/...` at the same paths, so samples need no copying in.

### What is installed and verified

| Tool | Version | Verified by |
|---|---|---|
| `tshark` | 4.4.19 | 3,055 protocols + 261,569 fields parsed |
| `sigrok-cli` | **0.7.2** | drivers and decoders enumerated |
| `prlimit` | util-linux 2.41.5 | the exact primitive REA requires |
| `unblob` | **26.6.4** | identified `SQUASHFS_V4_LE` at offset 4096 in a synthetic firmware (100 % chunk ID); extracted a gzip payload correctly |
| `pwntools` | **4.15.0** | parsed `/bin/ls` → aarch64, 64-bit, PIE, 378 symbols, 115 PLT |
| 7-Zip, lz4, zstd, lzop, debugfs, partclone, erofs, simg2img, jefferson, ubi_reader | — | 13 of unblob's 15 extractors present |

Python tools: `unblob` via pipx (`~/.local/bin/unblob`), `pwntools` in the venv
`~/venv-pwntools`. Both pinned to the versions REA documents.

### Known gaps

- **`sasquatch` / `sasquatch-v4be`** are not packaged for Debian and are not built, so
  *unblob* cannot extract squashfs. Workaround that works today:
  `unsquashfs -d out payload.squashfs` (squashfs-tools is installed). Building
  sasquatch from source is the permanent fix.
- **`unar`** (RAR) absent.
- **binwalk 3.1.0** publishes no binaries — it would have to be built with
  `cargo install`. Not required: REA accepts unblob for firmware extraction.
- **Mode A only for REA-orchestrated analysis of native targets.** On macOS REA still
  reports `unsupported_host` for target-bound families; the VM is commanded directly.

### Mode B — a second REA inside the VM (built)

A full REA build lives in the VM and serves MCP over HTTP, so the Linux-only tools
appear as first-class tools in MiMoCode instead of shell commands.

| Piece | Value |
|---|---|
| Source | `~/rea` in the guest (copied from the host checkout, minus `node_modules`) |
| Node | `/opt/node24/bin/node` v24.22.2 (Linux arm64) |
| Service | systemd `rea-mcp.service`, enabled, `Restart=always` |
| Families | `REA_MCP_TOOL_FAMILIES=firmware,pcap,artifact,native` → **59 tools** |
| Bind | `MCP_HOST=127.0.0.1` `MCP_PORT=7391` (fixed; `--port` / `MCP_PORT` otherwise ephemeral) |
| Host entry | `http://127.0.0.1:7391/mcp`, registered in MiMoCode as remote server **`rea-linux`** |

Lima auto-forwards guest listeners to host loopback, so no `portForwards` stanza was
needed.

**REA's HTTP transport holds ONE session at a time.** Opening a second MCP session —
even a throwaway `curl` probe — logs `MCP HTTP session replaced by a new client` and
evicts whoever held the slot. MiMoCode's client then fails with
`-32001 "Session not found"` on every call and only recovers on a `mimo` restart.

Consequences:

- **Never probe `rea-linux` with ad-hoc `curl initialize` calls while MiMoCode is
  attached** — it silently kicks the agent off the server. Verify through the in-session
  `rea-linux_*` tools instead; if a fix must be proven server-side without the client,
  expect to restart `mimo` afterwards.
- The same symptom has two causes: a `systemctl restart rea-mcp` (`-32000 "Server not
  initialized"`) and a stray session stealing the slot (`-32001 "Session not found"`).
- Server-side evidence for this lives in `journalctl -u rea-mcp`, which logs both the
  replacement and the rejected requests. Tool names are **not** prefixed by REA; MiMoCode prefixes by server name, so
host tools stay `rea_*` and VM tools arrive as `rea-linux_*` — no collision.

```sh
limactl start core                       # VM must be running for rea-linux to answer
nanocore systemctl status rea-mcp        # service health
nanocore sudo journalctl -u rea-mcp -n 20   # why it failed
```

Gotchas found while building it:

- systemd `User=` is **`alemigav`**, not `alemigav.guest` (that is only the *home*
  path). Wrong value fails with `status=217/USER`.
- `pkill -f "rea.mjs mcp"` matches the very shell running it and kills itself; use
  `sudo fuser -k <port>/tcp` instead.
- The `native` family also advertises macOS-only operations (`inspect_macho`,
  `inspect_plist`, …) on the Linux server. They will error if called there — use the
  host `rea_*` tools for those. The Linux server exists for `extract_firmware`,
  `inspect_firmware_regions`, the `pcap` set, `inspect_binary_layout`,
  `inspect_recorded_crash`, and `decode_signal_recording`.
#### Required environment for the in-VM REA (learned the hard way)

REA **never searches `PATH`** for these tools — it demands absolute command paths, and
its own child processes (unblob's extractors) need a usable `PATH` too. The systemd
unit must therefore carry:

```ini
Environment=PATH=/home/alemigav.guest/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
Environment=REA_UNBLOB_COMMAND=/home/alemigav.guest/.local/bin/unblob
Environment=REA_TSHARK_COMMAND=/usr/bin/tshark
Environment=REA_TSHARK_PRLIMIT_COMMAND=/usr/bin/prlimit
Environment=REA_CAPINFOS_COMMAND=/usr/bin/capinfos
Environment=REA_SIGROK_COMMAND=/usr/bin/sigrok-cli
Environment=REA_SIGROK_PRLIMIT_COMMAND=/usr/bin/prlimit
Environment=REA_PWNTOOLS_PYTHON=/home/alemigav.guest/venv-pwntools/bin/python
```

Without `REA_UNBLOB_COMMAND`, `extract_firmware` fails with
`capability_unavailable: … requires Linux and an absolute REA_UNBLOB_COMMAND path`
even though unblob is installed and on an interactive shell's `PATH`.

**Editing the unit without breaking the session**: `systemctl restart rea-mcp`
invalidates MiMoCode's live MCP connection (`Bad Request: Server not initialized`).
Prefer `systemctl daemon-reload` **without** restarting — the running process keeps
its old environment and the new unit applies at the next start (VM boot, LaunchAgent
kickstart, or an intentional restart). `systemctl show -p MainPID -p NRestarts` proves
nothing was disturbed.

#### Verified through MCP (not just the CLI)

`extract_firmware` on a synthetic 8 KB firmware (squashfs at offset 4096) returned
provider `unblob 26.6.4` and published:

```
out/firmware.bin_extract/0-4096.padding
out/firmware.bin_extract/4096-8192.squashfs_v4_le_extract/hello.txt   → HELLO FROM FIRMWARE
out/firmware.bin_extract/4096-8192.squashfs_v4_le_extract/config.cfg  → secret=42
```

`inspect_pcap_client` reports `TShark (Wireshark) 4.4.19` — the pcap family is wired.

`sigrok` is wired too: `inspect_signal_decoders` found `uart` among 111 decoders and
reported the full stack (libsigrok 0.5.2, libsigrokdecode 0.5.3, Python 3.13.1), and
`decode_signal_recording` on a synthetic 9600-8N1 UART recording returned

```
1041660-1145827 uart-1: Start bit
1145827-1249994 uart-1: 1 … 1874994-1979161 uart-1: 0   (8 data bits, LSB first)
1145827-1979161 uart-1: 41                              (byte)
1979160-2083327 uart-1: Stop bit
```

matching the byte encoded into the waveform (`0x41` = `'A'`). Annotations keep raw
sample-number ranges and are explicitly *not* parsed into a byte stream.

#### sigrok/VCD gotchas (cost real debugging time)

- **sigrok's VCD importer ignores `$dumpvars`.** It treats the first *timestamped*
  transition as `t = 0` and adopts that value as the initial level. A waveform whose
  first transition is the start-bit falling edge therefore begins already low, with no
  idle context, and decodes to garbage. Emit an explicit (redundant) rising edge
  before the start bit.
- **The `uart` decoder's auto-baud fails on short lead-ins** — pass `baudrate`
  explicitly. Decoder syntax uses **colons**: `uart:rx=rx:baudrate=9600`, and
  annotation classes use dashes: `-A uart=rx-data`. `uart=rx=rx` is parsed as a
  decoder named `uart=rx=rx` and fails with `No module named 'uart=rx=rx'`.
- Convert waveforms to `.sr` (srzip) before handing them to REA: `sigrok-cli -i in.vcd -o out.sr`.

#### Architecture limit: pwntools tools need Linux **x64**

`inspect_binary_layout` and `inspect_recorded_crash` fail on this VM with
`capability_unavailable: The initial real-verified pwntools artifact profile supports
Linux x64 only`. The nanocore is **arm64**, so those two stay unavailable; the env var
is correct, the architecture is not. Fixing it would mean an x86_64 guest under QEMU
emulation — far slower than the native arm64 VM, for two tools.

- **The VM auto-starts at login** via the LaunchAgent
  `~/Library/LaunchAgents/com.alemigav.nanocore.plist` (`RunAtLoad`, runs
  `limactl start core` with `LIMA_HOME` set, logs to `~/Library/Logs/nanocore.log`).
  Inside the guest, systemd's `rea-mcp.service` is `enabled`, so the MCP endpoint
  returns on its own. Verified end-to-end: `limactl stop core` → `launchctl kickstart`
  → VM `Running` and `127.0.0.1:7391` answering in **~9 s**.
  Manage it with:
  ```sh
  launchctl bootout   gui/$(id -u)/com.alemigav.nanocore   # stop auto-starting
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.alemigav.nanocore.plist
  launchctl print     gui/$(id -u)/com.alemigav.nanocore   # state
  ```
  Cost: ~4 GiB RAM held while logged in (`limactl stop core` frees it until next login).

---

## 15. Windows / PE analysis — no Windows required

There is no Windows node, and none is needed for **static** PE work. REA parses PE and
CLI metadata in portable TypeScript; its own `inspect_pe_imports` contract states
*"Portable on supported Node hosts; no Windows SDK or engine installation required."*

Real samples are already on this machine: the .NET install ships hundreds of genuine
PE files under `/usr/local/share/dotnet/shared/Microsoft.NETCore.App/9.0.4/`.

### Verified on 2026-10-30 (macOS host, host `rea` server)

`inspect_managed_artifact` on `Microsoft.CSharp.dll` (873 KB):

```
classification: managed · modern-dotnet · cil-and-ready-to-run · arm64
CLI header @1632, runtime 2.5, flags: il-library, strong-name-signed
ReadyToRun signature observed @722944
assembly Microsoft.CSharp 9.0.0.0 · MVID 23c0424f-92c3-41b0-8622-97cfe0afe84d
target framework .NETCoreApp,Version=v9.0
metadata complete: 991/991 tables examined (TypeDef 235, MethodDef 1718, …)
```

`inspect_pe_imports` on `System.Web.dll`:

```
format pe32 · machine 0x014c (i386) · 5120 bytes
import directory rva 10389 (79 bytes @ file offset 2709)
mscoree.dll  →  _CorDllMain   (ILT 10429, IAT 8192, thunk 28c9)
imphash (pefile algorithm): dae02f32a21e03ce65412f6e56942daa
coverage: complete
```

The imphash is the standard malware-clustering fingerprint, computed here without
Windows, a Windows SDK, or a disassembler.

### Static tool surface available today

| Area | Tools |
|---|---|
| .NET / CLI | `inspect_managed_artifact`, `inspect_managed_members`, `inspect_managed_native_boundaries`, `project_managed_application_graph`, `compare_managed_members`, `verify_managed_native_boundaries`, `import_managed_reconstruction` |
| Native PE | `inspect_pe_imports` (verified), `inspect_pe_resources`, `inspect_pe_load_config`, `inspect_pe_certificates`, `inspect_native_exports` |
| Sharing | `inspect_artifact`, `inspect_byte_entropy`, `compare_artifacts`, `inspect_analysis_view` |

Unverified so far: the other `inspect_pe_*` paths, and managed member/boundary
inspection.

### Ghidra on PE — VERIFIED (2026-10-30)

A native PE32 was built with known ground truth (`projects/mkpe.py`, 1024 bytes,
`.text` at RVA 0x1000 containing a countdown loop summing 5+4+3+2+1). Ghidra 12.2
loaded it (`format: pe, architecture: x86`, image base `0x400000`) and returned
assembly matching the input byte-for-byte plus correct pseudocode:

```c
int entry(void) {
  int iVar1 = 0;
  int iVar2 = 5;
  do {
    iVar1 = iVar1 + iVar2;
    iVar2 = iVar2 + -1;
  } while (iVar2 != 0);
  return iVar1;            // 15
}
```

Also recovered: `int __stdcall entry(void)` — the PE/x86 calling convention, where the
same pipeline reported `__cdecl` for a Mach-O arm64 target, so convention detection is
platform-aware. CFG is 3 basic blocks with the back edge (`JNZ 0x401007`, flagged
`conditional`, `jump`, `flow`), and the p-code carries the SSA `MULTIEQUAL` phi for the
loop — a real analysis, not a stub.

**Managed PE is a different story.** Ghidra *loads* a .NET assembly (`System.Web.dll`
→ 4 segments, `managed: true` in the profile) but finds only **2 procedures** in 8 KB
of `.text`: those are native stubs. The IL body is data to it, so decompilation is
meaningless. Use `inspect_managed_artifact` / `inspect_managed_members` for managed
assemblies and reserve Ghidra for native code.

### What genuinely requires Windows

Dynamic execution only: running the sample, debugger sessions, Job Object resource
containment, API monitoring, memory dumping. REA's Windows Ghidra boundary is labelled
*experimental P0* in its own docs.

Not built, deliberately:

- A Windows 11 **ARM64** guest needs a ~5–6 GB ISO and a licence; that is an
  entitlement decision for the user, not something to download unilaterally.
- Lima does not manage Windows; it would need UTM, VMware Fusion, or QEMU+HVF.
- A Windows **x64** guest would *not* close the pwntools x64 gap — that
  `inspect_binary_layout` / `inspect_recorded_crash` profile is Linux-x64-only.

If dynamic Windows analysis is ever wanted, treat it as a separate, contained project:
snapshot rollback, no network egress, and an explicit licence source first.

---

## 16. Version control and backups

Two different problems, two different mechanisms. Conflating them is how people end up
committing a 6 GB toolchain or trusting an untested backup.

### What is versioned — `~/Visao` is a git repo

Only the **irreplaceable, human-authored** material: docs, wrappers, config, provisioning
manifest, test generators. **20 files, ~124 KB.**

```
README.md  PROTOCOL.md  PROVISION.md
config/mimocode.jsonc
scripts/{visao,proj,rea,nanocore,limactl,visao-doctor,apktool,brain-backup}
provision/{com.alemigav.nanocore.plist,com.alemigav.brain-backup.plist,rea-mcp.service}
tools/{mkpe.py,mkuart_vcd.py,mkpcap.py,mkpcap_dns.py}
```

Two commits on `main`, pushed to **`https://github.com/alemigav/visao`** — **private**,
20 files / 83 KB, `main` tracking `origin/main`.

**Commit identity**: `alemigav <alemigav@users.noreply.github.com>`, configured globally
by the user (`~/.gitconfig` holds exactly those two keys, 67 bytes). The email is
GitHub's noreply form, so commits link to the account without exposing a real address.
Earlier commits in this repo were authored per-command with `GIT_AUTHOR_*` env vars —
either method yields the same author.

Never let a commit fall back to the auto-derived
`Alexandre Gavronski <alemigav@Mac-mini-de-Alexandre.local>`: it bakes the machine
hostname into history and won't associate with GitHub. If the global config is ever lost,
git will silently do exactly that.

Verified before pushing: the remote tree contains no `auth.json`, no `.env`, no `*.db`,
no `.toolchain/`, no `.brain/`, no `rea/` — 20 files, all text.

### What is deliberately excluded (`.gitignore`)

| Excluded | Why |
|---|---|
| `.toolchain/` (6.2 GB) | Reproducible from `PROVISION.md` — versions, URLs, sha256s, build lines. Committing a binary derivative of a recipe we already have, 75,000× larger, would bloat history on every upgrade |
| `rea/` (1.0 GB) | Upstream checkout with its own `.git` |
| `.brain/`, `*.db*` | 13 MB of SQLite containing full conversation transcripts, churning daily |
| `.mimocode/` | Agent runtime scratch and locks |
| `auth.json`, `.env`, keys | Secrets — never, anywhere |

### Backup of state — encrypted, verified, daily

Time Machine is **not** used, for arithmetic reasons rather than taste:

| Volume | Filesystem | Size | Verdict |
|---|---|---|---|
| Internal `Macintosh HD` | APFS | 228 GB (**~179 GB used**) | source |
| `VISAO` | APFS | **29 GB**, empty | APFS is fine for TM, but too small for a 179 GB machine |
| `SSD EXTERNO` | **ExFAT** | 120 GB (69 GB used) | `tmutil` refuses ExFAT; reformatting would destroy that data |

A Time Machine full backup needs at least the size of the data set; 29 GB against
179 GB would fill and fail. So `VISAO` (APFS, dedicated, empty) is used as the backup
target for **what cannot be regenerated**, and the 6.2 GB toolchain is left to
`PROVISION.md`. If a disk of ≥250 GB is ever attached, TM becomes the better answer and
covers the toolchain too — `sudo tmutil setdestination -a /Volumes/<name>`.

The backup therefore:

- `brain-backup` writes `brain-YYYYmmdd-HHMMSS.tar.gz.enc` to
  `/Volumes/VISAO/visao-backups/`, falling back to `SSD EXTERNO` if VISAO is unplugged —
  AES-256-CBC, PBKDF2 (200k iterations).
- **One archive holds both halves**: `mimocode.db` + `memory/` (state that changes) and
  `repo/` (the ~124 KB of docs, scripts and provision manifest that cannot be
  regenerated). When the repo has commits, the repo half is produced with
  `git archive` plus a `visao-history.bundle` (a clonable single-file copy of history).
- It takes a **consistent** DB copy with `sqlite3 .backup` even while mimo is writing,
  then the memory directory, and **decrypts the result to verify** before keeping it.
  An unverified backup is not a backup.
- Passphrase lives in the login Keychain as service `visao-backup` (never in the repo,
  never on the external disk).
- Rotation keeps the newest 10 (~86 MB total).
- Once the repo has commits, the `repo/` half is produced by `git archive` **plus a
  `visao-history.bundle`** — a single-file, `git clone`-able copy of the full history.
  Verified: `git bundle verify` reports "records a complete history" and cloning it
  reproduces the commit.
- Scheduled daily at 21:17 by LaunchAgent `com.alemigav.brain-backup`
  (logs to `~/Library/Logs/brain-backup.log`); also safe to run by hand any time.

Restore:

```sh
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass "pass:$(security find-generic-password -s visao-backup -a $USER -w)" \
  -in brain-<stamp>.tar.gz.enc | tar xzf - -C <target-dir>
# then: quit mimo, copy mimocode.db over ~/.local/share/mimocode/mimocode.db,
#       delete mimocode.db-wal and mimocode.db-shm
```

Verified 2026-10-30 twice, on both volumes: restored archive → `pragma integrity_check`
= `ok`, brain session row present, memory tree intact, and the 19-file repo recovered
with `PROVISION.md` (182 lines) and `PROTOCOL.md` (132 lines) intact.

**If a disk is ever formatted APFS**, Time Machine becomes the better option and covers
the toolchain too — `sudo tmutil setdestination -a /Volumes/<name>`.

---

## 17. Portability — rebuilding on another Mac

The repo alone gives you the **capability stack**, not the brain. Two distinct things:

| | Travels via GitHub | Rebuilt / restored |
|---|---|---|
| Docs, scripts, config, provision manifest (83 KB) | ✅ git clone | — |
| Toolchain (6.2 GB) | ❌ | `bootstrap.sh` |
| Session DB + memory (the brain) | ❌ **never committed** | encrypted backup (`brain-backup`) |

```sh
git clone https://github.com/alemigav/visao.git ~/Visao
cd ~/Visao && ./provision/bootstrap.sh --check   # audit: what exists, what is missing
./provision/bootstrap.sh                         # install/skip everything, then verify
```

**Apple Silicon only.** The artefacts are arm64 throughout — Node `darwin-arm64`, the
hand-compiled Ghidra decompiler, the Lima guest. `bootstrap.sh` refuses to run on Intel
rather than half-working.

### What was fixed to make this true

- **All 8 scripts were parameterised.** They previously carried 83 literal
  `/Users/alemigav/...` paths, so a different username broke everything. They now derive
  from `$HOME` and `${VISAO_HOME:-$HOME/Visao}`, overridable per shell.
- **Config and units are rendered from templates**, not copied with someone else's paths
  baked in. `bootstrap.sh` computes the Lima guest user and home at install time
  (`id -un`, `$HOME`) instead of assuming `alemigav` / `/home/alemigav.guest`.
- **The pinned session degrades gracefully.** `visao` tries the pinned id, then
  `--continue`, and explains how to set `VISAO_SESSION` — because a fresh machine has no
  such session and previously would just fail.

### What genuinely does not transfer

The **brain** — this conversation, the accumulated rules and traps in `MEMORY.md`, the
pinned session. Those live in `~/.local/share/mimocode/` and are deliberately excluded
from git: binary, churning daily, full transcripts. Restore from the encrypted backup
instead, and the new machine continues the same conversation.

Machine-specific actions a new Mac still needs, because they are inherently local:
Keychain passphrase (bootstrap creates one), LaunchAgent bootstrap (bootstrap does it),
the Hopper `chmod a-x` if that vendor app happens to be installed, and the SSH/Keychain
authorisation prompts on first use.
