# House-hacking playbook

Working notes for systematically taking apart the devices in your own home. Every
command here has been checked against this machine's actual tooling, and the phases are
ordered so that each one needs less of the previous one's assumptions — you start
passive and only touch hardware when the network has told you what is worth touching.

**Scope rule, once and then not repeated:** devices you own, network you control. Your
bulb's firmware is yours to read; the vendor's cloud API is not yours to attack. When a
step would cross that line, it is marked ⚠︎.

---

## 0. The split that shapes everything

The nanocore VM has **no USB passthrough** (verified: 0 devices in `/dev/bus/usb`). So:

| Runs on the **host** (needs the physical port) | Runs in the **nanocore** (analysis only) |
|---|---|
| `sigrok-cli` / PulseView capture from a logic analyser | `decode_signal_recording` — protocol decoding |
| `flashrom` + CH341A for SPI dumps | `extract_firmware` — unblob unpacking |
| `tcpdump` capture on the host interface | `inspect_pcap_capture` — endpoints, DNS, SNI, URIs |
| `mosquitto_sub`, `adb`, USB-serial consoles | pwntools/ELF tooling, prlimit-sandboxed tools |

Capture on the Mac, analyse in the VM. That is not a limitation to work around — the
nanocore is where untrusted bytes are handled in a sandbox, which is the right place for
them.

### Host tools to install once

```sh
brew install nmap mosquitto sigrok-cli flashrom     # capture/discovery front ends
# optional: pulseview (GUI for sigrok), wireshark
```

Nothing here is required for the first three phases.

---

## 1. Inventory — what is actually in the house

Start passive. No packets are sent that a normal client would not send.

```sh
# who has an IP
arp -a | sort

# what advertises itself (mDNS is gold: IoT devices announce their protocol)
dns-sd -B _services._dns-sd._udp local.        # all service types, ~15 s then Ctrl-C
```

Then browse the interesting types specifically — each is a fingerprint:

```sh
dns-sd -B _http._tcp        local.   # devices with a web UI
dns-sd -B _hap._tcp         local.   # HomeKit accessory protocol
dns-sd -B _googlecast._tcp  local.   # Chromecast / Google TV
dns-sd -B _airplay._tcp     local.   # Apple TV, speakers
dns-sd -B _miio._udp        local.   # Xiaomi / Mi ecosystem
dns-sd -B _shelly._tcp      local.   # Shelly relays (ESP-based, usually hackable)
dns-sd -B _esphomelib._tcp  local.   # ESPHome — already yours
dns-sd -B _mqtt._tcp        local.   # a broker on the LAN: subscribe to # and listen
dns-sd -B _printer._tcp     local.
```

Record for each device: IP, MAC (first 3 bytes = vendor, `arp -a`), open ports, protocol.
Port sweep with `nmap -sT -p- --min-rate 2000 <ip>` — only against your own gear.

**Why mDNS first:** it usually tells you the *chipset family* before you open anything.
`_shelly`, `_esphomelib`, `_miio` all imply ESP32/ESP8266, which means: UART header,
flashable SPI, and usually no secure boot.

---

## 2. What does it talk to? — capture and attribute

The fastest way to find a device's cloud endpoints, OTA server and auth flow.

```sh
sudo tcpdump -i en0 -n -s0 -w /tmp/house.pcap 'not port 22'
# operate the device's app for a few minutes, then Ctrl-C
```

Copy it where the VM can read it — the guest mounts your home read-only at the same path,
so no copying is needed for `/Users/...` paths, but `/tmp` is not shared:

```sh
cp /tmp/house.pcap ~/projects/house.pcap
```

Then attribute it in-session:

```
rea-linux_inspect_pcap_capture  { path: "/Users/<you>/projects/house.pcap" }
```

Returns endpoints, DNS questions→addresses, TLS SNI values, HTTP URIs and a protocol
distribution. What you are looking for:

- **SNI + DNS** → which cloud. `.amazonaws.com`, `.azure-devices.net`, vendor domains.
- **HTTP URIs** → OTA paths (`/firmware/`, `/update`), API versions, device IDs.
- **Ports 1883/8883** → MQTT (plain / TLS), i.e. a broker you can subscribe to.
- **Port 6668, 554, 8000** → Tuya, RTSP, Hikvision-ish.

⚠︎ Replaying the *vendor's* endpoints with your credentials is fine; attacking their
infrastructure is not.

---

## 3. Firmware — three routes, cheapest first

### 3a. Vendor downloads and app-visible URLs (no hardware)

Look for `/firmware`, `/update`, `.bin`, `.img`, `.trx`, `.chk` in the pcap URIs, then
fetch the same URL yourself. Vendor support pages are the other source.

### 3b. Pull it from the device (often easiest)

- Camera/NAS/router with a web UI: many expose a `firmware.bin` endpoint or a
  backup/config download that contains one.
- Android-controlled devices: the companion app sometimes caches the OTA in
  `/sdcard/Android/data/<pkg>/` — `adb pull` it.

### 3c. Read the flash chip (needs hardware, see §5)

### Then unpack it — this is where the nanocore shines

```sh
cp firmware.bin ~/projects/          # guest reads your home read-only
```

```
rea-linux_extract_firmware { path: "/Users/<you>/projects/firmware.bin",
                             output_directory: "/home/<user>.guest/fw/out" }
```

Output must be an **absent** directory inside the guest's own filesystem. It returns
coverage, per-chunk handlers and `extraction_gaps` — read the gaps, they tell you which
extractor is missing rather than silently giving you half a filesystem.

### Triage the extracted tree

```sh
nanocore bash -c 'cd ~/fw/out && find . -type f | head -50'
```

High-value greps, in order of payoff:

| Look for | Command |
|---|---|
| Hardcoded credentials | `grep -rIn --binary-files=without-match -E "(passwd|password|pass|admin)" .` |
| Private keys | `find . -name '*.pem' -o -name 'id_rsa' -o -name '*.key'` |
| Shadow / passwd | `find . -name shadow -o -name passwd`, then `cat` |
| Cloud endpoints | `grep -rIhoE 'https?://[a-z0-9.-]+' . | sort -u` |
| MQTT creds | `grep -rIn -E 'mqtt|broker|1883' .` |
| Update / signature logic | `grep -rIn -E 'firmware|update|verify|signature' .` |
| Busybox + init scripts | `find . -name 'rcS' -o -name inittab -o -name busybox` |

A shell on the device is usually the goal; UART (§5a) gets you there fastest.

---

## 4. Picking your target

Rank devices by expected yield, not by interest:

| Signal | Means | Yield |
|---|---|---|
| `_esphomelib`, `_shelly` | ESP32/ESP8266, UART pads labelled | ⭐⭐⭐ trivial |
| No TLS on the wire, HTTP admin | design didn't consider an adversary | ⭐⭐⭐ |
| Old firmware, no update since 2+ years | known CVEs likely | ⭐⭐ |
| Local MQTT broker | entire device fleet in one channel | ⭐⭐⭐ |
| Cloud-only, TLS-pinned app | much more work for less | ⭐ |
| Mains-powered sealed pot (bulb, plug) | destructive to open | ⭐ (start elsewhere) |

Start with one ESP-based plug or the bridge/hub. A hub is the highest-leverage single
device: compromise it and you usually get the protocol for everything under it.

---

## 5. Physical layer — where the shop comes in

Two entry points matter: a serial console (read the boot log, often get a shell) and the
flash chip (full filesystem, modifiable). Do UART first — it is non-destructive.

### 5a. UART console

**Find the pads.** Look for 3–4 unpopulated holes/pads near the SoC, often labelled
`TX RX GND VCC` or `J1`. Identify ground with a multimeter (continuity to the shield or
power jack barrel).

**Capture and decode with a logic analyser.** A cheap 8-channel fx2lafw clone
(Saleae-clone) works; ~€12. The workflow, given no USB in the VM:

```sh
# 1. capture on the HOST, 0.5–1 MHz is plenty for 115200 baud.
#    The device string depends on the clone: `fx2lafw` for the common 8-ch
#    Saleae clones, or `saleae-logic8` / `dreamsourcelab-dslogic` for others.
#    Check with: sigrok-cli -L | grep -A2 "Supported hardware"
sigrok-cli -d fx2lafw --config samplerate=1m --channels D0,D1 \
           --time 8 -o /Users/<you>/projects/boot.sr

# 2. decode in the VM (this is the tool we verified end to end)
```
```
rea-linux_decode_signal_recording {
  path: "/Users/<you>/projects/boot.sr",
  decoders: "uart:rx=D0:baudrate=115200" }
```

If the baud rate is wrong you get frames that look like garbage; try 115200, 57600, 38400,
9600 in that order. Decoder syntax uses **colons** (`uart:rx=D0:baudrate=115200`);
a wrong form fails with `No module named 'uart=rx=D0'`.

**Then read it for real** with a 3.3 V USB-serial adapter (CP2102/FT232, ~€5), **GND
first, TX→RX, RX→TX, never VCC** unless the board is unpowered and needs it:

```sh
screen /dev/tty.usbserial-XXXX 115200     # or: picocom -b 115200 /dev/tty.usbserial-XXXX
```

Common outcomes, in order of frequency: `U-Boot` prompt (interrupt for a shell; often
lets you `setenv`, `tftpboot`, or read memory) → Linux console login (try `root` with no
password, `root/root`, `admin/admin`) → silent (wrong baud, or TX only, or TX disabled in
a production build).

**U-Boot `printenv` is the single highest-value command in home hacking.** It leaks the
bootargs, the flash layout, the kernel partition and often the recovery image location.

### 5b. SPI flash dump

Needed when there is no console, or the filesystem is squashfs read-only and you want to
modify it. `CH341A` programmer + `SOIC-8` clip ≈ €8.

```sh
brew install flashrom
flashrom -p ch341a_spi -r /Users/<you>/projects/dump1.bin
flashrom -p ch341a_spi -r /Users/<you>/projects/dump2.bin
shasum -a 256 dump1.bin dump2.bin      # MUST match. Two matching reads or your clip slipped.
```

Rules that prevent bricks:

1. **Read twice, compare hashes.** A bad clip gives plausible-looking garbage.
2. **Keep the original.** Never overwrite `dump1.bin`; work on copies.
3. Cut power to the device, power the chip **from the programmer**, and if the chip shares
   the bus with a running SoC, expect contention — an in-circuit clip on a live board often
   reads corrupt. Desoldering is sometimes the honest answer.
4. Before writing anything back: verify your modified image is the same size, and check
   whether the vendor verifies a checksum/signature at boot (§3 triage greps for it).

Windows: CH341A + 1.8 V adapter for 1.8 V chips (many modern IoT). Wrong voltage kills
the chip — read the part number and check its datasheet first.

### 5c. JTAG / SWD (advanced)

`FT2232H` + OpenOCD (~€20) gets you to the SoC's debug unit: memory read, register access,
halt. Board-specific pinouts; use `openocd` to identify the tap chain. Worth it only after
UART and flash have failed.

---

## 6. Radios — the part this stack does not cover

No RF hardware yet, and sigrok decodes logic levels, not radio. What each needs:

| Protocol | Hardware | Software |
|---|---|---|
| **MQTT (Wi-Fi-based)** | none — it's just TCP | `mosquitto_sub -h <ip> -t '#' -v` |
| **BLE** | nRF52840 dongle (~€12) for sniffing | `bluez`+`btmon`, or `nRF Connect` |
| **Zigbee** | CC2652 coordinator (~€22) | `zigbee2mqtt`, or sniffer firmware + `wireshark` |
| **Z-Wave** | Aeotec Z-Stick (~€40) | `zwave-js` |
| **Wi-Fi (monitor mode)** | MT7612U / AR9271 adapter (~€25) | `tcpdump -i wlan0mon`, then our pcap analysis |
| **Sub-GHz (remotes, gate, sensors)** | RTL-SDR + rtl_433 (~€30) | `rtl_433` |

**MQTT is the free win** and needs nothing: if `dns-sd -B _mqtt._tcp` or a port scan
finds a broker, `mosquitto_sub -h <ip> -t '#' -v` streams the whole device fleet's state,
often unauthenticated. That is frequently the entire "smart home" protocol in the clear.

---

## 7. The app and the daemon

### Companion app (what the vendor's code reveals)

```sh
# locate and pull the APK
adb shell pm list packages | grep -i <vendor>
adb shell pm path <package>          # base.apk + splits
adb pull /data/app/.../base.apk ~/projects/

# on-device logs while you operate the app
adb logcat -c && adb logcat | grep -iE 'http|mqtt|token|key|login'
```

Then in-session (verified tooling, no Linux needed):

```
rea_inspect_android_package   { path: ".../base.apk" }
rea_search_android_classes    { path: ".../base.apk", query: "Auth" }
rea_inspect_android_method    { path: "...", class: "…", method: "…" }
rea_trace_android_references  { ... }
```

You are looking for: base URLs, API keys (often in `strings.xml`), MQTT credentials,
certificate pinning (which tells you how much work TLS interception would be), and the
local-network discovery mechanism the app uses — that is usually a second, undocumented
path into the device.

### Daemon on a hub/NAS/camera

Pull the ELF out of the extracted firmware (§3) and open it:

```
rea_open_binary      { path: ".../usr/sbin/daemon", provider_id: "ghidra" }
rea_analyze_function { procedure: "main" }
rea_search_strings   { ... }     # endpoints, formats, credentials
```

Prefer the **web UI's JavaScript** when there is one — `analyze_web_bundle` and
`analyze_javascript_application` reconstruct routes and endpoints from a bundle without
running it, which is far cheaper than reversing a compiled daemon.

---

## 8. Safety and reversibility

Non-negotiables, learned from other people's bricks:

- **Read before you write.** Every phase above is read-only; keep it that way until you
  have a verified duplicate of the original.
- **Snapshot before modifying**: `cp dump1.bin dump1.orig.bin`, record the sha256.
- **Mains devices**: unplug, and do not open power supplies — capacitors hold charge.
  Work on the low-voltage side only.
- **Isolate while testing**: put the target on a network with no WAN route, or block it at
  the router. A device in a half-modified state should not be able to phone home and
  auto-update over your work.
- **One change at a time**, and re-verify boot after each.
- **Keep notes per device**: firmware sha256, board photo, pad locations, baud rate,
  credentials found, what you changed. A file per device in `~/projects/<device>/`.

---

## 9. Shopping list

Nothing is needed for phases 1–3 (inventory, capture, vendor firmware). Buy in this order:

| Priority | Item | ~€ | Unlocks |
|---|---|---|---|
| 1 | USB-serial 3.3 V (CP2102 or FT232) | 5 | serial console — the fastest route to a shell |
| 1 | 8-ch logic analyser (fx2lafw clone) | 12 | finding the UART pins, decoding boot logs |
| 1 | Multimeter + dupont wires + SOIC-8 clip | 20 | continuity, connections, flash dumps |
| 2 | CH341A programmer (+1.8 V adapter) | 10 | full flash read/write |
| 2 | nRF52840 dongle | 12 | BLE sniffing, Zigbee sniffer firmware |
| 3 | CC2652 Zigbee coordinator | 22 | whole Zigbee mesh |
| 3 | MT7612U Wi-Fi adapter | 25 | monitor mode, 802.11 analysis |
| 3 | RTL-SDR + antenna | 30 | 433/868 MHz remotes, gate, sensors |
| 4 | FT2232H + OpenOCD | 20 | JTAG/SWD |
| 4 | Hot air rework station | 60 | desoldering flash, dead devices |

Start with row 1: about €37 and it covers UART, the highest-yield technique in this list.

---

## 10. First night — nothing to buy

1. `dns-sd -B _services._dns-sd._udp local.` — inventory, and note which protocols appear.
2. `arp -a` — record MACs; look up the vendor prefixes.
3. `sudo tcpdump -i en0 -s0 -w ~/projects/first.pcap`, operate three devices, stop.
4. `rea-linux_inspect_pcap_capture` on it — find every cloud endpoint and TLS SNI.
5. Download one firmware image from a vendor support page.
6. `rea-linux_extract_firmware` on it, then the §3 triage greps.
7. Pick the device with the best §4 signal and write its note file.

That sequence needs zero hardware and typically produces the two things worth having:
the network map, and a filesystem with credentials, keys and endpoints in it.

---

## 11. Known limits of this setup

- **No USB in the VM** → all capture is host-side; the VM decodes. Do not expect
  `sigrok-cli` inside the nanocore to see your analyser.
- **No radio** → BLE/Zigbee/Z-Wave/sub-GHz need the hardware in §9.
- **No hands** → I cannot press a pairing button, hold a probe, or clip a chip. You are the
  physical layer; I do the analysis, the commands and the reasoning.
- **pwntools tooling needs Linux x64** — unavailable on this arm64 guest, so binary-exploit
  scaffolding is manual.
- **FAT Mach-O needs `lipo -thin`** before Ghidra will take it (irrelevant for IoT, relevant
  if a device ships an Apple binary).
