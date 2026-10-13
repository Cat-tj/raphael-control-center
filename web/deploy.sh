#!/bin/bash
# Deploys Raphael Web to an always-on Linux box over SSH.
#
#   web/deploy.sh user@host [https-port]
#
# - runs the tests, extracts the collector + schema from the Swift sources
# - copies the app to ~/raphael-web/app on the host (config and data are never overwritten)
# - installs ~/.config/raphael-web/config.json from web/config.local.json only if none exists
# - (re)starts the systemd user service raphael-web (127.0.0.1 only, memory-capped)
# - publishes it on the tailnet with `tailscale serve` on https-port (default 8787)
#
# Rollback: systemctl --user disable --now raphael-web; sudo tailscale serve --https=<port> off
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${1:?usage: web/deploy.sh user@host [https-port]}
HTTPS_PORT=${2:-8787}

python3 web/extract.py
python3 -m unittest discover -s web/tests 2>&1 | tail -1 | grep -q '^OK' || { echo "✗ tests failed"; python3 -m unittest discover -s web/tests 2>&1 | tail -20; exit 1; }
echo "✓ tests"

ssh -o BatchMode=yes "$HOST" 'mkdir -p ~/raphael-web/app ~/.config/raphael-web ~/.config/systemd/user'
COPYFILE_DISABLE=1 tar --no-xattrs -C web -czf - server.py core.py workspace.py static build | ssh -o BatchMode=yes "$HOST" 'rm -rf ~/raphael-web/app.new && mkdir ~/raphael-web/app.new && tar -C ~/raphael-web/app.new -xzf - && rm -rf ~/raphael-web/app.old && { [ -d ~/raphael-web/app ] && mv ~/raphael-web/app ~/raphael-web/app.old; true; } && mv ~/raphael-web/app.new ~/raphael-web/app'
echo "✓ copied (previous version kept in ~/raphael-web/app.old)"

if [ -f web/config.local.json ]; then
  ssh -o BatchMode=yes "$HOST" '[ -f ~/.config/raphael-web/config.json ] || cat > ~/.config/raphael-web/config.json' < web/config.local.json
fi

ssh -o BatchMode=yes "$HOST" 'cat > ~/.config/systemd/user/raphael-web.service' <<'UNIT'
[Unit]
Description=Raphael Web (Control Center: monitor + workspace)
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 %h/raphael-web/app/server.py --config %h/.config/raphael-web/config.json
Restart=on-failure
RestartSec=5
# A guest on a busy box: never more than 30 % of one core, idle-priority I/O, capped memory
# (the collector it spawns inherits these limits).
Nice=10
CPUQuota=30%
IOSchedulingClass=idle
MemoryMax=200M
Environment=PYTHONUNBUFFERED=1
StandardOutput=append:%h/raphael-web/server.log
StandardError=append:%h/raphael-web/server.log

[Install]
WantedBy=default.target
UNIT

ssh -o BatchMode=yes "$HOST" "systemctl --user daemon-reload && systemctl --user enable raphael-web >/dev/null 2>&1; systemctl --user restart raphael-web && sleep 3 && systemctl --user is-active raphael-web && curl -fsS http://127.0.0.1:\$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser(\"~/.config/raphael-web/config.json\"))).get(\"port\",8790))')/healthz"
echo
echo "✓ service running"

ssh -o BatchMode=yes "$HOST" "sudo -n tailscale serve --bg --https=$HTTPS_PORT http://127.0.0.1:\$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser(\"~/.config/raphael-web/config.json\"))).get(\"port\",8790))') >/dev/null && tailscale serve status | grep -A1 ':$HTTPS_PORT'"
echo "✓ tailnet: https://<host>.<tailnet>.ts.net:$HTTPS_PORT"
