#!/usr/bin/env python3
"""
Local operator status page for COTI full node (non-technical friendly).
Binds inside the container on 0.0.0.0; map host to 127.0.0.1 only in docker-compose.
"""

from __future__ import annotations

import html
import json
import os
import socket
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8090"))
RPC_URL = os.environ.get("RPC_URL", "http://127.0.0.1:8545").rstrip("/")
RPC_TIMEOUT = float(os.environ.get("RPC_TIMEOUT", "8"))
FULLNODE_FQDN = (os.environ.get("FULLNODE_FQDN") or "").strip()
FULLNODE_EXT_IP = (os.environ.get("FULLNODE_EXT_IP") or "").strip()
NGINX_ENABLED = os.environ.get("NGINX_ENABLED", "false").lower() == "true"
FRPC_ENABLED = os.environ.get("FRPC_ENABLED", "false").lower() == "true"
FRPC_CUSTOM_DOMAIN = (os.environ.get("FRPC_CUSTOM_DOMAIN") or "").strip()
FRPS_SERVER_ADDR = (os.environ.get("FRPS_SERVER_ADDR") or os.environ.get("FRPS_SERVER_ADDR_1") or "").strip()
FRPS_SERVER_PORT = int(os.environ.get("FRPS_SERVER_PORT", "7000") or "7000")


def _normalize_dashboard_path(path: str) -> str:
    """Map /operator and /operator/... to paths seen when served without a reverse-proxy prefix."""
    if path.startswith("/operator"):
        rest = path[len("/operator") :]
        if not rest or rest == "/":
            return "/"
        return rest if rest.startswith("/") else f"/{rest}"
    return path


def _rpc(method: str, params: list[Any] | None = None) -> dict[str, Any]:
    body = json.dumps(
        {"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}
    ).encode()
    req = Request(
        f"{RPC_URL}/",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(req, timeout=RPC_TIMEOUT) as resp:
        raw = resp.read().decode()
    return json.loads(raw)


def _hex_to_int(h: str | None) -> int | None:
    if not h or not isinstance(h, str) or not h.startswith("0x"):
        return None
    try:
        return int(h, 16)
    except ValueError:
        return None


def collect_status() -> dict[str, Any]:
    out: dict[str, Any] = {
        "ts": int(time.time()),
        "rpc_url_internal": RPC_URL,
        "checks": [],
    }

    # --- JSON-RPC chain / node ---
    t0 = time.perf_counter()
    try:
        bn = _rpc("eth_blockNumber")
        latency_ms = round((time.perf_counter() - t0) * 1000, 1)
        err = bn.get("error")
        if err:
            out["checks"].append(
                {
                    "id": "rpc",
                    "label": "Node software responding",
                    "state": "bad",
                    "detail": str(err.get("message", err)),
                }
            )
            out["checks"].append(
                {
                    "id": "summary",
                    "label": "Overall",
                    "state": "bad",
                    "detail": "The node did not answer on the internal network. It may be stopped or still starting.",
                }
            )
            return out
        block = _hex_to_int(bn.get("result"))
        out["checks"].append(
            {
                "id": "rpc",
                "label": "Node software responding",
                "state": "ok",
                "detail": f"Last block number: {block if block is not None else bn.get('result')}. "
                f"Response time about {latency_ms} ms.",
            }
        )
    except (URLError, OSError, TimeoutError, json.JSONDecodeError, ValueError) as e:
        out["checks"].append(
            {
                "id": "rpc",
                "label": "Node software responding",
                "state": "bad",
                "detail": f"No answer from the node ({e!s}). Is Docker running and the full node container up?",
            }
        )
        out["checks"].append(
            {
                "id": "summary",
                "label": "Overall",
                "state": "bad",
                "detail": "Fix the node container first; other checks were skipped.",
            }
        )
        return out

    try:
        peers_raw = _rpc("net_peerCount")
        peers = _hex_to_int(peers_raw.get("result"))
        if peers is None:
            peer_detail = "Could not read peer count."
            peer_state = "warn"
        elif peers == 0:
            peer_detail = (
                "No peers yet. If the machine just started, wait a few minutes. "
                "If this stays at zero, check firewall rules for outbound/inbound on port 7400 (P2P)."
            )
            peer_state = "warn"
        else:
            peer_detail = f"Connected to {peers} peer(s). This is how the node talks to the network."
            peer_state = "ok"
        out["checks"].append(
            {
                "id": "peers",
                "label": "Connection to other nodes (P2P)",
                "state": peer_state,
                "detail": peer_detail,
            }
        )
    except (URLError, OSError, TimeoutError, json.JSONDecodeError, ValueError) as e:
        out["checks"].append(
            {
                "id": "peers",
                "label": "Connection to other nodes (P2P)",
                "state": "warn",
                "detail": f"Could not read peer count: {e!s}",
            }
        )

    try:
        sync = _rpc("eth_syncing")
        sr = sync.get("result")
        if sr is False:
            out["checks"].append(
                {
                    "id": "sync",
                    "label": "Blockchain sync",
                    "state": "ok",
                    "detail": "Caught up with the network (not actively syncing large history).",
                }
            )
        elif isinstance(sr, dict):
            cur = _hex_to_int(sr.get("currentBlock"))
            high = _hex_to_int(sr.get("highestBlock"))
            out["checks"].append(
                {
                    "id": "sync",
                    "label": "Blockchain sync",
                    "state": "warn",
                    "detail": f"Still syncing. Local block about {cur}, network head about {high}.",
                }
            )
        else:
            out["checks"].append(
                {
                    "id": "sync",
                    "label": "Blockchain sync",
                    "state": "warn",
                    "detail": "Sync status is unclear from the node.",
                }
            )
    except (URLError, OSError, TimeoutError, json.JSONDecodeError, ValueError) as e:
        out["checks"].append(
            {
                "id": "sync",
                "label": "Blockchain sync",
                "state": "warn",
                "detail": str(e),
            }
        )

    try:
        cid = _rpc("eth_chainId")
        chain = _hex_to_int(cid.get("result"))
        out["checks"].append(
            {
                "id": "chain",
                "label": "Network ID",
                "state": "ok",
                "detail": f"Chain ID (hex): {cid.get('result')}"
                + (f" — decimal {chain}" if chain is not None else ""),
            }
        )
    except (URLError, OSError, TimeoutError, json.JSONDecodeError, ValueError):
        pass

    try:
        ver = _rpc("web3_clientVersion")
        out["checks"].append(
            {
                "id": "client",
                "label": "Node version",
                "state": "ok",
                "detail": str(ver.get("result", "unknown")),
            }
        )
    except (URLError, OSError, TimeoutError, json.JSONDecodeError, ValueError):
        pass

    # --- DNS (name points to an address) ---
    if FULLNODE_FQDN:
        try:
            infos = socket.getaddrinfo(FULLNODE_FQDN, None, type=socket.SOCK_STREAM)
            ips = sorted({x[4][0] for x in infos})
            dns_detail = f"This machine is configured with hostname “{FULLNODE_FQDN}”. It resolves to: {', '.join(ips)}."
            if FULLNODE_EXT_IP and FULLNODE_EXT_IP in ips:
                dns_detail += f" That includes your configured public IP ({FULLNODE_EXT_IP})."
            elif FULLNODE_EXT_IP:
                dns_detail += (
                    f" Your configured public IP is {FULLNODE_EXT_IP}. "
                    "If you expect them to match, update DNS at your registrar or wait for DNS to update."
                )
            out["checks"].append(
                {
                    "id": "dns",
                    "label": "DNS name (hostname)",
                    "state": "ok",
                    "detail": dns_detail,
                }
            )
        except OSError as e:
            out["checks"].append(
                {
                    "id": "dns",
                    "label": "DNS name (hostname)",
                    "state": "bad",
                    "detail": f"The name “{FULLNODE_FQDN}” did not resolve ({e!s}). Check DNS settings.",
                }
            )
    else:
        out["checks"].append(
            {
                "id": "dns",
                "label": "DNS name (hostname)",
                "state": "warn",
                "detail": "No FULLNODE_FQDN is set in your environment, so DNS was not checked.",
            }
        )

    # --- HTTPS on your domain (only when Nginx + TLS is used) ---
    if NGINX_ENABLED and FULLNODE_FQDN:
        url = f"https://{FULLNODE_FQDN}/"
        try:
            ctx = ssl.create_default_context()
            req = Request(url, method="HEAD")
            with urlopen(req, timeout=12, context=ctx) as resp:
                code = resp.status
            ok_code = code < 500 or code in (401, 403, 405)
            out["checks"].append(
                {
                    "id": "https",
                    "label": "Website / SSL on your domain",
                    "state": "ok" if ok_code else "warn",
                    "detail": f"Got HTTP {code} from {url} (TLS certificate verified).",
                }
            )
        except HTTPError as e:
            ok_code = e.code < 500 or e.code in (401, 403, 405)
            out["checks"].append(
                {
                    "id": "https",
                    "label": "Website / SSL on your domain",
                    "state": "ok" if ok_code else "warn",
                    "detail": f"Server answered with HTTP {e.code} for {url}. TLS is working; path may differ.",
                }
            )
        except (URLError, OSError, TimeoutError) as e:
            out["checks"].append(
                {
                    "id": "https",
                    "label": "Website / SSL on your domain",
                    "state": "bad",
                    "detail": f"Could not open {url} ({e!s}). Check Nginx and certificates.",
                }
            )
    elif FRPC_ENABLED:
        out["checks"].append(
            {
                "id": "https",
                "label": "Public HTTPS on this machine",
                "state": "ok",
                "detail": "You are using the COTI tunnel (FRPC). HTTPS is handled at COTI’s gateway, not on this PC’s Nginx.",
            }
        )
    else:
        out["checks"].append(
            {
                "id": "https",
                "label": "Public HTTPS on your domain",
                "state": "warn",
                "detail": "Nginx with TLS is not enabled in your settings, so a public HTTPS check was skipped.",
            }
        )

    # --- FRPC gateway reachability ---
    if FRPC_ENABLED and FRPS_SERVER_ADDR:
        try:
            sock = socket.create_connection((FRPS_SERVER_ADDR, FRPS_SERVER_PORT), timeout=6)
            sock.close()
            out["checks"].append(
                {
                    "id": "frp_gateway",
                    "label": "COTI gateway (tunnel)",
                    "state": "ok",
                    "detail": f"This machine can reach {FRPS_SERVER_ADDR}:{FRPS_SERVER_PORT} (needed for the RPC tunnel).",
                }
            )
        except OSError as e:
            out["checks"].append(
                {
                    "id": "frp_gateway",
                    "label": "COTI gateway (tunnel)",
                    "state": "bad",
                    "detail": f"Cannot reach {FRPS_SERVER_ADDR}:{FRPS_SERVER_PORT} ({e!s}). "
                    "Allow outbound traffic in the firewall.",
                }
            )
        if FRPC_CUSTOM_DOMAIN:
            base = FRPC_CUSTOM_DOMAIN.rstrip("/")
            tunnel_url = f"https://{base}/rpc"
            try:
                ctx = ssl.create_default_context()
                req = Request(tunnel_url, method="HEAD")
                with urlopen(req, timeout=12, context=ctx) as resp:
                    code = resp.status
                ok_code = code < 500 or code in (401, 403, 405)
                out["checks"].append(
                    {
                        "id": "frp_domain",
                        "label": "Your tunnel web address",
                        "state": "ok" if ok_code else "warn",
                        "detail": f"Got HTTP {code} from {tunnel_url}",
                    }
                )
            except HTTPError as e:
                ok_code = e.code < 500 or e.code in (401, 403, 405)
                out["checks"].append(
                    {
                        "id": "frp_domain",
                        "label": "Your tunnel web address",
                        "state": "ok" if ok_code else "warn",
                        "detail": f"Got HTTP {e.code} from {tunnel_url}",
                    }
                )
            except (URLError, OSError, TimeoutError) as e:
                out["checks"].append(
                    {
                        "id": "frp_domain",
                        "label": "Your tunnel web address",
                        "state": "warn",
                        "detail": f"Could not verify {tunnel_url} ({e!s}). The tunnel may still be starting.",
                    }
                )

    # --- Overall heuristic ---
    bad = sum(1 for c in out["checks"] if c.get("state") == "bad")
    warns = sum(1 for c in out["checks"] if c.get("state") == "warn")
    if bad:
        summary = (
            f"{bad} problem(s) to fix. "
            "Read the red items below or contact COTI support with a screenshot."
        )
        sstate = "bad"
    elif warns:
        summary = (
            "No critical errors, but some yellow items need attention or patience (for example first sync)."
        )
        sstate = "warn"
    else:
        summary = "All automated checks passed."
        sstate = "ok"
    out["checks"].insert(
        0,
        {"id": "summary", "label": "Overall", "state": sstate, "detail": summary},
    )

    return out


INDEX_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>COTI Full Node — Status</title>
  <style>
    :root {
      --bg: #0f1419;
      --card: #1a2332;
      --text: #e7ecf3;
      --muted: #8b9bb4;
      --ok: #3ecf8e;
      --warn: #f5a623;
      --bad: #ff6b6b;
      --border: #2d3a4d;
    }
    * { box-sizing: border-box; }
    body {
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      margin: 0;
      padding: 1.25rem;
      line-height: 1.5;
      font-size: 1.05rem;
    }
    h1 { font-size: 1.5rem; font-weight: 700; margin: 0 0 0.25rem 0; }
    .sub { color: var(--muted); font-size: 0.95rem; margin-bottom: 1.25rem; }
    .banner {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 1rem 1.25rem;
      margin-bottom: 1rem;
    }
    .row {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 1rem 1.25rem;
      margin-bottom: 0.65rem;
    }
    .row h2 {
      margin: 0 0 0.35rem 0;
      font-size: 1.1rem;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .pill {
      display: inline-block;
      font-size: 0.75rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      padding: 0.2rem 0.55rem;
      border-radius: 999px;
    }
    .pill.ok { background: rgba(62, 207, 142, 0.2); color: var(--ok); }
    .pill.warn { background: rgba(245, 166, 35, 0.2); color: var(--warn); }
    .pill.bad { background: rgba(255, 107, 107, 0.2); color: var(--bad); }
    .detail { color: var(--muted); font-size: 0.95rem; margin: 0; }
    footer { color: var(--muted); font-size: 0.85rem; margin-top: 1.5rem; }
    .spin { display: inline-block; animation: r 0.9s linear infinite; }
    @keyframes r { to { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <h1>COTI Full Node — Status</h1>
  <p class="sub">Open this page on the same machine where the node runs. It refreshes every 15 seconds.</p>
  __EXTRA_SUB__
  <div id="app"><div class="banner"><span class="spin">⟳</span> Loading…</div></div>
  <footer>Problems persist? Save this page (or a screenshot) when asking for help.</footer>
  <script>
    function pill(state) {
      const t = state === 'ok' ? 'Good' : state === 'warn' ? 'Attention' : 'Problem';
      return '<span class="pill ' + state + '">' + t + '</span>';
    }
    function render(data) {
      const checks = data.checks || [];
      let html = '';
      for (const c of checks) {
        html += '<div class="row"><h2>' + pill(c.state) + ' ' + escapeHtml(c.label) + '</h2>';
        html += '<p class="detail">' + escapeHtml(c.detail) + '</p></div>';
      }
      document.getElementById('app').innerHTML = html;
    }
    function escapeHtml(s) {
      return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }
    function apiStatusUrl() {
      let p = window.location.pathname || '/';
      if (p.toLowerCase().endsWith('/index.html')) p = p.slice(0, -10) || '/';
      if (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
      if (p === '/' || p === '') return '/api/status';
      return p + '/api/status';
    }
    async function load() {
      try {
        const r = await fetch(apiStatusUrl(), { cache: 'no-store' });
        render(await r.json());
      } catch (e) {
        document.getElementById('app').innerHTML =
          '<div class="banner"><span class="pill bad">Problem</span> Could not load status.</div>';
      }
    }
    load();
    setInterval(load, 15000);
  </script>
</body>
</html>
"""


def _extra_sub_html() -> str:
    blocks: list[str] = []
    if NGINX_ENABLED and FULLNODE_FQDN:
        u = f"https://{FULLNODE_FQDN}/operator/"
        blocks.append(
            f'<p class="sub">HTTPS (this host): <a href="{html.escape(u)}">{html.escape(u)}</a></p>'
        )
    if FRPC_ENABLED and FRPC_CUSTOM_DOMAIN:
        u = f"https://{FRPC_CUSTOM_DOMAIN.rstrip('/')}/operator/"
        blocks.append(
            f'<p class="sub">HTTPS (COTI tunnel): <a href="{html.escape(u)}">{html.escape(u)}</a></p>'
        )
    return "\n  ".join(blocks)


def _index_html() -> str:
    return INDEX_HTML.replace("__EXTRA_SUB__", _extra_sub_html())


INDEX_HTML_BYTES = _index_html().encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        # Quiet default logging
        return

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        path = _normalize_dashboard_path(path)
        if path in ("/", "/index.html"):
            body = INDEX_HTML_BYTES
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/status":
            data = collect_status()
            body = json.dumps(data, indent=2).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404, "Not Found")


def main() -> None:
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"operator-dashboard listening on {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
