#!/usr/bin/env python3
"""vpn-ondemand.py — поднимает корп. L2TP только по требованию.

Триггер — DNS-запрос к корпоративной зоне (через /etc/resolver зоны
уходят на 127.0.0.1:5354). Логика на каждый запрос:

  1) туннель ppp0 уже есть          -> просто переслать запрос корп. DNS;
  2) корп. сеть доступна напрямую   -> VPN НЕ поднимаем (корп. Wi-Fi/LAN),
     (корп. Wi-Fi/LAN)                запрос идёт на корп. DNS напрямую;
  3) ни туннеля, ни прямой сети     -> ставим маркер спроса, просим watchdog
     поднять L2TP, ждём готовности DNS (до WAIT_READY с), пересылаем;
     не дождались — быстрый SERVFAIL (клиент повторит запрос).

Исключения из правила 3 (иначе dial не может состояться, а публичные имена
в корп. зонах перестают открываться):

  * имена самих VPN-серверов (vpn1..4.tradesoft.ru из профилей) и
    ONDEMAND_BYPASS резолвятся публичным DNS без подъёма туннеля — macOS
    резолвит сервер в момент dial через тот же системный резолвер, и корп.
    DNS без туннеля недоступен (25.11.2026: networksetup висел в Connecting);
  * если туннель поднять не удалось (cooldown после неудачи), ответ берём
    у публичного DNS — публичные сайты этих зон продолжают работать.

Простой: если туннель поднят, корп. DNS-запросов нет IDLE секунд, нет
установленных соединений в корп. подсети и маркер спроса несвежий —
туннель гасится (scutil --nc stop).

Запуск: root-демон com.tradesoft.corp-vpn-ondemand.
Проверки: vpn-ondemand.py --selftest
"""
import argparse
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time

LISTEN_HOST = os.environ.get("CORP_ONDEMAND_HOST", "127.0.0.1")
# ВАЖНО: не 5353 — этот порт занят mDNS (mDNSResponder), и системный
# резолвер считает nameserver на 5353 multicast-DNS: запросы до нашего
# демона не доходили, macOS молча падал на обычный DNS. 5354 — обычный порт.
LISTEN_PORT = int(os.environ.get("CORP_ONDEMAND_PORT", "5354"))
CONF = os.environ.get("CORP_NETWORKS_CONF", "/usr/local/etc/corp-networks.conf")
LOG = os.environ.get("CORP_ONDEMAND_LOG", "/tmp/corp-vpn-ondemand.log")
DEMAND_FILE = os.environ.get("CORP_VPN_DEMAND_FILE", "/tmp/corp-vpn-demand")
HOLD_FILE = os.environ.get("CORP_VPN_HOLD_FILE", "/tmp/corp-vpn-hold")
DIAL_COOLDOWN_FILE = os.environ.get("CORP_VPN_DIAL_COOLDOWN",
                                    "/tmp/corp-vpn-dial-cooldown")
DIAL_COOLDOWN_SECS = int(os.environ.get("CORP_DIAL_COOLDOWN_SECS", "180"))
WATCHDOG = os.environ.get("CORP_VPN_WATCHDOG", "/usr/local/sbin/vpn-watchdog.sh")
CORP_IF = "ppp0"

IDLE = int(os.environ.get("CORP_ONDEMAND_IDLE", "600"))         # простой, с
WAIT_READY = float(os.environ.get("CORP_ONDEMAND_WAIT", "10"))  # ожидание DNS
DIAL_MIN_INTERVAL = int(os.environ.get("CORP_ONDEMAND_DIAL_GAP", "20"))
KICK_MIN_INTERVAL = int(os.environ.get("CORP_ONDEMAND_KICK_GAP", "120"))
KICK_GRACE = int(os.environ.get("CORP_ONDEMAND_KICK_GRACE", "15"))
ROUTES_DAEMON = os.environ.get("CORP_ROUTES_DAEMON",
                               "system/com.tradesoft.corp-vpn-routes")
PROBE_TTL = 20.0
DNS_TIMEOUT = 2.0
PUBLIC_DNS_TTL = 60.0     # кэш «обычных» DNS-серверов (scutil --dns)
BYPASS_TTL = 300.0        # кэш имён VPN-серверов из профилей
# Кэши горячего пути: на каждый DNS-запрос нельзя дёргать ifconfig/ipconfig
# (это ~10 процессов на запрос). Короткий TTL: состояние сети меняется
# медленнее, а «свежесть» там, где она важна, берётся через force=True.
VPN_UP_TTL = 2.0
CORP_LAN_TTL = 20.0

# Фолбэк, если конфиг недоступен: корп. зоны из corp-networks.conf.
FALLBACK_ZONES = [
    "tradesoft.ru", "tradesoft.pro", "tradesoft.corp", "prj",
    "master.systest.php7", "master.systest.php56", "auto-vision.ru",
    "parts-catalogs.ru", "parts-catalogs.com", "parts-index.com",
    "bitrix24.ru", "bitrix24.com", "t120",
]
FALLBACK_DNS = ["192.168.0.210", "192.168.0.220"]
# Эталоны корп. сети (те же, что у vpn-watchdog.sh / corp-wifi-routes.sh):
# приватный MAC en0 для корп. Wi-Fi и ARP-MAC шлюза. Основной источник —
# corp-networks.conf; значения ниже — только страховка на случай его отсутствия.
FALLBACK_EN0_MACS = ["b6:be:0c:d5:9a:24"]
FALLBACK_GW_MACS = ["54:b8:a:cf:80:0"]
CORP_LAN_PREFIX = "192.168.128."
PPP_TRAFFIC_MIN = int(os.environ.get("CORP_ONDEMAND_PPP_BYTES", "8192"))


_lock = threading.Lock()
_cfg_lock = threading.Lock()   # кэши scutil (имена серверов, DNS)
_slots = threading.Semaphore(int(os.environ.get("CORP_ONDEMAND_MAXQ", "32")))
_state = {
    "last_activity": time.time(),
    "last_dial": 0.0,
    "dial_running": False,
    "ready_until": 0.0,
    "probe_ok_until": 0.0,
    "corpwifi": (False, 0.0),
}


def log(msg):
    line = "%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass


def trim_log(path=LOG, limit=2 * 1024 * 1024):
    try:
        if os.path.getsize(path) > limit:
            with open(path, "r+", encoding="utf-8", errors="ignore") as f:
                tail = f.readlines()[-2000:]
                f.seek(0)
                f.truncate()
                f.writelines(tail)
    except OSError:
        pass


# ---------------------------------------------------------------- конфиг ---
def parse_zones_from_text(text, var="DOMAIN_SUFFIX"):
    """Зоны из переменной конфига (ведущая точка убирается)."""
    m = re.search(r'^%s="((?:[^"\\]|\\.)*)"' % re.escape(var), text, re.M | re.S)
    if not m:
        return []
    zones = []
    for raw in m.group(1).split():
        z = raw.strip().lower().lstrip(".")
        if z and z not in zones:
            zones.append(z)
    return zones


def parse_dns_from_text(text):
    m = re.search(r'^DNS_HOSTS="((?:[^"\\]|\\.)*)"', text, re.M | re.S)
    if not m:
        return []
    return [x for x in m.group(1).split() if x]


def read_conf_text():
    """Текст corp-networks.conf ("" если файла нет)."""
    try:
        with open(CONF, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def conf_zones(text):
    """Зоны-триггеры из конфига: DOMAIN_SUFFIX + ONDEMAND_ZONES (чистая)."""
    zones = []
    for z in (parse_zones_from_text(text)
              + parse_zones_from_text(text, "ONDEMAND_ZONES")):
        if z not in zones:
            zones.append(z)
    return zones


def load_config():
    text = read_conf_text()
    zones = conf_zones(text)
    servers = parse_dns_from_text(text)
    return (zones or FALLBACK_ZONES), (servers or FALLBACK_DNS)


def conf_var(name, default=""):
    """Строковое значение переменной из corp-networks.conf."""
    try:
        with open(CONF, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return default
    m = re.search(r'^%s="?([^"\n]*)"?' % re.escape(name), text, re.M)
    return m.group(1).strip() if m else default


def parse_macs_from_text(text, var):
    """MAC-эталоны из corp-networks.conf (CORP_WIFI_EN0_MACS и т.п.)."""
    m = re.search(r'^%s="((?:[^"\\]|\\.)*)"' % re.escape(var), text, re.M | re.S)
    if not m:
        return []
    return [x.strip().lower() for x in m.group(1).split() if x.strip()]


def load_macs():
    en0, gw = list(FALLBACK_EN0_MACS), list(FALLBACK_GW_MACS)
    try:
        with open(CONF, encoding="utf-8") as f:
            text = f.read()
        en0 = parse_macs_from_text(text, "CORP_WIFI_EN0_MACS") or en0
        gw = parse_macs_from_text(text, "CORP_WIFI_GATEWAY_MACS") or gw
    except OSError:
        pass
    return en0, gw


# ------------------------------------------------------------------- DNS ---
def parse_qname(data):
    """Имя из вопроса DNS (offset 12). None — пакет битый/не запрос."""
    if len(data) < 17:
        return None
    qdcount = struct.unpack(">H", data[4:6])[0]
    if qdcount < 1:
        return None
    idx, labels = 12, []
    while idx < len(data):
        ln = data[idx]
        if ln == 0:
            return ".".join(labels).lower()
        if ln & 0xC0:  # сжатие в вопросе не встречается — считаем битым
            return None
        idx += 1
        if idx + ln > len(data):
            return None
        labels.append(data[idx:idx + ln].decode("latin-1"))
        idx += ln
    return None


def zone_match(qname, zones):
    if not qname:
        return False
    q = qname.lower().rstrip(".")
    return any(q == z or q.endswith("." + z) for z in zones)


def build_error(data, rcode):
    """Ответ-ошибка (SERVFAIL=2 / REFUSED=5) на исходный запрос."""
    qdcount = struct.unpack(">H", data[4:6])[0] if len(data) >= 6 else 0
    # Копируем заголовок и вопрос, чтобы клиент сопоставил ответ с запросом.
    end = 12
    if qdcount:
        while end < len(data) and data[end] != 0:
            end += 1 + data[end]
        end = min(end + 5, len(data))
    question = data[12:end] if qdcount else b""
    flags = 0x8000 | (rcode & 0xF) | 0x0100  # QR + RD
    hdr = struct.pack(">HHHHHH", struct.unpack(">H", data[0:2])[0],
                      flags, 1 if qdcount else 0, 0, 0, 0)
    return hdr + question


def dns_rcode(packet):
    """rcode из ответа DNS (None — пакет не ответ)."""
    if not packet or len(packet) < 4:
        return None
    return struct.unpack(">H", packet[2:4])[0] & 0xF


def dns_ancount(packet):
    """Число записей в ответе (None — пакет не ответ)."""
    if not packet or len(packet) < 8:
        return None
    return struct.unpack(">H", packet[6:8])[0]


def forward_udp(packet, servers, timeout=DNS_TIMEOUT):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        for srv in servers:
            try:
                s.sendto(packet, (srv, 53))
                data, _ = s.recvfrom(65535)
                if len(data) >= 12 and data[0:2] == packet[0:2]:
                    return data
            except (socket.timeout, OSError):
                continue
        return None
    finally:
        s.close()


def forward_tcp(packet, servers, timeout=DNS_TIMEOUT):
    for srv in servers:
        try:
            with socket.create_connection((srv, 53), timeout=timeout) as c:
                c.sendall(struct.pack(">H", len(packet)) + packet)
                hdr = _recv_exact(c, 2)
                if not hdr:
                    continue
                n = struct.unpack(">H", hdr)[0]
                data = _recv_exact(c, n)
                if data and data[0:2] == packet[0:2]:
                    return data
        except OSError:
            continue
    return None


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def dns_probe(servers, timeout=1.0):
    """Корп. DNS отвечает? Строим простой A-запрос tradesoft.ru."""
    qname = b"\x09tradesoft\x03ru\x00"
    packet = struct.pack(">HHHHHH", int(time.time()) & 0xFFFF, 0x0100, 1, 0, 0, 0) \
        + qname + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        for srv in servers:
            try:
                s.sendto(packet, (srv, 53))
                data, _ = s.recvfrom(4096)
                if len(data) >= 12 and data[0:2] == packet[0:2]:
                    return True
            except (socket.timeout, OSError):
                continue
        return False
    finally:
        s.close()


def parse_public_dns(text, corp_servers=()):
    """Обычные (не наши) DNS-серверы из вывода `scutil --dns`.

    Нужны, чтобы резолвить имена VPN-серверов и публичные имена корп. зон,
    когда туннеля нет. Отбрасываем loopback (наш собственный резолвер),
    корп. DNS (без туннеля недоступны) и нестандартные порты.
    """
    skip = set(corp_servers) | {"127.0.0.1", "::1", "localhost"}
    out = []
    for block in re.split(r"(?m)^resolver #", text or "")[1:]:
        m = re.search(r"(?m)^\s*nameserver\[\d+\]\s*:\s*(\S+)", block)
        if not m:
            continue
        ns = m.group(1)
        pm = re.search(r"(?m)^\s*port\s*:\s*(\d+)", block)
        if pm and pm.group(1) != "53":
            continue
        if ns in skip or ns in out:
            continue
        out.append(ns)
    return out


def public_dns_servers(corp_servers):
    cached, until = _state.get("public_dns", ([], 0.0))
    if time.time() < until:
        return cached
    with _cfg_lock:
        cached, until = _state.get("public_dns", ([], 0.0))
        if time.time() < until:
            return cached
        dns = parse_public_dns(_run(["/usr/sbin/scutil", "--dns"], timeout=5),
                               corp_servers)
        _state["public_dns"] = (dns, time.time() + PUBLIC_DNS_TTL)
        return dns


def parse_profiles(list_text):
    """Имена PPP-профилей из `scutil --nc list`."""
    names = []
    for line in (list_text or "").splitlines():
        if "PPP" not in line:
            continue
        m = re.search(r'"([^"]+)"', line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return names


def parse_remote_address(show_text):
    """Адрес сервера из `scutil --nc show <профиль>` (только имя хоста)."""
    m = re.search(r"CommRemoteAddress\s*:\s*(\S+)", show_text or "")
    if not m:
        return ""
    addr = m.group(1).strip().strip('"').lower().rstrip(".")
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", addr) or ":" in addr:
        return ""       # IP-литерал резолвить не надо
    return addr


def vpn_names():
    """Имена, которые нельзя отдавать корп. DNS: серверы VPN + ONDEMAND_BYPASS.

    macOS резолвит адрес VPN-сервера в момент dial через системный резолвер,
    то есть через нас. Пока туннеля нет, корп. DNS недоступен — такой запрос
    надо отдавать обычному DNS, иначе dial зависает в Connecting.
    """
    cached, until = _state.get("vpn_names", ([], 0.0))
    if time.time() < until:
        return cached
    with _cfg_lock:
        return _vpn_names_locked()


def _vpn_names_locked():
    cached, until = _state.get("vpn_names", ([], 0.0))
    if time.time() < until:
        return cached
    names = []
    for raw in conf_var("ONDEMAND_BYPASS", "").replace(",", " ").split():
        n = raw.strip().lower().lstrip(".").rstrip(".")
        if n and n not in names:
            names.append(n)
    for p in parse_profiles(_run(["/usr/sbin/scutil", "--nc", "list"])):
        addr = parse_remote_address(
            _run(["/usr/sbin/scutil", "--nc", "show", p]))
        if addr and addr not in names:
            names.append(addr)
    _state["vpn_names"] = (names, time.time() + BYPASS_TTL)
    return names


def is_bypass(qname, names):
    q = (qname or "").lower().rstrip(".")
    return any(q == n or q.endswith("." + n) for n in names)


def cooldown_fresh(mtime, now, secs=None):
    """Свежий ли cooldown после неудачного dial'а (чистая функция)."""
    if mtime is None:
        return False
    return (now - mtime) < (DIAL_COOLDOWN_SECS if secs is None else secs)


def dial_blocked(now=None):
    """Dial сейчас бессмысленен: watchdog в cooldown после неудачи."""
    if _state.get("dial_running"):
        return False
    try:
        mtime = os.path.getmtime(DIAL_COOLDOWN_FILE)
    except OSError:
        return False
    return cooldown_fresh(mtime, now or time.time())


def log_throttled(key, msg, secs=60):
    """Пишем в лог не чаще раза в secs (повторные запросы не заливают лог)."""
    now = time.time()
    if now - _state.get("log_" + key, 0.0) < secs:
        return
    _state["log_" + key] = now
    log(msg)


# ------------------------------------------------------------ сеть/туннель ---
def vpn_up(force=False):
    """Поднят ли ppp0. Кэш VPN_UP_TTL; force=True — перепроверить сейчас."""
    now = time.time()
    if not force:
        cached = _state.get("vpn_up")
        if cached and now < cached[1]:
            return cached[0]
    try:
        out = subprocess.run(["/sbin/ifconfig", CORP_IF], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    up = "inet " in out
    _state["vpn_up"] = (up, now + VPN_UP_TTL)
    # Момент подъёма нужен, чтобы не дёргать маршрутный демон, пока он
    # штатно пересобирает маршруты (см. maybe_kick_routes).
    _state["vpn_up_since"] = _state.get("vpn_up_since") or (now if up else 0.0)
    if not up:
        _state["vpn_up_since"] = 0.0
    return up


def _run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def mac_matches(value, macs):
    """MAC (в любом регистре) входит в список эталонов."""
    if not value:
        return False
    v = value.strip().lower()
    return any(v == m.strip().lower() for m in macs)


def en0_mac():
    m = re.search(r"\bether\s+([0-9a-f:]{11,17})",
                  _run(["/sbin/ifconfig", "en0"]), re.I)
    return m.group(1).lower() if m else ""


def gw_mac():
    """ARP-MAC шлюза по умолчанию (не через туннель)."""
    gw = ""
    for line in _run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] == "default" and not p[-1].startswith("utun"):
            gw = p[1]
            break
    if not gw or gw == "0.0.0.0":
        return ""
    m = re.search(r"\bat\s+([0-9a-f:]{11,17})",
                  _run(["/usr/sbin/arp", "-n", gw]), re.I)
    return m.group(1).lower() if m else ""


def corp_wifi_now():
    """Корп. Wi-Fi: приватный MAC en0 ИЛИ ARP-MAC шлюза из эталонов.

    На корп. Wi-Fi L2TP/IPSec не поднимается, поэтому там туннель не нужен.
    Вердикт кэшируется на PROBE_TTL в обе стороны (чтобы не дёргать
    netstat/arp на каждый DNS-запрос).
    """
    verdict, until = _state.get("corpwifi", (False, 0.0))
    now = time.time()
    if now < until:
        return verdict
    res = mac_matches(en0_mac(), _EN0_MACS) or mac_matches(gw_mac(), _GW_MACS)
    _state["corpwifi"] = (res, now + PROBE_TTL)
    return res


def corp_lan(force=False):
    """Проводной корп. LAN: IP 192.168.128.x на не-Wi-Fi интерфейсе.

    Кэш CORP_LAN_TTL: проверка обходит все интерфейсы (ifconfig -lu + ipconfig
    на каждый), а спрашивают её на каждый DNS-запрос.
    """
    now = time.time()
    if not force:
        cached = _state.get("corp_lan")
        if cached and now < cached[1]:
            return cached[0]
    res = False
    for iface in _run(["/sbin/ifconfig", "-lu"]).split():
        if iface == "en0" or iface.startswith(
                ("lo", "utun", "gif", "stf", "anpi", "awdl", "llw", "ppp",
                 "vnic", "ap")):
            continue
        if _run(["/usr/sbin/ipconfig", "getifaddr", iface]).strip().startswith(
                CORP_LAN_PREFIX):
            res = True
            break
    _state["corp_lan"] = (res, now + CORP_LAN_TTL)
    return res


def direct_corp(servers):
    """Корп. DNS отвечает без VPN (корп. Wi-Fi/LAN или прямой доступ)."""
    if vpn_up():
        return False
    if time.time() < _state["probe_ok_until"]:
        return True
    if dns_probe(servers, timeout=0.8):
        _state["probe_ok_until"] = time.time() + PROBE_TTL
        return True
    return False


def corp_direct_net(servers):
    """VPN не нужен: корп. Wi-Fi/LAN (ресурсы доступны напрямую)."""
    if vpn_up():
        return False
    return corp_wifi_now() or corp_lan() or direct_corp(servers)


def parse_connected_profiles(list_text):
    """Имена подключённых PPP-профилей из `scutil --nc list` (чистая функция)."""
    names = []
    for line in (list_text or "").splitlines():
        if "(Connected)" not in line or "PPP" not in line:
            continue
        m = re.search(r'"([^"]+)"', line)
        if m and m.group(1) not in names:
            names.append(m.group(1))
    return names


def connected_profiles():
    return parse_connected_profiles(
        _run(["/usr/sbin/scutil", "--nc", "list"]))


def connected_profile():
    names = connected_profiles()
    return names[0] if names else ""


def dial_async(servers=None):
    """Ставит маркер спроса и просит watchdog поднять туннель (в фоне)."""
    if corp_direct_net(servers or _SERVERS):
        # Корп. Wi-Fi/LAN: корп. DNS доступен напрямую, туннель не нужен.
        return
    try:
        with open(DEMAND_FILE, "w", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S\n"))
        os.chmod(DEMAND_FILE, 0o666)
    except OSError:
        pass
    with _lock:
        now = time.time()
        if _state["dial_running"] or now - _state["last_dial"] < DIAL_MIN_INTERVAL:
            return
        _state["dial_running"] = True
        _state["last_dial"] = now

    def run():
        deadline = time.time() + 60
        try:
            while time.time() < deadline:
                if vpn_up(force=True):
                    break
                if os.path.exists(WATCHDOG):
                    # Watchdog держит собственный lock: если его тик уже идёт,
                    # запуск выйдет мгновенно — повторяем, пока не поднимется.
                    subprocess.run(["/bin/sh", WATCHDOG], timeout=90)
                else:
                    subprocess.run(["/usr/sbin/networksetup",
                                    "-connectpppoeservice", "vpn2-ts"],
                                   timeout=40)
                if vpn_up(force=True):
                    break
                time.sleep(3)
        except (OSError, subprocess.SubprocessError) as ex:
            log("dial error: %s" % type(ex).__name__)
        finally:
            with _lock:
                _state["dial_running"] = False
            log("dial finished (vpn_up=%s)" % vpn_up())

    threading.Thread(target=run, daemon=True).start()
    log("demand: запрос к корп. зоне, поднимаю туннель")


def wait_ready(servers, timeout=WAIT_READY):
    """Ждём готовности корп. DNS.

    Возвращает "ready" (DNS отвечает), "vpn_up" (туннель поднялся, но DNS ещё
    не готов — маршруты пересобираются) или "no_vpn" (туннеля нет).
    Если туннель появился, но маршрута до корп. DNS нет, продлеваем ожидание
    на один WAIT_READY: маршрутный демон после kickstart тратит несколько
    секунд на пересборку (25.11.2026: туннель поднялся за 8 с, DNS — позже).
    """
    end = time.time() + timeout
    extended = False
    direct = None
    while True:
        if direct is None:
            direct = corp_direct_net(servers)
        if direct:
            return "ready"
        up = vpn_up(force=True)
        if up and dns_probe(servers, timeout=0.6):
            return "ready"
        if up and not extended:
            maybe_kick_routes(servers)
            end = max(end, time.time() + timeout)
            extended = True
        if time.time() >= end:
            break
        time.sleep(0.3)
    return "vpn_up" if vpn_up() else "no_vpn"


def route_is_ppp(route_output):
    """Маршрут (route -n get) идёт через ppp0? Чистая функция для selftest."""
    m = re.search(r"interface:\s*(\S+)", route_output or "")
    return bool(m) and m.group(1) == CORP_IF


def dns_route_via_ppp(servers):
    for srv in servers:
        if route_is_ppp(_run(["/sbin/route", "-n", "get", srv], timeout=3)):
            return True
    return False


def maybe_kick_routes(servers):
    """Туннель есть, а маршрута до корп. DNS через ppp0 нет — маршрутный демон
    завис/не пересобрал (наблюдалось 25.11.2026 после серии переподключений).
    Перезапускаем его, но не чаще KICK_MIN_INTERVAL и не раньше KICK_GRACE
    секунд после подъёма туннеля: штатная пересборка маршрутов занимает
    несколько секунд, и дёргать демон в этот момент вредно."""
    now = time.time()
    since = _state.get("vpn_up_since") or 0.0
    if not since:
        _state["vpn_up_since"] = now
        return
    if now - since < KICK_GRACE:
        return
    if now - _state.get("last_kick", 0.0) < KICK_MIN_INTERVAL:
        return
    if dns_route_via_ppp(servers):
        return
    _state["last_kick"] = now
    try:
        subprocess.run(["/bin/launchctl", "kickstart", "-k", ROUTES_DAEMON],
                       timeout=10, capture_output=True)
        log("маршрута до корп. DNS через %s нет — перезапустил %s"
            % (CORP_IF, ROUTES_DAEMON))
    except (OSError, subprocess.SubprocessError) as ex:
        log("kickstart %s: %s" % (ROUTES_DAEMON, type(ex).__name__))


def corp_established():
    """Есть ли установленные TCP-соединения в корп. подсети."""
    try:
        out = subprocess.run(["/usr/sbin/netstat", "-an", "-f", "inet"],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    for line in out.splitlines():
        if "ESTABLISHED" not in line:
            continue
        m = re.search(r"\s(\d+\.\d+\.\d+\.\d+)\.\d+\s+ESTABLISHED", line)
        if not m:
            continue
        ip = m.group(1)
        if ip.startswith("10.") or ip.startswith("192.168."):
            return True
    return False


def should_idle(now, last_activity, demand_mtime, established, idle=None,
                hold_until=0.0):
    """Пора гасить туннель? (чистая функция — для selftest)."""
    if idle is None:
        idle = IDLE
    if now < (hold_until or 0):
        return False          # ручное удержание (corp-vpn.sh start)
    last = max(last_activity, demand_mtime or 0)
    if established:
        return False
    return (now - last) >= idle


def hold_until():
    """Эпоха, до которой туннель держим принудительно (0 — нет удержания)."""
    try:
        with open(HOLD_FILE, encoding="utf-8") as f:
            return float(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0.0


def ppp_bytes():
    """Суммарные байты на ppp0 (in+out), None если интерфейса нет."""
    total = None
    for line in _run(["/usr/sbin/netstat", "-ib"]).splitlines():
        p = line.split()
        if len(p) < 10 or p[0] != CORP_IF:
            continue
        try:
            val = int(p[6]) + int(p[9])
        except (ValueError, IndexError):
            continue
        total = val if total is None else max(total, val)
    return total


def ppp_active(prev, cur, min_bytes=PPP_TRAFFIC_MIN):
    """Был ли заметный трафик по туннелю между тиками (чистая функция)."""
    return prev is not None and cur is not None and cur - prev >= min_bytes


def stop_vpn(reason):
    """Погасить туннель. Профилей может быть несколько (переключения
    vpn1..vpn4): гасим все подключённые, иначе «stop» оставляет живой чужой."""
    names = connected_profiles()
    if not names:
        return False
    log("idle: %s — отключаю %s" % (reason, ", ".join(names)))
    for name in names:
        try:
            subprocess.run(["/usr/sbin/scutil", "--nc", "stop", name],
                           timeout=15)
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        os.remove(DEMAND_FILE)
    except OSError:
        pass
    _state["ready_until"] = 0.0
    return True


def idle_loop(servers):
    prev_bytes = None
    while True:
        time.sleep(30)
        try:
            if not vpn_up():
                prev_bytes = None
                _state["vpn_up_since"] = 0.0
                continue
            if corp_direct_net(servers):
                prev_bytes = None
                continue
            # Живой трафик по туннелю (не только DNS) — тоже активность.
            cur_bytes = ppp_bytes()
            if prev_bytes is None:
                # Туннель только что появился (в т.ч. поднят вручную) —
                # даём ему полный IDLE, а не гасим сразу по старой метке.
                _state["last_activity"] = time.time()
            elif ppp_active(prev_bytes, cur_bytes):
                _state["last_activity"] = time.time()
            prev_bytes = cur_bytes
            dm = 0.0
            try:
                dm = os.path.getmtime(DEMAND_FILE)
            except OSError:
                pass
            if should_idle(time.time(), _state["last_activity"], dm,
                           corp_established(), hold_until=hold_until()):
                stop_vpn("нет корп. DNS-запросов и соединений %d с" % IDLE)
        except Exception as ex:  # демон не должен падать из-за одного тика
            log("idle loop: %s" % type(ex).__name__)


# ---------------------------------------------------------------- сервис ---
def handle_query(data, tcp=False):
    qname = parse_qname(data)
    servers = _SERVERS
    if not qname:
        return None
    if not zone_match(qname, _ZONES):
        return build_error(data, 5)  # REFUSED: не наша зона
    _state["last_activity"] = time.time()

    if not (vpn_up() or corp_direct_net(servers)):
        # Имена VPN-серверов резолвит сам dial (macOS, через системный
        # резолвер = через нас). Корп. DNS без туннеля недоступен, поэтому
        # такие имена отдаём обычному DNS и туннель из-за них не поднимаем.
        if is_bypass(qname, vpn_names()):
            resp = (forward_tcp if tcp else forward_udp)(
                data, public_dns_servers(servers))
            if resp is not None:
                return resp
            log_throttled("bypass", "нет публичного DNS для %s" % qname)
            return build_error(data, 2)

        ready = "no_vpn"
        if not dial_blocked():
            dial_async()
            ready = wait_ready(servers)
        if ready != "ready":
            if ready == "vpn_up":
                # Туннель есть, корп. DNS ещё не отвечает (пересборка
                # маршрутов). Публичным DNS тут отвечать нельзя: для
                # корп.-only имён это NXDOMAIN, который закэшируется.
                log("туннель есть, корп. DNS не готов: %s -> SERVFAIL" % qname)
                return build_error(data, 2)
            # Туннель поднять не удалось (cooldown после неудачи): публичные
            # имена корп. зон должны продолжать работать — отдаём ответ
            # обычного DNS, а не SERVFAIL.
            resp = (forward_tcp if tcp else forward_udp)(
                data, public_dns_servers(servers))
            # Пустой/NXDOMAIN-ответ публичного DNS для корп.-only имени
            # закэшировался бы надолго — в этом случае отдаём SERVFAIL,
            # чтобы клиент повторил запрос (и попал уже на поднятый туннель).
            if (resp is not None and dns_rcode(resp) == 0
                    and (dns_ancount(resp) or 0) > 0):
                log_throttled("fallback",
                              "туннель не готов, публичный DNS: %s" % qname)
                return resp
            log("нет готовности DNS за %.0f с: %s -> SERVFAIL" % (WAIT_READY, qname))
            return build_error(data, 2)

    resp = (forward_tcp if tcp else forward_udp)(data, servers)
    if resp is None:
        log("нет ответа корп. DNS: %s" % qname)
        return build_error(data, 2)
    return resp


def udp_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LISTEN_HOST, LISTEN_PORT))
    log("слушаю UDP %s:%d, зон: %d" % (LISTEN_HOST, LISTEN_PORT, len(_ZONES)))
    while True:
        try:
            data, addr = s.recvfrom(65535)
        except OSError:
            continue
        # Запрос, ждущий подъёма туннеля, занимает до WAIT_READY секунд —
        # обрабатываем параллельно, иначе остальные имена (в т.ч. серверы
        # VPN, которые резолвит сам dial) ждут в очереди и клиенты отваливаются
        # по таймауту (наблюдалось 25.11.2026).
        if not _slots.acquire(timeout=0.2):
            try:
                s.sendto(build_error(data, 2), addr)
            except OSError:
                pass
            continue
        threading.Thread(target=_udp_worker, args=(s, data, addr),
                         daemon=True).start()


def _udp_worker(sock, data, addr):
    try:
        resp = handle_query(data)
        if resp:
            sock.sendto(resp, addr)
    except Exception as ex:  # один запрос не должен ронять демон
        log("udp handler: %s" % type(ex).__name__)
    finally:
        _slots.release()


def tcp_client(conn):
    try:
        conn.settimeout(10)
        hdr = _recv_exact(conn, 2)
        if not hdr:
            return
        n = struct.unpack(">H", hdr)[0]
        data = _recv_exact(conn, n)
        if not data:
            return
        resp = handle_query(data, tcp=True)
        if resp:
            conn.sendall(struct.pack(">H", len(resp)) + resp)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def tcp_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((LISTEN_HOST, LISTEN_PORT))
    s.listen(16)
    while True:
        try:
            conn, _ = s.accept()
        except OSError:
            continue
        threading.Thread(target=tcp_client, args=(conn,), daemon=True).start()


_ZONES, _SERVERS = [], []
_EN0_MACS, _GW_MACS = list(FALLBACK_EN0_MACS), list(FALLBACK_GW_MACS)


def main():
    global _ZONES, _SERVERS, _EN0_MACS, _GW_MACS, IDLE
    ap = argparse.ArgumentParser(description="VPN on demand по DNS-запросам")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--once", metavar="NAME",
                    help="обработать один запрос и напечатать реакцию (отладка)")
    ap.add_argument("--zones", action="store_true",
                    help="напечатать зоны-триггеры из конфига (для install.sh)")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.zones:
        # Только то, что реально в конфиге: фолбэк здесь не нужен, иначе
        # установщик поставил бы резолверы для зон, которых в конфиге нет.
        zones = conf_zones(read_conf_text())
        if zones:
            print("\n".join(zones))
        return 0 if zones else 1

    trim_log()
    try:
        IDLE = int(conf_var("ONDEMAND_IDLE", str(IDLE)) or IDLE)
    except ValueError:
        pass
    _ZONES, _SERVERS = load_config()
    _EN0_MACS, _GW_MACS = load_macs()
    if args.once:
        qname = b"".join(bytes([len(p)]) + p.encode()
                         for p in args.once.split(".")) + b"\x00"
        pkt = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + qname \
            + struct.pack(">HH", 1, 1)
        resp = handle_query(pkt)
        print("ответ: %d байт, rcode=%s" % (
            len(resp or b""),
            (struct.unpack(">H", resp[2:4])[0] & 0xF) if resp else "-"))
        return 0

    log("===== START vpn-ondemand (idle=%ds, wait=%.0fs) =====" % (IDLE, WAIT_READY))
    threading.Thread(target=tcp_server, daemon=True).start()
    threading.Thread(target=idle_loop, args=(_SERVERS,), daemon=True).start()
    udp_server()
    return 0


# --------------------------------------------------------------- selftest ---
def selftest():
    passed = failed = 0

    def ck(name, cond):
        nonlocal passed, failed
        if cond:
            passed += 1
        else:
            failed += 1
            print("  FAIL %s" % name)

    ck("zones: из конфига",
       parse_zones_from_text('DOMAIN_SUFFIX=".tradesoft.ru .prj"')
       == ["tradesoft.ru", "prj"])
    ck("zones: нет переменной", parse_zones_from_text("X=1") == [])
    ck("zones: ONDEMAND_ZONES",
       parse_zones_from_text('ONDEMAND_ZONES="kyariz.com foo.ru"',
                             "ONDEMAND_ZONES") == ["kyariz.com", "foo.ru"])
    ck("dns: из конфига",
       parse_dns_from_text('DNS_HOSTS="192.168.0.210 192.168.0.220"')
       == ["192.168.0.210", "192.168.0.220"])

    ck("match: поддомен", zone_match("b24.tradesoft.ru", ["tradesoft.ru"]))
    ck("match: сама зона", zone_match("tradesoft.ru", ["tradesoft.ru"]))
    ck("match: чужой домен", not zone_match("notcorp.ru", ["tradesoft.ru"]))
    ck("match: похожий хвост",
       not zone_match("tradesoft.ru.evil.com", ["tradesoft.ru"]))
    ck("match: регистр", zone_match("B24.TRADESOFT.RU", ["tradesoft.ru"]))
    ck("match: точка в конце", zone_match("b24.tradesoft.ru.", ["tradesoft.ru"]))

    ck("macs: из конфига",
       parse_macs_from_text('CORP_WIFI_EN0_MACS="b6:be:0c:d5:9a:24 11:22:33:44:55:66"',
                            "CORP_WIFI_EN0_MACS")
       == ["b6:be:0c:d5:9a:24", "11:22:33:44:55:66"])
    ck("macs: нет переменной",
       parse_macs_from_text("X=1", "CORP_WIFI_EN0_MACS") == [])
    ck("mac: совпадение без регистра",
       mac_matches("B6:BE:0C:D5:9A:24", ["b6:be:0c:d5:9a:24"]))
    ck("mac: не совпадает",
       not mac_matches("3e:e9:15:74:f3:be", ["b6:be:0c:d5:9a:24"]))
    ck("mac: пусто", not mac_matches("", ["b6:be:0c:d5:9a:24"]))

    ck("ppp: трафик есть", ppp_active(1000, 1000 + 9000, 8192))
    ck("ppp: фоновый шум не считается", not ppp_active(1000, 1000 + 500, 8192))
    ck("ppp: первый тик без базы", not ppp_active(None, 5000, 8192))
    ck("ppp: интерфейс пропал", not ppp_active(5000, None, 8192))

    ck("route: через ppp0",
       route_is_ppp("  gateway: 192.168.160.1\n  interface: ppp0\n"))
    ck("route: через en0",
       not route_is_ppp("  gateway: 192.168.31.1\n  interface: en0\n"))
    ck("route: пусто", not route_is_ppp(""))

    scutil_dns = """DNS configuration

resolver #1
  search domain[0] : tradesoft.corp
  nameserver[0] : 192.168.31.1
  if_index : 14 (en0)

resolver #2
  domain   : tradesoft.ru
  nameserver[0] : 127.0.0.1
  port     : 5354

resolver #3
  domain   : local
  options  : mdns
  nameserver[0] : 224.0.0.251
  port     : 5353

resolver #4
  nameserver[0] : 192.168.0.210
"""
    ck("public dns: en0, без loopback/корп/mDNS",
       parse_public_dns(scutil_dns, ["192.168.0.210"]) == ["192.168.31.1"])
    ck("public dns: пустой вывод", parse_public_dns("") == [])

    nc_list = ('* (Disconnected)  BD3DD8DF-77F3-4001-A0C6-51ED1D1D4148 PPP --> '
               'L2TP "vpn4-ts" [PPP:L2TP]\n'
               '* (Connected)     520DA48B-8A47-42E0-9479-158B4A1B89CF VPN --> '
               'IKEv2 "Karing" [VPN:IKEv2]\n')
    ck("profiles: только PPP", parse_profiles(nc_list) == ["vpn4-ts"])
    ck("remote: имя хоста",
       parse_remote_address("  CommRemoteAddress : VPN4.tradesoft.ru\n")
       == "vpn4.tradesoft.ru")
    ck("remote: IP не резолвим",
       parse_remote_address("  CommRemoteAddress : 10.1.2.3\n") == "")
    ck("remote: нет поля", parse_remote_address("") == "")
    ck("bypass: точное имя",
       is_bypass("vpn4.tradesoft.ru", ["vpn4.tradesoft.ru"]))
    ck("bypass: поддомен",
       is_bypass("a.vpn4.tradesoft.ru", ["vpn4.tradesoft.ru"]))
    ck("bypass: чужое имя",
       not is_bypass("www.tradesoft.ru", ["vpn4.tradesoft.ru"]))
    ck("zones: conf_zones объединяет",
       conf_zones('DOMAIN_SUFFIX=".a.ru"\nONDEMAND_ZONES="b.com a.ru"')
       == ["a.ru", "b.com"])
    ck("zones: conf_zones без повторов",
       conf_zones('DOMAIN_SUFFIX=".a.ru .a.ru"') == ["a.ru"])

    nc_list2 = ('* (Connected) 1 PPP --> L2TP "vpn2-ts" [PPP:L2TP]\n'
                '* (Connected) 2 PPP --> L2TP "vpn4-ts" [PPP:L2TP]\n'
                '* (Disconnected) 3 PPP --> L2TP "vpn1-ts" [PPP:L2TP]\n'
                '* (Connected) 4 VPN --> IKEv2 "Karing" [VPN:IKEv2]\n')
    ck("profiles: все подключённые PPP",
       parse_connected_profiles(nc_list2) == ["vpn2-ts", "vpn4-ts"])
    ck("profiles: пустой вывод", parse_connected_profiles("") == [])
    ck("profiles: без дублей",
       parse_connected_profiles(nc_list2 + nc_list2) == ["vpn2-ts", "vpn4-ts"])

    ck("cooldown: свежий", cooldown_fresh(1000, 1100, 180))
    ck("cooldown: истёк", not cooldown_fresh(1000, 1200, 180))
    ck("cooldown: нет файла", not cooldown_fresh(None, 1200, 180))

    name = "b24.tradesoft.ru"
    q = struct.pack(">HHHHHH", 0xABCD, 0x0100, 1, 0, 0, 0) \
        + b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) \
        + b"\x00" + struct.pack(">HH", 1, 1)
    ck("parse: qname", parse_qname(q) == name)
    ck("parse: короткий пакет", parse_qname(b"\x00" * 5) is None)

    sf = build_error(q, 2)
    rf = build_error(q, 5)
    ck("rcode: SERVFAIL", dns_rcode(sf) == 2)
    ck("rcode: REFUSED", dns_rcode(rf) == 5)
    ck("rcode: пустой пакет", dns_rcode(b"") is None)
    ck("ancount: пустой ответ", dns_ancount(sf) == 0)
    ck("ancount: короткий пакет", dns_ancount(b"\x00\x01") is None)

    ck("servfail: id сохранён", sf[0:2] == q[0:2])
    ck("servfail: qr+rccode",
       struct.unpack(">H", sf[2:4])[0] & 0x8000
       and (struct.unpack(">H", sf[2:4])[0] & 0xF) == 2)
    ck("servfail: question сохранён", sf[12:] == q[12:])
    rf = build_error(q, 5)
    ck("refused: rcode 5", (struct.unpack(">H", rf[2:4])[0] & 0xF) == 5)

    # --- кэши горячего пути: на каждый DNS-запрос не должно быть процессов ---
    real_run = subprocess.run
    calls = []

    def fake_run(cmd, **kw):
        calls.append(list(cmd))
        if list(cmd)[:2] == ["/sbin/ifconfig", "-lu"]:
            return subprocess.CompletedProcess(cmd, 0, "en4\n", "")
        if list(cmd)[:2] == ["/usr/sbin/ipconfig", "getifaddr"]:
            return subprocess.CompletedProcess(cmd, 0, "192.168.128.50\n", "")
        if list(cmd)[:2] == ["/sbin/ifconfig", "ppp0"]:
            return subprocess.CompletedProcess(
                cmd, 0, "\tinet 10.0.0.1 --> 10.0.0.2 netmask 0xffffff00\n", "")
        return subprocess.CompletedProcess(cmd, 1, "", "")

    try:
        subprocess.run = fake_run
        for k in ("vpn_up", "corp_lan", "vpn_up_since"):
            _state.pop(k, None)
        ck("vpn_up: поднят", vpn_up() is True)
        n = len(calls)
        ck("vpn_up: повторно из кэша", vpn_up() is True and len(calls) == n)
        ck("vpn_up: force спрашивает снова",
           vpn_up(force=True) is True and len(calls) == n + 1)
        _state.pop("corp_lan", None)
        ck("corp_lan: находит 192.168.128.x", corp_lan() is True)
        n = len(calls)
        ck("corp_lan: повторно из кэша", corp_lan() is True and len(calls) == n)
        ck("corp_lan: force спрашивает снова",
           corp_lan(force=True) is True and len(calls) == n + 2)
        # Туннель пропал: vpn_up не должен врать дольше VPN_UP_TTL.
        _state["vpn_up"] = (True, 0.0)
        ck("vpn_up: истёкший кэш перепроверяется", vpn_up() is True)
        _state["corp_lan"] = (False, 0.0)
        ck("corp_lan: истёкший кэш перепроверяется", corp_lan() is True)
    finally:
        subprocess.run = real_run
        for k in ("vpn_up", "corp_lan", "vpn_up_since"):
            _state.pop(k, None)

    now = 1_000_000
    ck("idle: свежая активность — не гасим",
       not should_idle(now, now - 60, 0, False, 600))
    ck("idle: простой 10 мин — гасим",
       should_idle(now, now - 600, 0, False, 600))
    ck("idle: есть соединения — не гасим",
       not should_idle(now, now - 7200, 0, True, 600))
    ck("idle: свежий маркер спроса держит туннель",
       not should_idle(now, now - 7200, now - 120, False, 600))
    ck("idle: ручное удержание держит туннель",
       not should_idle(now, now - 7200, 0, False, 600, hold_until=now + 600))
    ck("idle: удержание истекло — гасим",
       should_idle(now, now - 7200, 0, False, 600, hold_until=now - 1))

    print("selftest: %d passed, %d failed" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
