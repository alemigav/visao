#!/usr/bin/env python3
"""Build a small, deterministic libpcap file with valid IPv4/TCP checksums.

Three packets on port 80 forming a recognizable HTTP conversation, plus one
UDP/DNS-shaped packet, so a dissector has something real to decode.
"""
import struct
import sys


def csum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) + data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def ipv4(src: str, dst: str, proto: int, payload: bytes, ident: int) -> bytes:
    s = bytes(int(x) for x in src.split("."))
    d = bytes(int(x) for x in dst.split("."))
    ver_ihl = 0x45
    total_len = 20 + len(payload)
    hdr = struct.pack("!BBHHHBBH4s4s", ver_ihl, 0, total_len, ident, 0x4000, 64, proto, 0, s, d)
    hdr = hdr[:10] + struct.pack("!H", csum(hdr)) + hdr[12:]
    return hdr + payload


def tcp(sport: int, dport: int, seq: int, ack: int, flags: int, payload: bytes,
        src: str, dst: str) -> bytes:
    hdr = struct.pack("!HHIIBBHHH", sport, dport, seq, ack, 5 << 4, flags, 8192, 0, 0)
    pseudo = bytes(int(x) for x in src.split(".")) + bytes(int(x) for x in dst.split("."))
    pseudo += struct.pack("!BBH", 0, 6, len(hdr) + len(payload))
    c = csum(pseudo + hdr + payload)
    hdr = hdr[:16] + struct.pack("!H", c) + hdr[18:]
    return hdr + payload


def udp(sport: int, dport: int, payload: bytes, src: str, dst: str) -> bytes:
    hdr = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0)
    pseudo = bytes(int(x) for x in src.split(".")) + bytes(int(x) for x in dst.split("."))
    pseudo += struct.pack("!BBH", 0, 17, 8 + len(payload))
    c = csum(pseudo + hdr + payload) or 0xFFFF
    hdr = hdr[:6] + struct.pack("!H", c)
    return hdr + payload


def eth(payload: bytes, src_mac: bytes, dst_mac: bytes, etype: int = 0x0800) -> bytes:
    return dst_mac + src_mac + struct.pack("!H", etype) + payload


CLIENT_MAC = bytes.fromhex("aa0000000001")
SERVER_MAC = bytes.fromhex("bb0000000002")
CLIENT, SERVER = "10.11.12.13", "93.184.216.34"

frames = []

# 1. SYN
frames.append(eth(ipv4(CLIENT, SERVER, 6,
                       tcp(49812, 80, 1000, 0, 0x02, b"", CLIENT, SERVER), 1),
                  CLIENT_MAC, SERVER_MAC))
# 2. HTTP GET request carrying a credential-looking header (useful for later analysis)
req = b"GET /admin/login.php?id=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: probe/1.0\r\n\r\n"
frames.append(eth(ipv4(CLIENT, SERVER, 6,
                       tcp(49812, 80, 1001, 1, 0x18, req, CLIENT, SERVER), 2),
                  CLIENT_MAC, SERVER_MAC))
# 3. HTTP response with a flag-shaped body
body = b"HTTP/1.1 200 OK\r\nServer: nginx/1.24.0\r\nContent-Length: 22\r\n\r\nFLAG{pcaps_work_fine}\n"
frames.append(eth(ipv4(SERVER, CLIENT, 6,
                       tcp(80, 49812, 5000, 1001 + len(req), 0x18, body, SERVER, CLIENT), 3),
                  SERVER_MAC, CLIENT_MAC))
# 4. UDP/DNS-shaped query
dns = struct.pack("!HHHHHH", 0xBEEF, 0x0100, 1, 0, 0, 0)
qname = b"".join(bytes([len(p)]) + p.encode() for p in "example.com".split(".")) + b"\x00"
dns += qname + struct.pack("!HH", 1, 1)
frames.append(eth(ipv4(CLIENT, "8.8.8.8", 17,
                       udp(5353, 53, dns, CLIENT, "8.8.8.8"), 4),
                  CLIENT_MAC, SERVER_MAC))

out = sys.argv[1]
with open(out, "wb") as f:
    f.write(struct.pack("!IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
    for i, fr in enumerate(frames):
        f.write(struct.pack("!IIII", 1793388000 + i, i * 1000, len(fr), len(fr)))
        f.write(fr)
print(f"wrote {out}: {len(frames)} packets")
