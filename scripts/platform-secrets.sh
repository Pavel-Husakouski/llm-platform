#!/usr/bin/env bash
# Секреты платформы в кластере, в git их нет. Ключ DeepSeek берётся из окружения и обновляется при
# каждом запуске (без DEEPSEEK_API_KEY остаётся прежний), остальное генерируется один раз: существующий секрет не перезаписывается,
# иначе Langfuse потеряет доступ к своим данным, а LiteLLM — к ключам тенантов.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# После переустановки k3s: секреты из бэкапа на хосте, данные в томах зашифрованы и закрыты ими.
restore_secrets

for ns in llm langfuse monitoring platform keycloak n8n dify; do namespace "$ns"; done

if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  apply llm deepseek "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY"
elif exists llm deepseek; then
  echo "secret llm/deepseek: DEEPSEEK_API_KEY не задан, остаётся прежний"
else
  die "задайте DEEPSEEK_API_KEY в окружении"
fi

# Langfuse: ключи приложения, headless init (org, проект platform для вызовов без тенанта,
# пользователь UI) и пароли его хранилищ. Проекты тенантов создаёт tenant.sh.
once langfuse langfuse-keys \
  "salt=$(rand 32)" "encryption-key=$(rand 32)" "nextauth-secret=$(rand 32)"
once langfuse langfuse-init \
  LANGFUSE_INIT_ORG_ID=llm-platform \
  LANGFUSE_INIT_ORG_NAME=llm-platform \
  LANGFUSE_INIT_PROJECT_ID=platform \
  LANGFUSE_INIT_PROJECT_NAME=platform \
  "LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-$(rand 16)" \
  "LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-$(rand 16)" \
  LANGFUSE_INIT_USER_EMAIL=admin@llm-platform.local \
  LANGFUSE_INIT_USER_NAME=admin \
  "LANGFUSE_INIT_USER_PASSWORD=$(rand 12)"
pg=$(rand 20)
once langfuse langfuse-postgresql-auth \
  POSTGRES_USER=postgres "POSTGRES_PASSWORD=$pg" POSTGRES_DB=langfuse \
  USERDB_USER=langfuse "USERDB_PASSWORD=$pg"
once langfuse langfuse-redis-auth "default=$(rand 20)"
s3=$(rand 20)
s3_config='{"identities":[{"name":"langfuse","credentials":[{"accessKey":"langfuse","secretKey":"'$s3'"}],"actions":["Admin","Read","Write","List","Tagging"]}]}'
once langfuse langfuse-s3-auth accessKey=langfuse "secretKey=$s3" "seaweedfs_s3_config=$s3_config"
# Пароль clickhouse общий с чартом Langfuse: чарт читает langfuse/langfuse-clickhouse-auth, под
# ClickHouse в platform — платформенную копию того же пароля (apply, а не once: копия всегда
# сверяется с источником).
once langfuse langfuse-clickhouse-auth "password=$(rand 20)"
apply platform clickhouse-auth "password=$(get langfuse langfuse-clickhouse-auth password)"
# Пароли пользователей общего ClickHouse из deploy/clickhouse (platform-users.xml), ключ = имя
# пользователя. Новый пользователь — новый ключ здесь, существующие пароли не меняются.
passwords platform clickhouse-users layers_writer grafana_ro

# Общий Postgres тенантов (deploy/postgres): суперпользователь и его пароль. Роли и базы
# тенантов создаёт tenant.sh, пароли ролей — в Secret llm/tenant-<name>.
once platform postgres \
  POSTGRES_USER=platform \
  "POSTGRES_PASSWORD=$(rand 20)" \
  POSTGRES_DB=postgres

# Grafana: admin и пароль grafana_ro для источника данных ClickHouse.
once monitoring grafana-admin admin-user=admin "admin-password=$(rand 12)"
apply monitoring grafana-clickhouse \
  "GRAFANA_RO_PASSWORD=$(get platform clickhouse-users grafana_ro)"

# LiteLLM: master key и пароль его Postgres. Virtual keys тенантов выдаёт tenant.sh.
once llm litellm \
  "LITELLM_MASTER_KEY=sk-master-$(rand 16)" \
  "POSTGRES_PASSWORD=$(rand 20)"

# n8n (queue mode): пароль его Postgres, encryption key (шифрует credentials) и JWT-секрет.
# Owner-аккаунт UI пользователь создаёт при первом входе: SSO в community-редакции нет.
once n8n n8n \
  "POSTGRES_PASSWORD=$(rand 20)" \
  "N8N_ENCRYPTION_KEY=$(rand 32)" \
  "N8N_USER_MANAGEMENT_JWT_SECRET=$(rand 32)"

# Dify: SECRET_KEY (сессии/шифрование в БД), INNER_API_KEY (внутренние вызовы api/worker) и
# пароли его Postgres/Redis. Chart кладёт их в общие DB_PASSWORD/REDIS_PASSWORD и берёт
# литералом из root-app (make root): в git этих значений нет.
once dify dify \
  "SECRET_KEY=$(rand 32)" \
  "INNER_API_KEY=$(rand 32)" \
  "POSTGRES_PASSWORD=$(rand 20)" \
  "REDIS_PASSWORD=$(rand 20)"

# Keycloak (SSO): bootstrap admin master-realm, пароль его Postgres и client secret'ы OIDC.
# Client secret'ы генерим заранее и кладём в keycloak/oidc: make keycloak ставит их на клиенты,
# а потребители (Argo CD, Grafana, LiteLLM, Langfuse) читают те же значения — после переустановки k3s
# секреты те же, SSO не перевыпускается.
once keycloak keycloak \
  KEYCLOAK_ADMIN_USERNAME=admin \
  "KEYCLOAK_ADMIN_PASSWORD=$(rand 20)" \
  POSTGRES_USER=keycloak \
  "POSTGRES_PASSWORD=$(rand 20)" \
  POSTGRES_DB=keycloak
# passwords, а не once: новый client secret добавляется к существующим, их значения не меняются.
passwords keycloak oidc \
  ARGOCD_CLIENT_SECRET GRAFANA_CLIENT_SECRET LITELLM_CLIENT_SECRET \
  LANGFUSE_CLIENT_SECRET PAUEL_PASSWORD

# Потребители SSO (apply, не once): значения из keycloak/oidc и адресов SSO, сверяются при
# каждом запуске. Grafana читает client secret через envFrom, LiteLLM — GENERIC_* и PROXY_BASE_URL.
apply monitoring grafana-keycloak \
  "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=$(get keycloak oidc GRAFANA_CLIENT_SECRET)"
apply llm litellm-sso \
  GENERIC_CLIENT_ID=litellm \
  "GENERIC_CLIENT_SECRET=$(get keycloak oidc LITELLM_CLIENT_SECRET)" \
  "GENERIC_AUTHORIZATION_ENDPOINT=${KEYCLOAK_URL}/realms/platform/protocol/openid-connect/auth" \
  "GENERIC_TOKEN_ENDPOINT=${KEYCLOAK_URL}/realms/platform/protocol/openid-connect/token" \
  "GENERIC_USERINFO_ENDPOINT=${KEYCLOAK_URL}/realms/platform/protocol/openid-connect/userinfo" \
  "GENERIC_SCOPE=openid email profile" \
  GENERIC_USER_EMAIL_ATTRIBUTE=email \
  GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=name \
  "PROXY_BASE_URL=${LITELLM_URL}" \
  PROXY_ADMIN_ID=pauel@llm-platform.io

# Langfuse SSO: OIDC-клиент Keycloak (AUTH_KEYCLOAK_*). issuer из KEYCLOAK_URL.
apply langfuse langfuse-sso \
  "LANGFUSE_CLIENT_SECRET=$(get keycloak oidc LANGFUSE_CLIENT_SECRET)"

# Копия API-ключей проекта platform для глобального колбэка LiteLLM: туда идут вызовы
# ключей без metadata.logging, например master key.
apply llm langfuse-api \
  "LANGFUSE_PUBLIC_KEY=$(get langfuse langfuse-init LANGFUSE_INIT_PROJECT_PUBLIC_KEY)" \
  "LANGFUSE_SECRET_KEY=$(get langfuse langfuse-init LANGFUSE_INIT_PROJECT_SECRET_KEY)"

backup_secrets
