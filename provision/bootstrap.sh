#!/bin/bash
# Visão bootstrap — rebuild the whole stack on a fresh Apple Silicon Mac.
#
#   ./bootstrap.sh --check     audit what exists / is missing (changes nothing)
#   ./bootstrap.sh             install everything, skipping what is already there
#
# Idempotent: each step detects an existing artefact and skips. Nothing outside
# $VISAO_HOME, ~/.local/bin, ~/.config/mimocode, ~/Library/LaunchAgents and the
# Keychain is touched — no Homebrew, no system runtimes, no /Applications installs.
set -uo pipefail

VISAO_HOME="${VISAO_HOME:-$HOME/Visao}"
VIS="$VISAO_HOME"
BIN="$HOME/.local/bin"
TC="$VIS/.toolchain"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

B=$'\033[1m'; R=$'\033[0m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'
step() { printf '\n%s▸ %s%s\n' "$B" "$*" "$R"; }
ok()   { if [ "$CHECK" -eq 1 ]; then
           printf '  %s·%s %s %s(missing — would install)%s\n' "$Y" "$R" "$*" "$D" "$R"
         else printf '  %s✓%s %s\n' "$G" "$R" "$*"; fi; }
skip() { printf '  %s·%s %s %s(already present)%s\n' "$D" "$R" "$*" "$D" "$R"; }
miss() { printf '  %s✗%s %s\n' "$Y" "$R" "$*"; }
have() { printf '  %s✓%s %s\n' "$G" "$R" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$Y" "$R" "$*" >&2; exit 1; }
run()  { if [ "$CHECK" -eq 1 ]; then printf '  %s$ %s%s\n' "$D" "$*" "$R"; else "$@"; fi; }

# --- prerequisites -----------------------------------------------------------
step "prerequisites"
[ "$(uname -s)" = Darwin ] || die "macOS only (found $(uname -s))"
[ "$(uname -m)" = arm64 ]   || die "Apple Silicon only — PROVISION.md artefacts are arm64 (Node darwin-arm64, Ghidra decompiler, Lima guest)"
have "macOS on arm64"
for t in git curl sqlite3 security clang; do
  command -v "$t" >/dev/null || die "missing '$t' (install Xcode Command Line Tools: xcode-select --install)"
done
have "core tools present"
command -v gh >/dev/null || printf '  %s·%s gh absent — fine unless you want to push to GitHub\n' "$D" "$R"

mkdir -p "$TC" "$BIN"

# --- 1. Node 24.22.2 ---------------------------------------------------------
step "Node 24.22.2 (REA rejects the machine default)"
NODE="$TC/node-v24.22.2-darwin-arm64/bin/node"
if [ -x "$NODE" ]; then skip "node 24.22.2"
else
  run bash -c "cd '$TC' && curl -fsSLO https://nodejs.org/dist/v24.22.2/node-v24.22.2-darwin-arm64.tar.xz \
    && tar xf node-v24.22.2-darwin-arm64.tar.xz && rm node-v24.22.2-darwin-arm64.tar.xz"
  ok "node 24.22.2"
fi

# --- 2. Temurin JDK 25 -------------------------------------------------------
step "Temurin JDK 25 (Ghidra 12.2 requires 25, not 17)"
JAVA_HOME_DIR="$TC/jdk-25.0.5/Contents/Home"
if [ -x "$JAVA_HOME_DIR/bin/java" ]; then skip "jdk 25.0.5"
else
  run bash -c "cd '$TC' \
    && curl -fsSL -o jdk25.tar.gz 'https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5_8.tar.gz' \
    && echo '36dc14d797aaff6d89aab302cd053fdba6207dfdcf772052fa7b023a94b0e857  jdk25.tar.gz' | shasum -a 256 -c - \
    && mkdir -p jdk-25.0.5 && tar xzf jdk25.tar.gz -C jdk-25.0.5 --strip-components=1 && rm jdk25.tar.gz"
  ok "jdk 25.0.5"
fi

# --- 3. Ghidra + the macOS decompiler (compiled here) ------------------------
step "Ghidra 12.2 + native decompiler"
GHIDRA="$TC/ghidra_12.2_PUBLIC"
if [ -x "$GHIDRA/Ghidra/Features/Decompiler/os/mac_arm_64/decompile" ]; then skip "ghidra 12.2 + decompiler"
else
  if [ ! -d "$GHIDRA" ]; then
    run bash -c "cd '$TC' \
      && curl -fsSL -o ghidra.zip https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.2_build/ghidra_12.2_PUBLIC_20261016.zip \
      && echo '2c2cd776db3c1f6a097ba418922378ac3649cadd5e844a6f5f088ae628a7be67  ghidra.zip' | shasum -a 256 -c - \
      && unzip -q ghidra.zip && rm ghidra.zip"
  fi
  # Ghidra ships no macOS decompiler; its Makefile hardcodes -arch x86_64.
  run bash -c "cd '$GHIDRA/Ghidra/Features/Decompiler/src/decompile/cpp' \
    && make OS=Darwin ARCH_TYPE='' OSDIR=mac_arm_64 CXX='clang++ -std=c++11' ADDITIONAL_FLAGS='-w' -j8 ghidra_opt \
    && mkdir -p ../../os/mac_arm_64 && cp ghidra_opt ../../os/mac_arm_64/decompile \
    && chmod +x ../../os/mac_arm_64/decompile && rm -rf ghi_opt"
  ok "ghidra 12.2 + decompiler"
fi

# --- 4. REA ------------------------------------------------------------------
step "REA checkout and build"
if [ -f "$VIS/rea/dist/cli-runtime/cli.js" ]; then skip "rea build"
else
  [ -d "$VIS/rea/.git" ] || run git clone --depth 1 https://github.com/morluto/rea.git "$VIS/rea"
  run bash -c "cd '$VIS/rea' && git submodule update --init --recursive"
  run bash -c "export PATH='$TC/node-v24.22.2-darwin-arm64/bin:\$PATH' && cd '$VIS/rea' && npm ci && npm run build:cached"
  ok "rea 6.8.0 built"
fi

# --- 5. Lima + the Linux nanocore -------------------------------------------
step "Lima 2.2.1 and the nanocore VM"
export LIMA_HOME="$TC/lima-home"
LIMACTL="$TC/lima/bin/limactl"
if [ -x "$LIMACTL" ]; then skip "lima 2.2.1"
else
  run bash -c "cd '$TC' \
    && curl -fsSL -o lima.tar.gz https://github.com/lima-vm/lima/releases/download/v2.2.1/lima-2.2.1-Darwin-arm64.tar.gz \
    && echo '9e9eacce88f37e185c346bad73aa6136f738d8cdf8c3bb23cd42b071824bc66e  lima.tar.gz' | shasum -a 256 -c - \
    && mkdir -p lima && tar xzf lima.tar.gz -C lima && rm lima.tar.gz"
  ok "lima 2.2.1"
fi
mkdir -p "$LIMA_HOME"
if [ -d "$LIMA_HOME/core" ]; then skip "VM 'core'"
else
  run "$LIMACTL" create --name=core --cpus=4 --memory=4 --disk=10 --tty=false template:debian
  run "$LIMACTL" start core --tty=false
  ok "VM 'core' created and started"
fi

# --- 6. Guest toolchain ------------------------------------------------------
step "guest toolchain (tshark, sigrok, unblob, sasquatch, pwntools)"
if "$LIMACTL" shell core -- bash -c 'command -v unblob >/dev/null && command -v sasquatch >/dev/null' 2>/dev/null; then
  skip "guest tools"
else
  run "$LIMACTL" shell core -- bash -c '
    sudo apt-get update -qq &&
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      tshark sigrok-cli p7zip-full unzip lz4 zstd e2fsprogs xz-utils bzip2 gzip cabextract \
      cpio python3-pip python3-venv pipx util-linux file binutils git curl lzop lziprecover \
      erofs-utils partclone squashfs-tools android-sdk-libsparse-utils unar &&
    pipx install unblob && pipx install jefferson && pipx install ubi_reader &&
    python3 -m venv ~/venv-pwntools && ~/venv-pwntools/bin/pip install -q "pwntools==4.15.0" &&
    cd /tmp && curl -fsSL -O https://github.com/onekey-sec/sasquatch/releases/download/sasquatch-v4.5.1-6/sasquatch_1.0_arm64.deb &&
    sudo dpkg -i sasquatch_1.0_arm64.deb'
  ok "guest tools"
fi

# --- 7. In-guest REA (Mode B) + systemd unit ---------------------------------
step "in-guest REA over HTTP MCP"
GUEST_USER=$("$LIMACTL" shell core -- bash -c 'id -un' 2>/dev/null | tr -d '\r')
GUEST_HOME=$("$LIMACTL" shell core -- bash -c 'echo $HOME' 2>/dev/null | tr -d '\r')
[ -n "$GUEST_USER" ] && [ -n "$GUEST_HOME" ] || die "could not determine guest user/home"
have "guest user=$GUEST_USER home=$GUEST_HOME"
if "$LIMACTL" shell core -- test -f "$GUEST_HOME/rea/dist/cli-runtime/cli.js" 2>/dev/null; then
  skip "guest rea build"
else
  run "$LIMACTL" shell core -- bash -c '
    cd /tmp && curl -fsSL -O https://nodejs.org/dist/v24.22.2/node-v24.22.2-linux-arm64.tar.xz &&
    sudo mkdir -p /opt/node24 && sudo tar xJf node-v24.22.2-linux-arm64.tar.xz -C /opt/node24 --strip-components=1'
  run bash -c "tar czf '$TC/rea-src.tgz' -C '$VIS/rea' --exclude ./node_modules --exclude ./.git --exclude ./dist --exclude ./third_party ."
  run "$LIMACTL" shell core -- bash -c "mkdir -p ~/rea && tar xzf '$TC/rea-src.tgz' -C ~/rea 2>/dev/null; \
    export PATH=/opt/node24/bin:\$PATH && cd ~/rea && npm ci && npm run build:cached"
  ok "guest rea built"
fi
UNIT=/tmp/rea-mcp.service
sed -e "s#@GUEST_USER@#$GUEST_USER#g" -e "s#@GUEST_HOME@#$GUEST_HOME#g" \
  "$VIS/provision/rea-mcp.service.template" > "$UNIT"
if [ "$CHECK" -eq 0 ]; then
  "$LIMACTL" shell core -- sudo cp "$UNIT" /etc/systemd/system/rea-mcp.service 2>/dev/null ||
    { cat "$UNIT" | "$LIMACTL" shell core -- bash -c 'sudo tee /etc/systemd/system/rea-mcp.service >/dev/null'; }
  "$LIMACTL" shell core -- bash -c 'sudo systemctl daemon-reload && sudo systemctl enable --now rea-mcp'
  ok "rea-mcp.service installed and enabled"
fi

# --- 8. Native macOS tooling -------------------------------------------------
step "native tooling (adb, apktool, jadx, WABT)"
if [ -x "$TC/platform-tools/adb" ]; then skip "platform-tools"
else run bash -c "cd '$TC' && curl -fsSL -o pt.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip && unzip -q pt.zip && rm pt.zip"; ok "adb"; fi
ln -sf "$TC/platform-tools/adb" "$BIN/adb" 2>/dev/null || true
if [ -f "$TC/apktool/apktool_3.0.3.jar" ]; then skip "apktool"; else
  run bash -c "mkdir -p '$TC/apktool' && curl -fsSL -o '$TC/apktool/apktool_3.0.3.jar' https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar"; ok "apktool"; fi
if [ -f "$TC/jadx/jadx-headless-mcp-0.7.1-all.jar" ]; then skip "jadx-headless-mcp"; else
  run bash -c "mkdir -p '$TC/jadx' && cd '$TC/jadx' && curl -fsSLO https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar \
    && echo '6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75  jadx-headless-mcp-0.7.1-all.jar' | shasum -a 256 -c -"; ok "jadx-headless-mcp"; fi
if [ -d "$TC/wabt-1.0.42" ]; then skip "wabt"; else
  run bash -c "cd '$TC' && curl -fsSLO https://github.com/WebAssembly/wabt/releases/download/1.0.42/wabt-1.0.42-macos-arm64.tar.gz \
    && mkdir -p wabt-1.0.42 && tar xzf wabt-1.0.42-macos-arm64.tar.gz -C wabt-1.0.42 && rm wabt-1.0.42-macos-arm64.tar.gz"; ok "wabt"; fi

# --- 9. Scripts --------------------------------------------------------------
step "wrapper scripts"
if [ "$CHECK" -eq 0 ]; then
  cp "$VIS"/scripts/{visao,proj,rea,nanocore,limactl,visao-doctor,apktool,brain-backup} "$BIN"/
  chmod +x "$BIN"/{visao,proj,rea,nanocore,limactl,visao-doctor,apktool,brain-backup}
  ok "installed into $BIN"
else
  for s in visao proj rea nanocore limactl visao-doctor apktool brain-backup; do
    [ -x "$BIN/$s" ] && skip "$s" || miss "$s"
  done
fi

# --- 10. MiMoCode config -----------------------------------------------------
step "MiMoCode config"
CFG="$HOME/.config/mimocode/mimocode.jsonc"
mkdir -p "$(dirname "$CFG")"
RENDERED=$(mktemp)
sed -e "s#@VISAO_HOME@#$VIS#g" -e "s#@HOME@#$HOME#g" "$VIS/provision/mimocode.jsonc.template" > "$RENDERED"
if [ -f "$CFG" ]; then
  if cmp -s "$RENDERED" "$CFG"; then skip "config identical"
  else
    cp "$RENDERED" "$CFG.new"
    miss "existing config preserved; rendered proposal written to $CFG.new — diff before replacing"
  fi
elif [ "$CHECK" -eq 0 ]; then
  cp "$RENDERED" "$CFG"; ok "config written to $CFG"
else
  miss "config absent"
fi
rm -f "$RENDERED"

# --- 11. Backups + autostart -------------------------------------------------
step "backup keychain and LaunchAgents"
if security find-generic-password -s visao-backup -a "$USER" -w >/dev/null 2>&1; then skip "keychain 'visao-backup'"
elif [ "$CHECK" -eq 0 ]; then
  security add-generic-password -s visao-backup -a "$USER" -w "$(openssl rand -base64 32)" -U && ok "keychain item created"
else miss "keychain 'visao-backup'"; fi

if [ "$CHECK" -eq 0 ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  for t in nanocore brain-backup; do
    sed -e "s#@VISAO_HOME@#$VIS#g" -e "s#@HOME@#$HOME#g" \
      "$VIS/provision/com.alemigav.$t.plist.template" > "$HOME/Library/LaunchAgents/com.alemigav.$t.plist"
    launchctl bootout "gui/$(id -u)/com.alemigav.$t" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.alemigav.$t.plist" 2>/dev/null
    ok "LaunchAgent com.alemigav.$t"
  done
fi

# --- 12. Verify --------------------------------------------------------------
step "verification"
if [ "$CHECK" -eq 1 ]; then
  printf '  %s--check finished: nothing was changed.%s\n' "$D" "$R"
  exit 0
fi
"$BIN/rea" --version     || die "rea does not run"
"$BIN/rea" doctor --provider ghidra | head -2
"$BIN/visao-doctor" | tail -4
printf '\n%bDone.%b Open a new terminal and type %bvisao%b.\n' "$B" "$R" "$B" "$R"
printf '%bNote:%b the pinned brain session does not exist on a fresh machine — restore the\n' "$D" "$R"
printf 'encrypted backup (brain-backup) or set VISAO_SESSION, otherwise visao falls back\n'
printf 'to the most recent session.\n'
