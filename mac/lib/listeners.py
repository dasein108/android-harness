#!/usr/bin/env python3
"""Parse Android /proc/net/tcp{,6} and /proc/net/udp{,6} into a listener table.

Why this exists: inside Termux the agent runs as an untrusted_app uid, and
Android denies it both the netlink socket `ss` needs and /proc/net/tcp itself.
A device-side "no external listener" check therefore sees nothing and would pass
vacuously. The adb `shell` uid can read those files, so the authoritative view
is taken from the host and attributed back to an Android uid.

Input : the concatenated contents of the /proc/net files, each preceded by a
        line of the form `#FILE <name>`.
Output: one line per listening socket, `proto<TAB>address<TAB>port<TAB>uid`.
"""

import sys

# TCP_LISTEN in Linux's tcp_states enum, as printed by /proc/net/tcp.
TCP_LISTEN = "0A"


def parse_addr(hex_addr: str) -> str:
    """Decode the little-endian hex address /proc/net uses."""
    if len(hex_addr) == 8:  # IPv4
        b = bytes.fromhex(hex_addr)
        return ".".join(str(x) for x in reversed(b))
    if len(hex_addr) == 32:  # IPv6, stored as four little-endian 32-bit words
        words = [hex_addr[i:i + 8] for i in range(0, 32, 8)]
        raw = b"".join(bytes(reversed(bytes.fromhex(w))) for w in words)
        groups = [raw[i:i + 2].hex() for i in range(0, 16, 2)]
        # IPv4-mapped (::ffff:a.b.c.d) is worth showing in its familiar form.
        if groups[:5] == ["0000"] * 5 and groups[5] == "ffff":
            return "::ffff:" + ".".join(str(x) for x in raw[12:16])
        return ":".join(g.lstrip("0") or "0" for g in groups)
    return hex_addr


def main() -> int:
    proto = "?"
    for line in sys.stdin:
        line = line.strip()
        if line.startswith("#FILE"):
            proto = line.split()[-1].rsplit("/", 1)[-1]
            continue
        parts = line.split()
        if len(parts) < 8 or parts[0] == "sl":
            continue
        local, state, uid = parts[1], parts[3], parts[7]
        # UDP sockets have no LISTEN state; a bound one shows state 07 (CLOSE).
        if proto.startswith("tcp") and state != TCP_LISTEN:
            continue
        try:
            addr_hex, port_hex = local.split(":")
            port = int(port_hex, 16)
        except ValueError:
            continue
        print(f"{proto}\t{parse_addr(addr_hex)}\t{port}\t{uid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
