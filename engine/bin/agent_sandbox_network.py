import base64
import fcntl
import ipaddress
import os
import select
import shutil
import socket
import ssl
import struct
import subprocess
import threading
import urllib.parse


PROVIDER_HOSTS = {
    "codex": {"api.openai.com", "auth.openai.com", "chatgpt.com", "codex-cloud-environments.chatgpt.com"},
    "claude": {"api.anthropic.com"},
    "zcode": {"api.z.ai", "api.bigmodel.cn", "open.bigmodel.cn"},
}
PROXY_VARS = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")


def configure_environment(env):
    for name in PROXY_VARS + ("NO_PROXY", "no_proxy"):
        env.pop(name, None)
    env.update({"HTTP_PROXY": "http://127.0.0.1:3128", "HTTPS_PROXY": "http://127.0.0.1:3128",
                "ALL_PROXY": "http://127.0.0.1:3128", "http_proxy": "http://127.0.0.1:3128",
                "https_proxy": "http://127.0.0.1:3128", "all_proxy": "http://127.0.0.1:3128",
                "NO_PROXY": "", "no_proxy": ""})
    return env


def host_proxy():
    for name in ("https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"):
        value = os.environ.get(name, "")
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme in {"http", "https"} and parsed.hostname:
            return parsed
        if value:
            raise RuntimeError("sandbox network broker requires an HTTP or HTTPS host proxy")
    return None


def connect_upstream(host, port):
    proxy = host_proxy()
    if proxy is None:
        for family, kind, protocol, _, address in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM):
            if not ipaddress.ip_address(address[0].split("%", 1)[0]).is_global:
                continue
            upstream = socket.socket(family, kind, protocol)
            try:
                upstream.settimeout(30)
                upstream.connect(address)
                upstream.settimeout(None)
                return upstream, None
            except OSError:
                upstream.close()
        raise OSError("provider host did not resolve to a reachable public address")
    upstream = socket.create_connection((proxy.hostname, proxy.port or (443 if proxy.scheme == "https" else 80)), timeout=30)
    if proxy.scheme == "https":
        upstream = ssl.create_default_context().wrap_socket(upstream, server_hostname=proxy.hostname)
    target = f"{host}:{port}"
    headers = [f"CONNECT {target} HTTP/1.1", f"Host: {target}", "Proxy-Connection: Keep-Alive"]
    if proxy.username is not None:
        credentials = f"{urllib.parse.unquote(proxy.username)}:{urllib.parse.unquote(proxy.password or '')}".encode()
        headers.append("Proxy-Authorization: Basic " + base64.b64encode(credentials).decode())
    upstream.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())
    response = read_headers(upstream)
    if not response.startswith((b"HTTP/1.0 200", b"HTTP/1.1 200")):
        upstream.close()
        raise OSError(response.split(b"\r\n", 1)[0].decode("ascii", "replace"))
    return upstream, response


def read_headers(connection):
    result = bytearray()
    while len(result) < 16384 and not result.endswith(b"\r\n\r\n"):
        part = connection.recv(1)
        if not part:
            break
        result.extend(part)
    return bytes(result)


def relay(left, right):
    peers = {left: right, right: left}
    open_sockets = {left, right}
    while open_sockets:
        readable, _, _ = select.select([left, right], [], [], 60)
        if not readable:
            continue
        for source in readable:
            target = peers[source]
            data = source.recv(65536)
            if not data:
                open_sockets.discard(source)
                try:
                    target.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
            else:
                target.sendall(data)


def request_target(request):
    first = request.split(b"\r\n", 1)[0].decode("ascii", "replace").split()
    if len(first) < 2 or first[0].upper() != "CONNECT":
        return "", 0
    authority = urllib.parse.urlsplit("//" + first[1])
    try:
        port = authority.port or 443
    except ValueError:
        return "", 0
    return authority.hostname or "", port


def proxy_connection(connection, path):
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        peer.connect(path)
        relay(connection, peer)
    except OSError:
        try:
            connection.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        except OSError:
            pass
    finally:
        connection.close()
        peer.close()


def proxy_server():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 3128))
    listener.listen(64)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=proxy_connection, args=(connection, "/run/zf-agent/proxy.sock"), daemon=True).start()


def set_loopback_up():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as control:
        request = struct.pack("16sH14s", b"lo", 0, b"")
        result = fcntl.ioctl(control.fileno(), 0x8913, request)
        flags = struct.unpack("16sH14s", result)[1] | 1
        fcntl.ioctl(control.fileno(), 0x8914, struct.pack("16sH14s", b"lo", flags, b""))


def start_worker_proxy():
    set_loopback_up()
    pid = os.fork()
    if pid == 0:
        try:
            proxy_server()
        finally:
            os._exit(0)
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", 3128), timeout=0.1):
                return
        except OSError:
            threading.Event().wait(0.02)
    raise RuntimeError("sandbox network proxy did not start")


class ProxyBroker:
    def __init__(self, stage, provider):
        self.path = str(stage / "proxy.sock")
        self.provider = provider
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        os.chmod(self.path, 0o600)
        self.server.listen(64)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def handle(self, connection):
        upstream = None
        try:
            request = read_headers(connection)
            host, port = request_target(request)
            if port != 443 or host not in PROVIDER_HOSTS[self.provider]:
                connection.sendall(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
                return
            upstream, response = connect_upstream(host, port)
            connection.sendall(response or b"HTTP/1.1 200 Connection Established\r\n\r\n")
            relay(connection, upstream)
        except OSError:
            try:
                connection.sendall(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
        finally:
            connection.close()
            if upstream is not None:
                upstream.close()

    def serve(self):
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def close(self):
        self.server.close()
        self.thread.join(timeout=2)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


def run(command, cwd, stage, provider):
    broker = ProxyBroker(stage, provider)
    try:
        unshare = shutil.which("unshare")
        if not unshare:
            raise RuntimeError("unshare is required for the worker sandbox")
        environment = {"PATH": "/usr/bin:/bin", "HOME": "/tmp/worker", "LANG": "C.UTF-8"}
        return subprocess.run([unshare, "--user", "--map-root-user", "--mount", "--net", "--pid", "--fork", "--kill-child", "--mount-proc", *command], cwd=cwd, env=environment)
    finally:
        broker.close()
