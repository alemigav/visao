#!/usr/bin/env python3
"""Emit a VCD with a UART frame carrying a known byte, 9600 8N1.

Waveform is idle-high, then start bit, 8 data bits LSB-first, stop bit. Timestamps
are integer nanoseconds (bit period 104166 ns ~= 9600 baud), so a decoder must
recover exactly the byte we encode -- a wrong result means a decoder problem, not
an ambiguous input.
"""
import sys

BYTE = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x41  # 'A'
BAUD = int(sys.argv[4]) if len(sys.argv) > 4 else 9600
BIT_NS = round(1_000_000_000 / BAUD)
# Idle-high lead-in: must span several bit periods so the decoder's start-bit
# detection and baud estimation have unambiguous context.
T0 = int(sys.argv[3]) if len(sys.argv) > 3 else 20 * BIT_NS

bits = [0]                                    # start
bits += [(BYTE >> i) & 1 for i in range(8)]   # data, LSB first
bits += [1]                                   # stop

lines = []
lines.append("$timescale 1ns $end")
lines.append("$scope module logic $end")
lines.append("$var wire 1 ! rx $end")
lines.append("$upscope $end")
lines.append("$enddefinitions $end")
lines.append("$dumpvars")
lines.append("1!")                            # idle high
lines.append("$end")

# sigrok's VCD importer ignores $dumpvars and treats the first *timestamped*
# transition as t=0, adopting its value as the initial level. Emit an explicit
# (redundant) rise before the start bit so the decoder sees real idle-high
# context instead of a signal that begins already low.
lines.append(f"#{T0 // 2}")
lines.append("1!")

t = T0
lines.append(f"#{t}")
lines.append("0!")                            # falling edge = start bit
prev = 0
for i, b in enumerate(bits):
    val = b
    if val != prev:
        # transition happens at the start of this bit cell
        lines.append(f"#{T0 + i * BIT_NS}")
        lines.append(f"{val}!")
        prev = val
# return to idle
lines.append(f"#{T0 + len(bits) * BIT_NS}")
lines.append("1!")

out = sys.argv[1]
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"wrote {out}: UART {BAUD} 8N1 byte 0x{BYTE:02X} ({chr(BYTE)!r}), {len(bits)} bit cells")
