#!/usr/bin/env python3
import argparse
import random
import socket
import struct
import subprocess
import threading
import time

BUFSIZE = 65536
DNS_SERVER = ""
CORP_IF = "ppp0"
CORP_UP = False


def resolve_via_dns(name, server, timeout=5):
    tid = random.randint(0, 65535)
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    hdr = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    query = hdr + qname + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(query, (server, 53))
        data, _ = s.recvfrom(4096)
    finally:
        s.close()
    if len(data) < 12 or struct.unpack(">H", data[0:2])[0] != tid:
        raise ConnectionError("DNS response mismatch")
    ancount = struct.unpack(">H", data[6:8])[0]
    idx = 12 + len(qname) + 4
    addrs = []
    for _ in range(ancount):
        if data[idx] & 0xC0 == 0xC0:
            idx += 2
        else:
            while data[idx]:
                idx += 1 + data[idx]
            idx += 1
        typ, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[idx:idx + 10])
        idx += 10
        rdata = data[idx:idx + rdlen]
        idx += rdlen
        if typ == 1 and rdlen == 4:
            addrs.append(socket.inet_ntoa(rdata))
    if not addrs:
        raise ConnectionError(f"no A records for {name}")
    return addrs


def corp_checker():
    global CORP_UP
    while True:
        try:
            r = subprocess.run(
                ["ifconfig", CORP_IF],
                capture_output=True,
                text=True,
                timeout=10,
            )
            CORP_UP = "UP" in r.stdout and "inet " in r.stdout
        except Exception:
            CORP_UP = False
        time.sleep(5)


def resolve_host(host, dns_server):
    try:
        socket.inet_aton(host)
        return host
    except OSError:
        pass
    if dns_server:
        return resolve_via_dns(host, dns_server)[0]
    return host


def read_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("EOF")
        data += chunk
    return data


def send_all(sock, data):
    while data:
        sent = sock.send(data)
        data = data[sent:]


def relay(src, dst):
    try:
        while True:
            data = src.recv(BUFSIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def handle(conn):
    try:
        conn.settimeout(30)
        ver, nmethods = read_exact(conn, 2)
        if ver != 5:
            return
        read_exact(conn, nmethods)
        send_all(conn, b"\x05\x00")
        ver, cmd, _rsv, atyp = read_exact(conn, 4)
        if ver != 5 or cmd != 1:
            return
        if atyp == 1:
            host = socket.inet_ntoa(read_exact(conn, 4))
        elif atyp == 3:
            n = read_exact(conn, 1)[0]
            host = read_exact(conn, n).decode()
        elif atyp == 4:
            raw = read_exact(conn, 16)
            host = socket.inet_ntop(socket.AF_INET6, raw)
        else:
            return
        port = struct.unpack(">H", read_exact(conn, 2))[0]

        try:
            target = resolve_host(host, DNS_SERVER)
            if not CORP_UP:
                raise ConnectionError("corporate tunnel is down")
            upstream = socket.create_connection((target, port), timeout=30)
        except Exception:
            send_all(conn, b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            return
        send_all(conn, b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        conn.settimeout(None)
        upstream.settimeout(None)
        t1 = threading.Thread(target=relay, args=(conn, upstream))
        t2 = threading.Thread(target=relay, args=(upstream, conn))
        t1.daemon = True
        t2.daemon = True
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=1082)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--dns", default="")
    ap.add_argument("--corp-if", default="ppp0")
    args = ap.parse_args()
    global DNS_SERVER, CORP_IF
    DNS_SERVER = args.dns
    CORP_IF = args.corp_if
    threading.Thread(target=corp_checker, daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(64)
    print(f"bridge listening on {args.bind}:{args.port}", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
