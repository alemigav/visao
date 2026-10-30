#!/usr/bin/env python3
"""Second capture: DNS query + matching response with an A record.

Purpose: verify REA's DNS address attribution rather than trusting it. The
response answer owner is a compression pointer back to the question name, which
is exactly the shape the attribution rule expects.
"""
import struct
import sys

from mkpcap import csum, ipv4, udp, eth

CLIENT_MAC = bytes.fromhex("aa0000000001")
SERVER_MAC = bytes.fromhex("bb0000000002")
CLIENT, RESOLVER = "10.11.12.13", "10.11.12.1"
ANSWER_IP = "93.184.216.34"

qname = b"".join(bytes([len(p)]) + p.encode() for p in "example.com".split(".")) + b"\x00"
question = qname + struct.pack("!HH", 1, 1)  # A, IN

query = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + question

answer = b"\xc0\x0c"                                    # pointer to offset 12
answer += struct.pack("!HHIH", 1, 1, 300, 4)            # A, IN, ttl 300, rdlen 4
answer += bytes(int(x) for x in ANSWER_IP.split("."))
response = struct.pack("!HHHHHH", 0x1234, 0x8180, 1, 1, 0, 0) + question + answer

frames = [
    eth(ipv4(CLIENT, RESOLVER, 17, udp(40000, 53, query, CLIENT, RESOLVER), 1),
        CLIENT_MAC, SERVER_MAC),
    eth(ipv4(RESOLVER, CLIENT, 17, udp(53, 40000, response, RESOLVER, CLIENT), 2),
        SERVER_MAC, CLIENT_MAC),
]

out = sys.argv[1]
with open(out, "wb") as f:
    f.write(struct.pack("!IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
    for i, fr in enumerate(frames):
        f.write(struct.pack("!IIII", 1793388100 + i, i * 1000, len(fr), len(fr)))
        f.write(fr)
print(f"wrote {out}: {len(frames)} packets (query + response for {ANSWER_IP})")
