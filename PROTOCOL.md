# Context Discipline Protocol

How the brain stays useful across a long life. Written 2026-10-30 at 51 % context.

The problem this solves: work that is **finished and documented** keeps occupying
working context, so every later turn pays for it. The fix is not to forget it — it is
already written down — but to carry a *pointer* instead of the *payload*.

---

## 1. The three tiers

Every piece of information in play belongs to exactly one tier.

| Tier | What it is | Carry in context? |
|---|---|---|
| **A — Live** | The task being worked on right now, undecided questions, unreviewed findings, anything the next action depends on | **Yes, fully** |
| **B — Closed & documented** | Work that is verified, written into `README.md` and/or `MEMORY.md`, and needed by no open task | **Pointer only** |
| **C — Discarded** | Dead ends, superseded attempts, raw tool output whose conclusion is already recorded | **No** — one clause if the *reason* matters |

Tier C is the easiest to keep by accident: verbatim JSON, full file dumps, failed
attempts. Keep the conclusion and the reason a thing was rejected; drop the bytes.

## 2. The drop gate

A topic may move from tier A to tier B **only** when all three hold:

1. **Verified** — it ran, and the result was checked against ground truth (not merely
   "the command exited 0").
2. **Documented** — a future session could reproduce it from `README.md` /
   `MEMORY.md` alone: path, command, expected output, and the trap that bit us.
3. **Not load-bearing** — no open task currently depends on the details.

If any condition fails, it stays in tier A. Half-documented work is worse than
un-documented: it invites confident re-derivation from a summary.

## 3. Triggers

| Context | Action |
|---|---|
| **50 %** | *Consolidate*: run the close-out ritual (§4) on everything already closed; move any verified-but-undocumented findings into the docs |
| **65 %** | *Handoff*: write open items + live state to `memory/sessions/<id>/notes.md`, then stop carrying closed detail for the rest of the session |
| **85 %** | *Rebuild*: run `/rebuild` from the latest checkpoint; do not attempt new work before it |

Context % is shown by the harness. Never guess it.

## 4. The close-out ritual

Run per endeavour, in this order. Nothing is dropped before step 4.

1. **Verify** the result against a known-truth artefact or second method.
2. **Document** it: `README.md` (human-facing, with the reproduction command) and
   `MEMORY.md` (agent-facing, compressed, with the trap if there was one).
3. **Ledger** it: add one line to the Closed-work ledger below.
4. **Announce** the pointer in one line: *"Closed: <thing> → README §N, MEMORY: <bullet>."*
5. **Drop** the payload. From here the topic is answered by reading the doc, never by
   re-deriving from memory.

The user's keywords **"scratch"** or **"consolidate"** mean: run this ritual across
everything closed, and reply with the ledger delta — not with a narration of the work.

## 5. Rules that make this safe

- **Re-read, don't reconstruct.** When a closed topic resurfaces, read that README
  section or MEMORY bullet first. Never rebuild the conclusion from a paraphrase —
  paraphrases lose the exact paths, versions and caveats that made the work correct.
- **Verify claims, not memories.** MEMORY entries are claims about a point in time.
  Machine state drifts (services restart, files move, permissions change): check live
  before acting on any name, path, or version.
- **One home per fact.** The README explains *why* and *how to reproduce*; MEMORY holds
  the compressed rule; the ledger holds *that it is done*. Duplicating detail in all
  three is how the budget gets eaten.
- **Record refusals too.** "We decided not to build X because Y" is cheap to store and
  expensive to rediscover. Rejected paths belong in the ledger with their reason.
- **Never drop the trap.** A gotcha that cost real debugging time is the highest-value
  thing to record, even when the task itself is trivial.

## 6. Anti-patterns

- Carrying raw tool output (evidence JSON, full file dumps) after its conclusion is written.
- Re-explaining a resolved design decision when a § reference would do.
- Re-litigating a corrected mistake — cite the rule, move on.
- Writing a doc so long that reading it costs what re-deriving would have cost.
- Marking something "documented" because a chat message described it. Chat is not storage.

---

## Closed-work ledger

Every entry: **what is done**, **where it is written**, **what must not be redone**.
Consult this before planning anything that sounds familiar.

| # | Endeavour | Recorded in | Do not redo |
|---|---|---|---|
| 1 | REA 6.8.0 cloned, submodules, built | README §5 | `npm ci` / build recipe, submodule list |
| 2 | Pinned Node 24.22.2 (engine-strict gate) | README §3, MEMORY Rules | Do not use system Node 25.5.0 |
| 3 | Ghidra 12.2 + Temurin JDK 25 in `.toolchain/` | README §3, §4 | Ghidra needs Java **25**; do not try system Java 1.8 |
| 4 | macOS arm64 decompiler **compiled from Ghidra source** | README §4 (recipe) | Rebuild after every Ghidra upgrade — it ships no macOS binary |
| 5 | Wrappers `visao` / `proj` / `rea` (+`nanocore`, `limactl`, `adb`, `apktool`, `visao-doctor`) | README §2 | Never `npm link`; PATH wiring via `.zshenv` |
| 6 | MCP registration: host `rea` (stdio) + `rea-linux` (HTTP) | README §7, §14 | Env is fixed at spawn — config edits need a `mimo` restart |
| 7 | Hopper rejected (licensing + broken bridge) and **disabled at OS level** | README §4, §10, MEMORY Rules | Never re-enable, never propose proprietary engines |
| 8 | Brain session pinned + launcher retry + daily DB snapshots + `visao-doctor` | README §6, §10 (#13–14) | The 5 s worker race is known; retry handles it |
| 9 | Native wins: adb, apktool, jadx-headless-mcp JAR, WABT | MEMORY (verified bullet) | All four verified via REA client probes; no Linux needed |
| 10 | Lima nanocore: Debian 13 arm64, 4 CPU/4 GiB/10 GiB, `vz` | README §14 | No `portForwards` needed — listeners auto-forward |
| 11 | sasquatch via unblob's own `.deb` fork → 15/15 extractors | README §14, MEMORY | Do not build squashfs-tools from source |
| 12 | Firmware extraction verified (squashfs @ offset 4096) | README §14 | Extraction is per-file; `/tmp` is not shared into the guest |
| 13 | pcap verified (HTTP URIs, DNS attribution both directions) | README §14 | Attribution requires one complete question/answer pair |
| 14 | sigrok verified (UART `0x41`@9600, `0x48`@115200) | README §14, MEMORY | VCD: emit explicit rising edge; pass `baudrate`; colons not `=` |
| 15 | Ghidra on native PE verified; managed PE must not go to Ghidra | README §15 | PE32 loop → correct pseudocode; IL is data to Ghidra |
| 16 | Windows dynamic analysis **deliberately not built** | README §15, MEMORY | Needs licence + ISO; user decided "document and stop" |
| 17 | MCP HTTP transport is single-session | README §14, MEMORY | **Never curl-probe `rea-linux`** while the client is attached |
| 18 | LaunchAgent auto-starts the VM; systemd auto-starts `rea-mcp` | README §14 | `daemon-reload` without restart avoids evicting the client |
| 19 | `external_directory` roots: `~/projects/**` allow, else ask | README §8 | Last matching rule wins; catch-all must stay first |
| 20 | `visao` rendered as a **command-center dashboard** (status header + numbered menu, returns to the menu when a session exits; non-TTY callers bypass it) | README §2 | Don't rebuild it as a plain launcher; don't add a TTY check that also skips automation |
| 21 | **Corrected mistake**: `visao-doctor` used to probe `rea-linux` with a real MCP `initialize`, which evicted the agent's own session | README §2, §14 | Health checks use `nc -z 127.0.0.1 7391`; **never send `initialize` while a client is attached** |
| 22 | `~/Visao` is a git repo: 20 files / 136 KB, pushed to private `alemigav/visao`; commits authored as `alemigav <alemigav@users.noreply.github.com>` via global config (~/.gitconfig: exactly 2 keys) — docs, wrappers, config, provision manifest, test generators | README §16, `PROVISION.md` | Never commit `.toolchain/`, `rea/`, `.brain/`, `.mimocode/`, `*.db`, `auth.json`; reproducible bulk is regenerated, not versioned |
| 26 | **Project 2: `~/projects/re2-64-decomp`** — RE2 (N64) decompilation. Own repo `71595bb`; M0 done (MIPS BE decompiles via REA/Ghidra), M1 blocked on the user's ROM. Tools: `n64info.py`, `wrap_mips_elf.py`, `mkmips.py` | `~/projects/re2-64-decomp/README.md` | **REA's raw-binary loader refuses `mips`** — ROM segments must be wrapped as ELF32 BE MIPS first. Never commit the ROM |
| 25 | **`PLAYBOOK.md`** — the house-hacking workflow: mDNS/ARP inventory, pcap attribution, firmware acquisition→`extract_firmware`→triage greps, UART via host capture + `decode_signal_recording`, SPI dump rules (read twice, hash, keep original), radios shopping list, device `note` discipline, first-night checklist | README §13, `PLAYBOOK.md` | Key constraint: **the VM has no USB** — capture host-side, analyse in the guest. Don't write playbook commands assuming `/dev/bus/usb` exists |
| 24 | **Portable bootstrap**: `provision/bootstrap.sh` (`--check` audit / full install, idempotent, refuses Intel) + `.template` files for config and units; all 8 scripts parameterised (`$HOME`, `${VISAO_HOME:-…}`) replacing 83 literal paths; `visao` falls back to `--continue` when the pinned session is absent | README §17, `PROVISION.md` | Don't reintroduce absolute `/Users/...` paths into `scripts/` — that is exactly what broke portability |
| 23 | Encrypted backups to the **VISAO** APFS volume (29 GB, auto-falls back to `SSD EXTERNO`): one archive holds **state** (`mimocode.db` + `memory/`) *and* **recipe** (`repo/`, plus a `visao-history.bundle` once commits exist) — AES-256, Keychain passphrase, verify-after-write, daily 21:17, keep 10 | README §16 | TM is ruled out by arithmetic (179 GB used vs 29 GB volume; SSD is ExFAT with 69 GB of data). Don't "improve" it into plain tar — the DB holds full transcripts |

---

## Where the live state goes at 65 %

Write this block into `memory/sessions/<id>/notes.md`, then stop carrying detail:

```
## Live handoff <timestamp>
Open:      <tasks in flight, one line each>
Decided:   <decisions taken this session not yet in the docs>
Blocked:   <what needs the user: restarts, licences, clicks>
Next:      <the single next action>
Avoid:     <approaches already ruled out this session, and why>
```
