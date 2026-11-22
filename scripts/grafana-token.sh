#!/usr/bin/env bash
# Токен Grafana для заливки дашбордов проекта по API: grafana-token.sh <name>.
#   1. папка <name> (uid = <name>);
#   2. service account <name> с ролью Viewer и правом Edit только на эту папку: проект меняет
#      свои дашборды, но не чужие;
#   3. токен service account, сохраняется в Secret monitoring/grafana-token-<name>.
# Если секрет уже есть, новый токен не выпускается, печатается сохранённый. Новый токен:
# удалить секрет и запустить снова (старый токен остаётся в Grafana, отзывается в UI).
# Работает снаружи кластера через NodePort: адрес GRAFANA_URL задаёт make по TARGET.
set -euo pipefail

name=${1:?usage: grafana-token.sh <name>}

GRAFANA_URL=${GRAFANA_URL:-http://localhost:13030}

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NAME=$name: нужны a-z, 0-9 и -"

secret=grafana-token-$name
if exists monitoring "$secret"; then
  echo "токен $name уже есть (Secret monitoring/$secret), новый не выпускается" >&2
  get monitoring "$secret" GRAFANA_TOKEN
  echo
  exit 0
fi

# Basic auth admin из grafana-admin, заголовком из файла: пароль не виден в ps.
printf 'authorization: Basic %s\n' \
  "$(printf '%s:%s' "$(get monitoring grafana-admin admin-user)" \
    "$(get monitoring grafana-admin admin-password)" | base64 -w0)" > "$tmp/auth"

# grafana <method> <path> [json]: запрос к API, ответ в stdout. Код ответа — в $tmp/code.
grafana() {
  local out=$tmp/grafana.out args=()
  [ $# -ge 3 ] && { printf '%s' "$3" > "$tmp/body.json"; args=(--data-binary @"$tmp/body.json"); }
  curl -sS -o "$out" -w '%{http_code}' -X "$1" "$GRAFANA_URL$2" -H @"$tmp/auth" \
    -H 'content-type: application/json' "${args[@]}" > "$tmp/code" \
    || die "Grafana $GRAFANA_URL недоступна"
  cat "$out"
}
code() { cat "$tmp/code"; }
ok() { [ "$(code)" = 200 ] || [ "$(code)" = 201 ] || die "Grafana $1 ответила $(code): $(cat "$tmp/grafana.out")"; }

curl -sf "$GRAFANA_URL/api/health" >/dev/null || die "Grafana на $GRAFANA_URL не отвечает"

grafana GET "/api/folders/$name" >/dev/null
if [ "$(code)" = 404 ]; then
  grafana POST /api/folders "$(jq -n --arg n "$name" '{uid: $n, title: $n}')" >/dev/null
  ok "POST /api/folders"
  echo "папка $name создана" >&2
else
  ok "GET /api/folders/$name"
fi

sa_id=$(grafana GET "/api/serviceaccounts/search?query=$name" \
  | jq -r --arg n "$name" '.serviceAccounts[] | select(.name == $n) | .id')
ok "GET /api/serviceaccounts/search"
if [ -z "$sa_id" ]; then
  sa_id=$(grafana POST /api/serviceaccounts "$(jq -n --arg n "$name" '{name: $n, role: "Viewer"}')" \
    | jq -er .id) || die "Grafana: service account $name не создан: $(cat "$tmp/grafana.out")"
  echo "service account $name создан" >&2
fi

grafana POST "/api/access-control/folders/$name/users/$sa_id" '{"permission": "Edit"}' >/dev/null
ok "права на папку $name"

token=$(grafana POST "/api/serviceaccounts/$sa_id/tokens" \
  "$(jq -n --arg n "$name-$(date +%Y%m%d%H%M%S)" '{name: $n}')" | jq -er .key) \
  || die "Grafana: токен не выпущен: $(cat "$tmp/grafana.out")"

apply monitoring "$secret" "GRAFANA_TOKEN=$token" "GRAFANA_FOLDER_UID=$name" >&2
echo "$token"
