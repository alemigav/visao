#!/usr/bin/env python3
"""Emit a minimal but valid native PE32 (i386) executable.

Ground truth coded into .text at RVA 0x1000:

    31 C0              xor  eax, eax
    B9 05 00 00 00     mov  ecx, 5
  loop:
    01 C8              add  eax, ecx
    49                 dec  ecx
    75 FB              jnz  loop
    C3                 ret

That is a deliberate countdown sum: 5+4+3+2+1 = 15 in EAX. If a decompiler
recovers a loop with that constant result, it is genuinely understanding the
code; if it emits garbage we find out here.
"""
import struct
import sys

CODE = bytes.fromhex("31c0b90500000001c849" "75fb" "c3")
IMAGE_BASE = 0x400000
SEC_RVA, SEC_RAW, SEC_ALIGN = 0x1000, 0x200, 0x200

out = bytearray()

# --- DOS header -------------------------------------------------------------
dos = bytearray(0x40)
dos[0:2] = b"MZ"
struct.pack_into("<H", dos, 0x02, 0x90)          # e_cblp
struct.pack_into("<H", dos, 0x04, 0x03)          # e_cp
struct.pack_into("<H", dos, 0x18, 0x40)          # e_lfarlc
struct.pack_into("<I", dos, 0x3C, 0x80)          # e_lfanew -> PE header
out += dos
out += bytes(0x40)                                # DOS stub

# --- PE + COFF headers ------------------------------------------------------
out += b"PE\0\0"
coff = struct.pack(
    "<HHIIIHH",
    0x014C,      # Machine x86
    1,           # NumberOfSections
    0, 0, 0,     # timestamp, symbol table, symbols
    0xE0,        # SizeOfOptionalHeader (PE32)
    0x0102,      # EXECUTABLE_IMAGE | 32BIT_MACHINE
)
out += coff

# --- Optional header (PE32) -------------------------------------------------
opt = bytearray()
opt += struct.pack("<HBB", 0x10B, 1, 0)                    # magic, linker versions
opt += struct.pack("<III", len(CODE), 0, 0)                # code/init/uninit sizes
opt += struct.pack("<II", SEC_RVA, SEC_RVA)                # entry point, base of code
opt += struct.pack("<I", SEC_RVA + 0x1000)                 # base of data
opt += struct.pack("<II", IMAGE_BASE, SEC_ALIGN)           # image base, section align
opt += struct.pack("<II", SEC_ALIGN, 6)                    # file align, OS major+minor
opt += struct.pack("<II", 0, 6)                            # image ver, subsystem ver
opt += struct.pack("<I", 0)                                # win32 version
opt += struct.pack("<III", SEC_RVA + 0x2000, SEC_RAW, 0)   # SizeOfImage, Headers, checksum
opt += struct.pack("<HH", 3, 0)                            # subsystem console, dll chars
opt += struct.pack("<IIII", 0x100000, 0x1000, 0x100000, 0x1000)
opt += struct.pack("<II", 0, 16)                           # loader flags, rva count
opt += bytes(16 * 8)                                       # data directories
assert len(opt) == 0xE0, hex(len(opt))
out += opt

# --- Section table ----------------------------------------------------------
sect = struct.pack(
    "<8sIIIIIIHHI",
    b".text\0\0\0",
    len(CODE),      # VirtualSize
    SEC_RVA,        # VirtualAddress
    0x200,          # SizeOfRawData
    SEC_RAW,        # PointerToRawData
    0, 0,           # relocs ptr, linenums ptr
    0, 0,           # counts
    0x60000020,     # CODE | EXECUTE | READ
)
out += sect

# --- Pad to raw code offset, then code --------------------------------------
assert len(out) <= SEC_RAW
out += bytes(SEC_RAW - len(out))
out += CODE
out += bytes(0x200 - len(CODE))

path = sys.argv[1]
with open(path, "wb") as f:
    f.write(out)
print(f"wrote {path}: {len(out)} bytes, entry RVA 0x{SEC_RVA:x}, code {CODE.hex()}")
