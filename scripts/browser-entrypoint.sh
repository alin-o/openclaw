#!/usr/bin/env bash
set -euo pipefail

export DISPLAY=:1
export HOME=/tmp/openclaw-home
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"

CDP_PORT="${OPENCLAW_BROWSER_CDP_PORT:-${CLAWDBOT_BROWSER_CDP_PORT:-9222}}"
VNC_PORT="${OPENCLAW_BROWSER_VNC_PORT:-${CLAWDBOT_BROWSER_VNC_PORT:-5900}}"
NOVNC_PORT="${OPENCLAW_BROWSER_NOVNC_PORT:-${CLAWDBOT_BROWSER_NOVNC_PORT:-6080}}"
ENABLE_NOVNC="${OPENCLAW_BROWSER_ENABLE_NOVNC:-${CLAWDBOT_BROWSER_ENABLE_NOVNC:-1}}"
HEADLESS="${OPENCLAW_BROWSER_HEADLESS:-${CLAWDBOT_BROWSER_HEADLESS:-0}}"

mkdir -p "${HOME}" "${HOME}/.chrome" "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}"

Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &

if [[ "${HEADLESS}" == "1" ]]; then
  CHROME_ARGS=(
    "--headless=new"
    "--disable-gpu"
  )
else
  CHROME_ARGS=()
fi

if [[ "${CDP_PORT}" -ge 65535 ]]; then
  CHROME_CDP_PORT="$((CDP_PORT - 1))"
else
  CHROME_CDP_PORT="$((CDP_PORT + 1))"
fi

CHROME_ARGS+=(
  "--remote-debugging-address=127.0.0.1"
  "--remote-debugging-port=${CHROME_CDP_PORT}"
  "--user-data-dir=${HOME}/.chrome"
  "--no-first-run"
  "--no-default-browser-check"
  "--disable-dev-shm-usage"
  "--disable-background-networking"
  "--disable-features=TranslateUI"
  "--disable-breakpad"
  "--disable-crash-reporter"
  "--metrics-recording-only"
  "--no-sandbox"
)

chromium "${CHROME_ARGS[@]}" about:blank &

for _ in $(seq 1 50); do
  if curl -sS --max-time 1 "http://127.0.0.1:${CHROME_CDP_PORT}/json/version" >/dev/null; then
    break
  fi
  sleep 0.1
done

# Create a Python proxy to rewrite Host headers (fix for Chrome rejecting non-IP Host headers)
cat <<'EOF' > /tmp/browser_proxy.py
import socket
import threading
import os
import select
import sys

# Get ports from environment (exported by bash script)
try:
    LISTEN_PORT = int(os.environ.get("CDP_PORT", "9222"))
    TARGET_PORT = int(os.environ.get("CHROME_CDP_PORT", "9223"))
except ValueError:
    sys.exit(1)

TARGET_HOST = "127.0.0.1"

def handle_client(client_socket):
    remote_socket = None
    try:
        remote_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote_socket.connect((TARGET_HOST, TARGET_PORT))
        
        # Read the first chunk from client to check/rewrite headers
        client_data = client_socket.recv(8192)
        if not client_data:
            return

        client_host_header = ""
        
        # 1. Rewrite Request (Client -> Browser)
        try:
            text = client_data.decode('utf-8', errors='ignore')
            if "HTTP/" in text and "Host:" in text:
                lines = text.split('\r\n')
                new_lines = []
                for line in lines:
                    if line.lower().startswith('host:'):
                        # Capture original Host header to use in response rewrite
                        client_host_header = line.split(':', 1)[1].strip()
                        # Rewrite Host to satisfy Chrome
                        new_lines.append(f'Host: {TARGET_HOST}:{TARGET_PORT}')
                    else:
                        new_lines.append(line)
                
                rewritten_data = '\r\n'.join(new_lines).encode('utf-8')
                remote_socket.sendall(rewritten_data)
            else:
                remote_socket.sendall(client_data)
        except Exception:
             remote_socket.sendall(client_data)

        # 2. Rewrite Response (Browser -> Client)
        # We need to catch the first chunk of the response to rewrite "webSocketDebuggerUrl"
        # identifying 127.0.0.1:<target_port> and replacing it with the client's requested Host
        
        # Use lists to act as mutable references for the select loop
        sockets = [client_socket, remote_socket]
        
        while True:
            readable, _, _ = select.select(sockets, [], [])
            
            if client_socket in readable:
                data = client_socket.recv(4096)
                if not data: break
                remote_socket.sendall(data)
                
            if remote_socket in readable:
                data = remote_socket.recv(4096)
                if not data: break
                
                # Simple heuristic: if this looks like a JSON response containing the internal URL
                # default client_host_header if empty (e.g. non-http)
                target_str = f"{TARGET_HOST}:{TARGET_PORT}"
                if client_host_header and target_str.encode() in data:
                     # Replace 127.0.0.1:9223 with browser:9222 (or whatever host the client used)
                     # limit count=1 to be safe, though global replace is likely fine for this small json
                     data = data.replace(target_str.encode(), client_host_header.encode())
                
                client_socket.sendall(data)

    except Exception:
        pass
    finally:
        try: client_socket.close()
        except: pass
        try: 
            if remote_socket: remote_socket.close()
        except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', LISTEN_PORT))
    server.listen(10)
    print(f"Proxy listening on {LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}")
    
    while True:
        client, _ = server.accept()
        t = threading.Thread(target=handle_client, args=(client,))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    main()
EOF

# Export variables for the python script
export CDP_PORT
export CHROME_CDP_PORT

python3 -u /tmp/browser_proxy.py &

if [[ "${ENABLE_NOVNC}" == "1" && "${HEADLESS}" != "1" ]]; then
  x11vnc -display :1 -rfbport "${VNC_PORT}" -shared -forever -nopw -localhost &
  websockify --web /usr/share/novnc/ "${NOVNC_PORT}" "localhost:${VNC_PORT}" &
fi

wait -n