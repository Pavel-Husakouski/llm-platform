#!/usr/bin/env bash
# Приватный CA платформы и wildcard-сертификат *.llm.internal для nginx edge (deploy/edge).
# Ключ CA хранится на хосте k3s (${SECRETS_DIR}/edge-tls, как бэкап секретов) и в локальном
# каталоге .edge-tls (в git его нет, см. .gitignore). Сертификат nginx кладётся в Secret
# edge/edge-tls (type kubernetes.io/tls) — Argo CD его не отслеживает (нет в git), под edge
# монтирует по secretName. Let's Encrypt для .internal невозможен (нет публичного DNS), поэтому
# свой CA: его корень ca.crt надо один раз доверить на клиентах.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

namespace edge

umask 077
local_ca="$(cd "$(dirname "$0")/.." && pwd)/.edge-tls"
remote_ca="${SECRETS_DIR:-}/edge-tls"
mkdir -p "$local_ca"

# CA: сначала с хоста (k3s), затем локальный, иначе генерируем новый и кладём на хост.
if [ -n "${SECRETS_SSH:-}" ] && ssh "$SECRETS_SSH" "test -f '$remote_ca/ca.key' -a -f '$remote_ca/ca.crt'"; then
  ssh "$SECRETS_SSH" "cat '$remote_ca/ca.key'" > "$local_ca/ca.key"
  ssh "$SECRETS_SSH" "cat '$remote_ca/ca.crt'" > "$local_ca/ca.crt"
fi

if [ ! -s "$local_ca/ca.key" ] || [ ! -s "$local_ca/ca.crt" ]; then
  echo "генерирую приватный CA платформы"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$local_ca/ca.key" -out "$local_ca/ca.crt" \
    -subj "/CN=llm-platform-local-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  if [ -n "${SECRETS_SSH:-}" ]; then
    ssh "$SECRETS_SSH" "mkdir -p '$remote_ca'"
    cat "$local_ca/ca.key" | ssh "$SECRETS_SSH" "umask 077 && cat > '$remote_ca/ca.key'"
    cat "$local_ca/ca.crt" | ssh "$SECRETS_SSH" "umask 077 && cat > '$remote_ca/ca.crt'"
  fi
fi

# Wildcard-сертификат nginx на *.llm.internal (и голый llm.internal). В $tmp (из lib.sh) —
# он уже на trap-очистке.
openssl req -new -newkey rsa:2048 -nodes -keyout "$tmp/tls.key" -out "$tmp/server.csr" \
  -subj "/CN=*.llm.internal"
printf 'subjectAltName=DNS:*.llm.internal,DNS:llm.internal\n' > "$tmp/ext.cnf"
openssl x509 -req -in "$tmp/server.csr" \
  -CA "$local_ca/ca.crt" -CAkey "$local_ca/ca.key" \
  -set_serial "0x$(openssl rand -hex 8)" \
  -out "$tmp/tls.crt" -days 825 -sha256 -extfile "$tmp/ext.cnf"

$KUBECTL create secret tls edge-tls -n edge \
  --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "secret edge/edge-tls обновлён"
echo "корень CA: $local_ca/ca.crt"
echo "установите его как доверенный на устройствах LAN (или примите предупреждение браузера)"
