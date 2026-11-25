# Общие функции скриптов платформы, подключается через source. Секреты передаются файлами во
# временном каталоге $tmp, а не аргументами: не видны в ps.
# shellcheck shell=bash

KUBECTL=${KUBECTL:-kubectl}

tmp=$(mktemp -d)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

rand() { openssl rand -hex "$1"; }

die() { echo "$*" >&2; exit 1; }

namespace() {
  $KUBECTL create namespace "$1" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
}

exists() { $KUBECTL -n "$1" get secret "$2" >/dev/null 2>&1; }

# get <ns> <secret> <key>: значение ключа из существующего секрета.
get() {
  $KUBECTL -n "$1" get secret "$2" -o "go-template={{index .data \"$3\" | base64decode}}"
}

# apply <ns> <secret> <key>=<value>...: создаёт или обновляет секрет.
apply() {
  local ns=$1 name=$2 dir pair
  shift 2
  dir=$(mktemp -d "$tmp/secret.XXXX")
  for pair in "$@"; do printf '%s' "${pair#*=}" > "$dir/${pair%%=*}"; done
  $KUBECTL -n "$ns" create secret generic "$name" --from-file="$dir" --dry-run=client -o yaml \
    | $KUBECTL apply -f - >/dev/null
  echo "secret $ns/$name"
}

# once <ns> <secret> <key>=<value>...: создаёт секрет, только если его ещё нет.
once() {
  if exists "$1" "$2"; then echo "secret $1/$2 уже есть"; else apply "$@"; fi
}

# passwords <ns> <secret> <key>...: секрет ровно с этими ключами; у ключей, которых ещё нет,
# случайное значение, существующие не меняются. Так новый пользователь получает пароль, а
# старые пароли остаются.
passwords() {
  local ns=$1 name=$2 k v pairs=()
  shift 2
  for k in "$@"; do
    v=''
    if exists "$ns" "$name"; then v=$(field "$ns" "$name" "$k"); fi
    pairs+=("$k=${v:-$(rand 20)}")
  done
  apply "$ns" "$name" "${pairs[@]}"
}

# field <ns> <secret> <key>: значение ключа или пустая строка, если ключа нет.
field() {
  $KUBECTL -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 -d
}

# Бэкап секретов платформы на хосте k3s: SECRETS_SSH (ssh-адрес), SECRETS_DIR (каталог, его
# создают make k3s-install и k3s-storage). Без SECRETS_SSH (kind) — ничего не делают.
# Секреты платформы — Opaque в llm, langfuse, monitoring, platform и keycloak, кроме созданных
# чартами (с меткой app.kubernetes.io/instance): их Argo CD создаст сам.
SECRETS_FILE=${SECRETS_DIR:-/srv/llm-platform/secrets}/secrets.json

backup_secrets() {
  [ -n "${SECRETS_SSH:-}" ] || return 0
  local ns
  for ns in llm langfuse monitoring platform keycloak; do $KUBECTL -n "$ns" get secret -o json; done \
    | jq -s '[.[].items[]
        | select(.type == "Opaque" and .metadata.labels["app.kubernetes.io/instance"] == null)
        | {apiVersion: "v1", kind: "Secret", type, data,
           metadata: {name: .metadata.name, namespace: .metadata.namespace}}]' > "$tmp/backup.json"
  # shellcheck disable=SC2029 # путь подставляется на клиенте намеренно
  ssh "$SECRETS_SSH" "umask 077 && cat > '$SECRETS_FILE.tmp' && mv '$SECRETS_FILE.tmp' '$SECRETS_FILE'" \
    < "$tmp/backup.json" \
    || die "бэкап секретов на $SECRETS_SSH:$SECRETS_FILE не записан (нет каталога? make k3s-storage)"
  echo "бэкап секретов: $SECRETS_SSH:$SECRETS_FILE ($(jq length "$tmp/backup.json") шт.)"
}

# restore_secrets: секреты из бэкапа, которых нет в кластере. Существующие не трогает.
restore_secrets() {
  [ -n "${SECRETS_SSH:-}" ] || return 0
  local s ns name
  # shellcheck disable=SC2029 # путь подставляется на клиенте намеренно
  ssh "$SECRETS_SSH" "if [ -f '$SECRETS_FILE' ]; then cat '$SECRETS_FILE'; fi" > "$tmp/restore.json" \
    || die "нет доступа к $SECRETS_SSH по ssh"
  [ -s "$tmp/restore.json" ] || { echo "бэкапа секретов на $SECRETS_SSH нет"; return 0; }
  while read -r s; do
    ns=$(jq -r .metadata.namespace <<< "$s")
    name=$(jq -r .metadata.name <<< "$s")
    exists "$ns" "$name" && continue
    namespace "$ns"
    $KUBECTL create -f - <<< "$s" >/dev/null
    echo "secret $ns/$name восстановлен из бэкапа"
  done < <(jq -c '.[]' "$tmp/restore.json")
}

# Admin API LiteLLM и внутренний tRPC Langfuse снаружи кластера, через NodePort. Адреса — в
# LITELLM_URL и LANGFUSE_URL (задаёт make по TARGET).
LITELLM_URL=${LITELLM_URL:-http://localhost:14000}
LANGFUSE_URL=${LANGFUSE_URL:-http://localhost:13300}
KEYCLOAK_URL=${KEYCLOAK_URL:-http://localhost:14040}

# litellm <path> <body-file>: POST с master key, ответ в stdout.
litellm() {
  local out=$tmp/litellm.out code
  [ -f "$tmp/litellm-auth" ] \
    || printf 'authorization: Bearer %s\n' "$(get llm litellm LITELLM_MASTER_KEY)" > "$tmp/litellm-auth"
  code=$(curl -sS -o "$out" -w '%{http_code}' -X POST "$LITELLM_URL$1" \
    -H @"$tmp/litellm-auth" -H 'content-type: application/json' --data-binary @"$2") \
    || die "LiteLLM $LITELLM_URL недоступен"
  [ "$code" = 200 ] || die "LiteLLM $1 ответил $code: $(cat "$out")"
  cat "$out"
}

# litellm_get <path>: GET с master key, ответ в stdout. 404 (например, /key/info на
# отсутствующий alias) — код возврата 1, прочие ошибки — die.
litellm_get() {
  local out=$tmp/litellm-get.out code
  [ -f "$tmp/litellm-auth" ] \
    || printf 'authorization: Bearer %s\n' "$(get llm litellm LITELLM_MASTER_KEY)" > "$tmp/litellm-auth"
  code=$(curl -sS -o "$out" -w '%{http_code}' "$LITELLM_URL$1" -H @"$tmp/litellm-auth") \
    || die "LiteLLM $LITELLM_URL недоступен"
  [ "$code" = 200 ] || { [ "$code" = 404 ] && return 1; die "LiteLLM $1 ответил $code: $(cat "$out")"; }
  cat "$out"
}

# langfuse_login: вход пользователем headless init, как это делает форма логина UI. Cookie
# сессии — в $tmp/cookies, их берёт trpc.
langfuse_login() {
  local csrf
  get langfuse langfuse-init LANGFUSE_INIT_USER_EMAIL > "$tmp/email"
  get langfuse langfuse-init LANGFUSE_INIT_USER_PASSWORD > "$tmp/password"
  csrf=$(curl -sSf -c "$tmp/cookies" "$LANGFUSE_URL/api/auth/csrf" | jq -er .csrfToken) \
    || die "Langfuse: не получен csrfToken"
  curl -sS -o /dev/null -b "$tmp/cookies" -c "$tmp/cookies" \
    -X POST "$LANGFUSE_URL/api/auth/callback/credentials" \
    --data-urlencode "email@$tmp/email" --data-urlencode "password@$tmp/password" \
    --data-urlencode "csrfToken=$csrf" --data-urlencode "callbackUrl=$LANGFUSE_URL"
  grep -q 'session-token' "$tmp/cookies" || die "Langfuse: вход пользователем init не удался"
}

# trpc <procedure> <json>: вызов tRPC Langfuse с cookie сессии, в stdout — result.data.json.
trpc() {
  local out=$tmp/trpc.out code
  jq -n --argjson j "$2" '{json: $j}' > "$tmp/trpc.json"
  code=$(curl -sS -o "$out" -w '%{http_code}' -X POST "$LANGFUSE_URL/api/trpc/$1" \
    -b "$tmp/cookies" -H 'content-type: application/json' --data-binary @"$tmp/trpc.json") \
    || die "Langfuse $LANGFUSE_URL недоступен"
  [ "$code" = 200 ] || die "Langfuse tRPC $1 ответил $code: $(cat "$out")"
  jq -e '.result.data.json' "$out" \
    || die "Langfuse tRPC $1: неожиданный ответ, API UI мог поменяться: $(cat "$out")"
}

# Проверка, что LiteLLM и Langfuse отвечают по адресам снаружи кластера.
health() {
  curl -sf "$LITELLM_URL/health/liveliness" >/dev/null || die "LiteLLM на $LITELLM_URL не отвечает"
  curl -sf "$LANGFUSE_URL/api/public/health" >/dev/null || die "Langfuse на $LANGFUSE_URL не отвечает"
}
