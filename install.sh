#!/usr/bin/env bash
# Install nginx + certbot and the privileged b580-proxy helper.
#
#   sudo ./install.sh
#
# Safe to run again.  It does not enable the proxy or obtain a certificate;
# the B580-ai panel (or `b580-proxy apply`) does that once a DNS name points
# at this machine and port 80 is forwarded.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -- "$0" "$@"
fi

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REAL_USER=${SUDO_USER:-}
EXTRA_PORTS=()

usage() {
  cat <<EOF
Usage: sudo $0 [--user NAME] [--ports "443 8443"]

  --user NAME       user allowed to run b580-proxy through sudo
                    (default: \$SUDO_USER, otherwise the owner of this checkout)
  --ports "P P"     extra TCP ports to allow in ufw when ufw is active
                    (default: 80 443 8443)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) REAL_USER=${2:?}; shift 2 ;;
    --ports) read -r -a EXTRA_PORTS <<< "${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$REAL_USER" ]]; then
  REAL_USER=$(stat -c '%U' "$ROOT")
fi
if ! [[ "$REAL_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "invalid user name: $REAL_USER" >&2
  exit 1
fi
if ! id "$REAL_USER" >/dev/null 2>&1; then
  echo "no such user: $REAL_USER" >&2
  exit 1
fi

echo "==> Installing nginx and certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nginx certbot openssl

echo "==> Installing b580-proxy helper"
install -d -m 0755 /usr/local/libexec
install -m 0755 "$ROOT/bin/b580-proxy" /usr/local/libexec/b580-proxy
install -m 0755 "$ROOT/proxy" /usr/local/bin/b580-proxy

install -d -m 0750 /etc/b580-proxy
install -d -m 0755 /etc/nginx/b580-proxy
install -d -m 0755 /var/www/b580-proxy
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/sudoers.d/b580-proxy <<EOF
# Let the B580-ai panel control nginx/certbot through this one fixed helper.
$REAL_USER ALL=(root) NOPASSWD: /usr/local/libexec/b580-proxy
EOF
chmod 0440 /etc/sudoers.d/b580-proxy
visudo -cf /etc/sudoers.d/b580-proxy >/dev/null

cat > /etc/letsencrypt/renewal-hooks/deploy/b580-proxy-reload <<'EOF'
#!/bin/sh
# Reload nginx after certbot renews a certificate.  If the proxy is disabled,
# nginx is intentionally stopped and there is nothing to reload.
set -eu
if systemctl is-active --quiet nginx; then
  nginx -t && systemctl reload nginx
fi
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/b580-proxy-reload

echo "==> Enabling the certbot renewal timer"
if systemctl list-unit-files --type=timer 2>/dev/null | grep -q '^certbot.timer'; then
  systemctl enable --now certbot.timer
else
  echo "warning: certbot.timer not found; check /etc/cron.d/certbot" >&2
fi

echo "==> Configuring nginx"
# The B580 proxy owns nginx on this machine.  Keep Ubuntu's default site
# available in sites-available so it can be restored by hand, but stop it
# from answering on port 80.
rm -f /etc/nginx/sites-enabled/default
nginx -t
if [[ -e /etc/nginx/sites-enabled/b580-proxy.conf ]]; then
  # Re-running the installer must not interrupt an enabled proxy.
  systemctl enable nginx >/dev/null 2>&1 || true
else
  systemctl disable --now nginx >/dev/null 2>&1 || true
fi

echo "==> Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ports=("${EXTRA_PORTS[@]}")
  if [[ ${#ports[@]} -eq 0 ]]; then
    ports=(80 443 8443)
  fi
  for port in "${ports[@]}"; do
    ufw allow "${port}/tcp" >/dev/null
    echo "    ufw allowed ${port}/tcp"
  done
else
  echo "    ufw is inactive; no firewall rules changed"
fi

cat <<EOF

b580-proxy is installed.

The proxy is not enabled yet.  Open the B580-ai panel (http://localhost:9090),
fill in Public access, and press "Save & enable".  Or from a shell:

  b580-proxy apply --domain b580.example.com --email you@example.com
  b580-proxy status

Before Let's Encrypt can issue a certificate:
  * the domain must resolve to this machine's public IP;
  * TCP port 80 must be forwarded to this machine for HTTP-01;
  * the two public ports (default 443 and 8443) must be forwarded too.

Disable it at any time with:

  b580-proxy disable          # or ./proxy down from B580-ai
EOF
