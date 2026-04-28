#!/usr/bin/env python3
"""
preflight-serve.py — Preflight Dashboard için lokal HTTP server.

Endpoint'ler:
  GET  /              → dashboard.html
  GET  /api/data      → son tarama JSON'u
  POST /api/run       → preflight.sh'ı re-run et, JSON'u güncelle
  POST /api/open      → Xcode'da dosya:satır aç (xed -l)
  POST /api/shutdown  → Server'ı düzgün kapat (.app çıkışı için)
"""
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

SCRIPT_DIR = Path(__file__).resolve().parent
# Brew install ile script libexec/'te yaşar. Repo kökü = caller'ın CWD'si.
REPO_ROOT = Path(os.environ.get("PREFLIGHT_REPO_ROOT") or os.getcwd()).resolve()
PREFLIGHT_SH = SCRIPT_DIR / "preflight-scan.sh"
INTROSPECT_PY = SCRIPT_DIR / "preflight-introspect.py"
DASHBOARD_HTML = SCRIPT_DIR / "dashboard.html"

# Cache her zaman repo kökünde (libexec read-only olabilir, CWD'ye yaz).
CACHE_DIR = REPO_ROOT / ".preflight"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
DATA_JSON = CACHE_DIR / "data.json"

PORT = int(os.environ.get("PREFLIGHT_PORT", "7474"))


def run_preflight(extra_args=None, target=None, config=None):
    """preflight.sh'ı --json ile çalıştırır.
    target/config verildiyse --target/--config flag'leri eklenir."""
    cmd = [str(PREFLIGHT_SH), "--json", str(DATA_JSON)]
    if target:
        cmd.extend(["--target", target])
    if config:
        cmd.extend(["--config", config])
    if extra_args:
        cmd.extend(extra_args)
    start = time.time()
    proc = subprocess.run(
        cmd, cwd=str(REPO_ROOT),
        capture_output=True, text=True, timeout=300,
    )
    return {
        "exitCode": proc.returncode,
        "durationMs": int((time.time() - start) * 1000),
        "stderr": proc.stderr[-2000:] if proc.stderr else "",
    }


def run_introspect(no_cache=False):
    """preflight-introspect.py'yi çağır, JSON döner."""
    cmd = [sys.executable, str(INTROSPECT_PY)]
    if no_cache:
        cmd.append("--no-cache")
    proc = subprocess.run(
        cmd, cwd=str(REPO_ROOT),
        capture_output=True, text=True, timeout=180,
    )
    if proc.returncode != 0:
        try:
            return json.loads(proc.stdout) if proc.stdout else {"error": proc.stderr[-500:]}
        except json.JSONDecodeError:
            return {"error": proc.stderr[-500:] or proc.stdout[-500:]}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        return {"error": f"introspect JSON parse: {e}"}


def _resolve_repo_path(file_str):
    """Verilen göreli yolu repo köküne göre çöz, repo dışına çıkışı engelle."""
    if not file_str:
        return None
    p = (REPO_ROOT / file_str).resolve()
    try:
        p.relative_to(REPO_ROOT.resolve())
    except ValueError:
        return None  # path traversal şüphesi
    return p


def open_in_xcode(file_str, line):
    """xed -l <line> <file> ile Xcode'da aç."""
    p = _resolve_repo_path(file_str)
    if p is None or not p.exists():
        return {"ok": False, "error": f"Dosya bulunamadı: {file_str}"}
    cmd = ["xed"]
    if line and str(line).isdigit():
        cmd += ["-l", str(line)]
    cmd.append(str(p))
    try:
        subprocess.run(cmd, check=False, timeout=10)
        return {"ok": True, "opened": str(p), "line": line}
    except Exception as e:
        return {"ok": False, "error": str(e)}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write(f"  {self.command} {self.path}\n")

    def _send(self, status, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        try:
            raw = self.rfile.read(length).decode("utf-8")
            return json.loads(raw)
        except Exception:
            return {}

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html", "/dashboard"):
            try:
                html = DASHBOARD_HTML.read_bytes()
                self._send(200, html, "text/html; charset=utf-8")
            except FileNotFoundError:
                self._send(500, "dashboard.html bulunamadı", "text/plain; charset=utf-8")
            return

        if path == "/api/data":
            if not DATA_JSON.exists():
                run_preflight()
            try:
                data = DATA_JSON.read_bytes()
                self._send(200, data)
            except FileNotFoundError:
                self._send(404, {"error": "Veri yok"})
            return

        if path == "/api/health":
            self._send(200, {"ok": True, "xed": shutil.which("xed") is not None})
            return

        if path == "/api/project":
            no_cache = urlparse(self.path).query == "refresh=1"
            data = run_introspect(no_cache=no_cache)
            self._send(200 if "error" not in data else 500, data)
            return

        self._send(404, {"error": "Not found: " + path})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._read_json()

        if path == "/api/run":
            target = body.get("target") or None
            config = body.get("config") or None
            try:
                result = run_preflight(target=target, config=config)
                if result["exitCode"] not in (0, 1):
                    self._send(500, {"error": "preflight.sh fail", **result})
                    return
                self._send(200, result)
            except subprocess.TimeoutExpired:
                self._send(504, {"error": "preflight.sh timeout (300s)"})
            except Exception as e:
                self._send(500, {"error": str(e)})
            return

        if path == "/api/open":
            r = open_in_xcode(body.get("file"), body.get("line"))
            self._send(200 if r.get("ok") else 400, r)
            return

        if path == "/api/shutdown":
            self._send(200, {"ok": True, "message": "Sunucu kapatılıyor."})
            # Response gittikten sonra kapat
            def _stop():
                time.sleep(0.2)
                self.server.shutdown()
            threading.Thread(target=_stop, daemon=True).start()
            return

        self._send(404, {"error": "Not found: " + path})


class ReusableTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    print(f"╔════════════════════════════════════════════════════════════╗")
    print(f"║       YK Preflight Dashboard                               ║")
    print(f"╚════════════════════════════════════════════════════════════╝")
    print(f"  Repo  : {REPO_ROOT}")
    print(f"  URL   : http://localhost:{PORT}")
    print(f"  xed   : {'✓' if shutil.which('xed') else '✗ (Xcode aç devre dışı)'}")
    print(f"  Çıkış : Ctrl+C ya da dashboard'da Çıkış butonu")
    print()

    if not PREFLIGHT_SH.exists():
        print(f"HATA: {PREFLIGHT_SH} bulunamadı.", file=sys.stderr)
        sys.exit(1)

    try:
        with ReusableTCPServer(("127.0.0.1", PORT), Handler) as httpd:
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n  Sunucu kapatıldı.")


if __name__ == "__main__":
    main()
