#!/usr/bin/env bash
# Bootstrap Keycloak: realm platform, OIDC-клиенты argocd/grafana/litellm (confidential, redirect
# URI под каждый UI), группы admins/viewers и пользователь pauel (admin). Идемпотентно, через
# Admin REST. Client secret'ы заранее сгенерированы make secret (keycloak/oidc): скрипт ставит их
# на клиенты, а argocd-овый кладёт в argocd-secret (Argo CD читает oidc.Keycloak.clientSecret).
# Клиенты и группы Keycloak в git не хранятся — как тенанты в tenant.sh.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# Адреса снаружи кластера (NodePort), задаёт make по TARGET.
KEYCLOAK_URL=${KEYCLOAK_URL:-http://localhost:14040}
ARGOCD_URL=${ARGOCD_URL:-http://localhost:18080}
GRAFANA_URL=${GRAFANA_URL:-http://localhost:13030}
LITELLM_URL=${LITELLM_URL:-http://localhost:14000}
REALM=platform
ADMIN_USER=pauel
ADMIN_EMAIL=pauel@llm-platform.io

admin_user=$(get keycloak keycloak KEYCLOAK_ADMIN_USERNAME)
admin_pass=$(get keycloak keycloak KEYCLOAK_ADMIN_PASSWORD)

# Токен admin-cli в master realm (password grant). Keycloak после старта ещё может мигрировать БД,
# поэтому ждём до ~60 с.
token=''
for _ in $(seq 1 30); do
  code=$(curl -sS -o "$tmp/master-token.json" -w '%{http_code}' \
    -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -H 'content-type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=$admin_user" \
    --data-urlencode "password=$admin_pass" 2>/dev/null || true)
  if [ "$code" = 200 ]; then token=$(jq -er .access_token "$tmp/master-token.json"); break; fi
  sleep 2
done
[ -n "$token" ] || { echo "Keycloak $KEYCLOAK_URL: admin login не удался ($(cat "$tmp/master-token.json" 2>/dev/null))" >&2; exit 1; }

# kc <method> <path> [body-file]: admin REST с токеном. Код ответа — в глобальной $kc_code,
# тело — в stdout (404 не ошибка, её разбирает вызывающий).
kc_code=''
kc() {
  local method=$1 path=$2 body=${3:-} args=()
  [ -n "$body" ] && args+=(-H 'content-type: application/json' --data-binary @"$body")
  kc_code=$(curl -sS -o "$tmp/kc.out" -w '%{http_code}' -X "$method" "$KEYCLOAK_URL$path" \
    -H "authorization: Bearer $token" "${args[@]}") \
    || die "Keycloak $path: соединение не удалось"
  cat "$tmp/kc.out"
}

# --- realm -------------------------------------------------------------
kc GET "/admin/realms/$REALM" >/dev/null
if [ "$kc_code" = 404 ]; then
  jq -n --arg r "$REALM" '{realm: $r, enabled: true}' > "$tmp/realm.json"
  kc POST "/admin/realms" "$tmp/realm.json" >/dev/null
  echo "realm $REALM создан"
else
  echo "realm $REALM уже есть"
fi

# --- клиенты -----------------------------------------------------------
# имя|redirect URI. Секрет при создании ставится, при обновлении не трогается (PUT без secret).
clients=(
  "argocd|$ARGOCD_URL/auth/callback"
  "grafana|$GRAFANA_URL/login/generic_oauth"
  "litellm|$LITELLM_URL/sso/callback"
)
for c in "${clients[@]}"; do
  cid=${c%%|*}
  redirect=${c#*|}
  case $cid in
    argocd) secret=$(get keycloak oidc ARGOCD_CLIENT_SECRET) ;;
    grafana) secret=$(get keycloak oidc GRAFANA_CLIENT_SECRET) ;;
    litellm) secret=$(get keycloak oidc LITELLM_CLIENT_SECRET) ;;
  esac
  jq -n --arg id "$cid" --arg redirect "$redirect" --arg secret "$secret" \
    '{clientId: $id, enabled: true, protocol: "openid-connect", publicClient: false,
      standardFlowEnabled: true, directAccessGrantsEnabled: false, serviceAccountsEnabled: false,
      redirectUris: [$redirect], secret: $secret}' > "$tmp/client.json"

  kc GET "/admin/realms/$REALM/clients?clientId=$cid" > "$tmp/clients.json"
  id=$(jq -r '.[0].id // empty' "$tmp/clients.json")
  if [ -n "$id" ]; then
    jq 'del(.secret)' "$tmp/client.json" > "$tmp/client-upd.json"
    kc PUT "/admin/realms/$REALM/clients/$id" "$tmp/client-upd.json" >/dev/null
    echo "client $cid: обновлён ($id)"
  else
    kc POST "/admin/realms/$REALM/clients" "$tmp/client.json" >/dev/null
    id=$(kc GET "/admin/realms/$REALM/clients?clientId=$cid" | jq -r '.[0].id')
    echo "client $cid: создан ($id)"
  fi

  # Маппер групп: claim groups в id_token, access_token и userinfo (Argo CD и Grafana читают его).
  kc GET "/admin/realms/$REALM/clients/$id/protocol-mappers/models" > "$tmp/mappers.json"
  if jq -e 'any(.[]; .name == "groups")' "$tmp/mappers.json" >/dev/null 2>&1; then
    echo "  mapper groups уже есть"
  else
    jq -n '{name: "groups", protocol: "openid-connect", protocolMapper: "oidc-group-membership-mapper",
      config: {"full.path": "false", "id.token.claim": "true", "access.token.claim": "true",
               "userinfo.token.claim": "true", "claim.name": "groups"}}' > "$tmp/mapper.json"
    kc POST "/admin/realms/$REALM/clients/$id/protocol-mappers/models" "$tmp/mapper.json" >/dev/null
    echo "  mapper groups добавлен"
  fi
done

# --- группы -------------------------------------------------------------
ensure_group() {
  local name=$1 id
  kc GET "/admin/realms/$REALM/groups?search=$name&exact=true" > "$tmp/groups.json"
  id=$(jq -r '.[0].id // empty' "$tmp/groups.json")
  if [ -z "$id" ]; then
    jq -n --arg n "$name" '{name: $n}' > "$tmp/group.json"
    kc POST "/admin/realms/$REALM/groups" "$tmp/group.json" >/dev/null
    id=$(kc GET "/admin/realms/$REALM/groups?search=$name&exact=true" | jq -r '.[0].id')
    echo "группа $name создана"
  else
    echo "группа $name уже есть"
  fi
  printf '%s' "$id" > "$tmp/group-$name"
}
ensure_group admins
ensure_group viewers

# --- пользователь pauel -------------------------------------------------
kc GET "/admin/realms/$REALM/users?username=$ADMIN_USER&exact=true" > "$tmp/users.json"
uid=$(jq -r '.[0].id // empty' "$tmp/users.json")
jq -n --arg u "$ADMIN_USER" --arg e "$ADMIN_EMAIL" \
  '{username: $u, email: $e, emailVerified: true, enabled: true, firstName: "Pauel"}' \
  > "$tmp/user.json"
if [ -z "$uid" ]; then
  kc POST "/admin/realms/$REALM/users" "$tmp/user.json" >/dev/null
  uid=$(kc GET "/admin/realms/$REALM/users?username=$ADMIN_USER&exact=true" | jq -r '.[0].id')
  echo "пользователь $ADMIN_USER создан ($uid)"
else
  kc PUT "/admin/realms/$REALM/users/$uid" "$tmp/user.json" >/dev/null
  echo "пользователь $ADMIN_USER обновлён ($uid, email=$ADMIN_EMAIL)"
fi

admins_id=$(cat "$tmp/group-admins")
kc PUT "/admin/realms/$REALM/users/$uid/groups/$admins_id" >/dev/null
echo "$ADMIN_USER в группе admins"

pauel_pass=$(get keycloak oidc PAUEL_PASSWORD)
jq -n --arg p "$pauel_pass" '{type: "password", value: $p, temporary: false}' > "$tmp/reset.json"
kc PUT "/admin/realms/$REALM/users/$uid/reset-password" "$tmp/reset.json" >/dev/null
echo "пароль $ADMIN_USER установлен"

# --- client secret Argo CD ---------------------------------------------
# Argo CD ставится helm (make argocd) и argocd-secret при upgrade пересоздаётся, поэтому secret
# кладём здесь, на каждом make up, из keycloak/oidc (значение стабильно, в бэкапе на хосте).
if $KUBECTL -n argocd get secret argocd-secret >/dev/null 2>&1; then
  argocd_secret=$(get keycloak oidc ARGOCD_CLIENT_SECRET)
  jq -n --arg s "$argocd_secret" '{stringData: {"oidc.Keycloak.clientSecret": $s}}' > "$tmp/argocd-patch.json"
  $KUBECTL -n argocd patch secret argocd-secret --type=merge -p "$(cat "$tmp/argocd-patch.json")" >/dev/null
  echo "argocd-secret: oidc.Keycloak.clientSecret установлен"
else
  echo "argocd-secret не найден (Argo CD ещё не установлен?) — пропускаю"
fi

echo
echo "SSO готов: вход в Argo CD, Grafana и LiteLLM через Keycloak ($ADMIN_USER, пароль: make keycloak-password)"
