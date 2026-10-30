# Provision manifest

Everything outside this repo is **reproducible from this file**. Do not commit the
binaries; re-run these steps. Verified against the build of 2026-10-30 on macOS 26.6,
Apple Silicon (arm64).

Total reproducible footprint: **~7.2 GB** (Ghidra 885 MB, JDK 294 MB, Node 199 MB,
Lima VM 3.0 GB, REA checkout+build ~172 MB, VM disk images and caches the rest).

## Fast path

```sh
git clone https://github.com/alemigav/visao.git ~/Visao   # private repo
cd ~/Visao && ./provision/bootstrap.sh --check            # audit only, changes nothing
./provision/bootstrap.sh                                  # install/skip, then verify
```

`bootstrap.sh` is idempotent — each step detects an existing artefact and skips it —
and refuses to run on Intel Macs, since all artefacts are arm64. It renders the
MiMoCode config and the launchd/systemd units from the `.template` files with your
actual `$HOME`, and computes the Lima guest user/home rather than assuming them.
It never overwrites an existing `~/.config/mimocode/mimocode.jsonc`: a differing
render lands as `mimocode.jsonc.new` for you to diff.

The manual steps below remain the reference for anything the script cannot decide,
and for understanding *why* each piece exists.

---

Root used throughout: `VIS=/Users/alemigav/Visao` (on another machine, your own clone path).

---

## 1. Node 24.22.2 (REA's runtime)

Node 25.5.0 is the machine default and **fails REA's `engine-strict` gate**
(`^22.23.4 || ^24.22.1 || >=26.12.1`).

```sh
mkdir -p "$VIS/.toolchain" && cd "$VIS/.toolchain"
curl -fsSLO https://nodejs.org/dist/v24.22.2/node-v24.22.2-darwin-arm64.tar.xz
tar xf node-v24.22.2-darwin-arm64.tar.xz && rm node-v24.22.2-darwin-arm64.tar.xz
```

## 2. Temurin JDK 25 (Ghidra 12.2 requires Java 25, not 17)

```sh
cd "$VIS/.toolchain"
curl -fsSL -o jdk25.tar.gz "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5_8.tar.gz"
# sha256 36dc14d797aaff6d89aab302cd053fdba6207dfdcf772052fa7b023a94b0e857
shasum -a 256 jdk25.tar.gz
mkdir -p jdk-25.0.5 && tar xzf jdk25.tar.gz -C jdk-25.0.5 --strip-components=1 && rm jdk25.tar.gz
# JAVA_HOME="$VIS/.toolchain/jdk-25.0.5/Contents/Home"
```

## 3. Ghidra 12.2 + **the macOS decompiler, compiled locally**

Ghidra ships native decompilers for `linux_x86_64` and `win_x86_64` **only**. On macOS
REA reports `config_drift` and pseudocode silently dies until a decompiler exists.

```sh
cd "$VIS/.toolchain"
curl -fsSL -o ghidra.zip https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.2_build/ghidra_12.2_PUBLIC_20261016.zip
# sha256 2c2cd776db3c1f6a097ba418922378ac3649cadd5e844a6f5f088ae628a7be67
shasum -a 256 ghidra.zip && unzip -q ghidra.zip && rm ghidra.zip

cd ghidra_12.2_PUBLIC/Ghidra/Features/Decompiler/src/decompile/cpp
make OS=Darwin ARCH_TYPE="" OSDIR=mac_arm_64 CXX="clang++ -std=c++11" ADDITIONAL_FLAGS="-w" -j8 ghidra_opt
mkdir -p ../../os/mac_arm_64 && cp ghidra_opt ../../os/mac_arm_64/decompile
chmod +x ../../os/mac_arm_64/decompile
rm -rf ghi_opt
```

The bundled Makefile hardcodes `-arch x86_64` / `mac_x86_64`; the overrides are
mandatory. Set `-w` because its own `-mmacosx-version-min=10.6` is invalid for arm64.
**Re-run this after every Ghidra upgrade.**

## 4. REA (upstream checkout — not committed here)

```sh
cd "$VIS"
git clone --depth 1 https://github.com/morluto/rea.git rea        # v6.8.0, commit 675d407
cd rea && git submodule update --init --recursive                  # binwalk, ghidra-nativeaot, jadx-headless-mcp, unblob, wakaru
export PATH="$VIS/.toolchain/node-v24.22.2-darwin-arm64/bin:$PATH"
npm ci && npm run build:cached                                     # turbo: metadata:check, compile, artifacts:skills
```

`npm ci` reports `allowScripts` blocks (esbuild ×2, fsevents) and 1 moderate advisory —
both harmless; the build passes 3/3.

## 5. Lima 2.2.1 + the Linux nanocore

```sh
cd "$VIS/.toolchain"
curl -fsSL -o lima.tar.gz https://github.com/lima-vm/lima/releases/download/v2.2.1/lima-2.2.1-Darwin-arm64.tar.gz
# sha256 9e9eacce88f37e185c346bad73aa6136f738d8cdf8c3bb23cd42b071824bc66e
mkdir -p lima && tar xzf lima.tar.gz -C lima && rm lima.tar.gz
export LIMA_HOME="$VIS/.toolchain/lima-home"                        # keeps instances inside .toolchain
mkdir -p "$LIMA_HOME"
./lima/bin/limactl create --name=core --cpus=4 --memory=4 --disk=10 --tty=false template:debian
./lima/bin/limactl start core --tty=false
```

Guest: Debian 13 (trixie) arm64, kernel 6.12, 4 CPU / 4 GiB / 10 GiB, `vz` driver.
Lima auto-forwards guest listeners to host loopback — **no `portForwards` stanza needed**.

### 5a. Guest toolchain

```sh
limactl shell core -- bash -c '
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  tshark sigrok-cli p7zip-full unzip lz4 zstd e2fsprogs xz-utils bzip2 gzip cabextract \
  cpio python3-pip python3-venv pipx util-linux file binutils git curl lzop lziprecover \
  erofs-utils partclone squashfs-tools android-sdk-libsparse-utils unar
pipx install unblob && pipx install jefferson && pipx install ubi_reader
python3 -m venv ~/venv-pwntools && ~/venv-pwntools/bin/pip install -q "pwntools==4.15.0"
cd /tmp && curl -fsSL -O https://github.com/onekey-sec/sasquatch/releases/download/sasquatch-v4.5.1-6/sasquatch_1.0_arm64.deb
sudo dpkg -i sasquatch_1.0_arm64.deb'
```

Versions achieved: tshark 4.4.19, sigrok-cli 0.7.2, unblob 26.6.4, pwntools 4.15.0,
prlimit util-linux 2.41.5, sasquatch 1.0 (both `sasquatch` and `sasquatch-v4be`),
7-Zip 25.01 — **15/15 unblob extractors present**.

### 5b. Node + REA inside the guest (Mode B)

```sh
limactl shell core -- bash -c '
cd /tmp && curl -fsSL -O https://nodejs.org/dist/v24.22.2/node-v24.22.2-linux-arm64.tar.xz
sudo mkdir -p /opt/node24 && sudo tar xJf node-v24.22.2-linux-arm64.tar.xz -C /opt/node24 --strip-components=1'
# copy the source in (home is mounted read-only in the guest, so use the host path):
tar czf "$VIS/.toolchain/rea-src.tgz" -C "$VIS/rea" --exclude ./node_modules --exclude ./.git --exclude ./dist --exclude ./third_party .
limactl shell core -- bash -c '
tar xzf /Users/alemigav/Visao/.toolchain/rea-src.tgz -C ~/rea 2>/dev/null
export PATH=/opt/node24/bin:$PATH && cd ~/rea && npm ci && npm run build:cached'
```

### 5c. systemd service (file: `provision/rea-mcp.service`)

Install to `/etc/systemd/system/rea-mcp.service`, then
`sudo systemctl daemon-reload && sudo systemctl enable --now rea-mcp`.

Non-obvious requirements, each learned by failing:

- `User=alemigav` — **not** `alemigav.guest` (that is only the *home path*; wrong value
  gives `status=217/USER`).
- REA **never searches `PATH`** for these tools: absolute `REA_UNBLOB_COMMAND`,
  `REA_TSHARK_COMMAND`, `REA_CAPINFOS_COMMAND`, `REA_SIGROK_COMMAND`,
  `REA_PWNTOOLS_PYTHON`, plus the prlimit pair. `PATH` must still be set so unblob's
  own extractor children resolve.
- `REA_MCP_TOOL_FAMILIES=firmware,pcap,artifact,native` → 59 tools, no overlap with the
  host server.

## 6. Native macOS tooling

```sh
cd "$VIS/.toolchain"
# adb — Android platform-tools
curl -fsSL -o pt.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip && unzip -q pt.zip && rm pt.zip
ln -sf "$VIS/.toolchain/platform-tools/adb" ~/.local/bin/adb
# apktool 3.0.3 (wrapper runs it with the pinned JDK)
mkdir -p apktool && curl -fsSL -o apktool/apktool_3.0.3.jar https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar
# jadx-headless-mcp 0.7.1 (the version REA verifies)
mkdir -p jadx && cd jadx
curl -fsSLO https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar
# sha256 6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75
# wabt 1.0.42 (REA verifies 1.0.42)
cd "$VIS/.toolchain" && curl -fsSLO https://github.com/WebAssembly/wabt/releases/download/1.0.42/wabt-1.0.42-macos-arm64.tar.gz
mkdir -p wabt-1.0.42 && tar xzf wabt-1.0.42-macos-arm64.tar.gz -C wabt-1.0.42 && rm wabt-1.0.42-macos-arm64.tar.gz
```

## 7. Wiring

- **Scripts**: copy `scripts/*` to `~/.local/bin/` and `chmod +x`. `scripts/adb` is a
  *symlink* into `.toolchain/platform-tools/`; create it with `ln -sf` as above.
- **PATH**: `~/.zshenv` must export `~/.local/bin` (not `.zshrc` — that is
  interactive-only, so scripts and MCP launches would never see it).
- **MiMoCode config**: copy `config/mimocode.jsonc` to `~/.config/mimocode/mimocode.jsonc`.
  It declares local `rea` (stdio, with the tool env) and remote `rea-linux`
  (`http://127.0.0.1:7391/mcp`), plus the `external_directory` roots.
- **VM autostart**: copy `provision/com.alemigav.nanocore.plist` to
  `~/Library/LaunchAgents/`, then
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.alemigav.nanocore.plist`.
- **Hopper disabled (policy)**: it is proprietary. `chmod a-x` its three binaries in
  `~/Applications/Hopper Disassembler.app/Contents/MacOS/`.

## 8. Verify the rebuild

```sh
rea --version                                          # 6.8.0
rea doctor --provider ghidra                           # healthy: true, incl. native decompiler
visao-doctor                                           # entry points, session, DB, VM, port
nanocore bash -c 'sigrok-cli --version; unblob --version; tshark -v | head -1'
lipo -thin arm64e /usr/bin/true -output /tmp/t && rea analyze /tmp/t --provider ghidra
tools/mkpe.py /tmp/x.exe && rea analyze /tmp/x.exe --provider ghidra   # PE path
```

## 9. Not reproducible, deliberately

`.brain/` (session DB snapshots), the memory directory, and `~/.local/share/mimocode/auth.json`
are **state and secrets**, not build artefacts. Back them up separately; never commit them.
