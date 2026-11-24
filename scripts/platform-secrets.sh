#!/usr/bin/env bash
# Секреты платформы в кластере, в git их нет. Ключ DeepSeek берётся из окружения и обновляется при
# каждом запуске (без DEEPSEEK_API_KEY остаётся прежний), остальное генерируется один раз: существующий секрет не перезаписывается,
# иначе Langfuse потеряет доступ к своим данным, а LiteLLM — к ключам тенантов.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# После переустановки k3s: секреты из бэкапа на хосте, данные в томах зашифрованы и закрыты ими.
restore_secrets

for ns in llm langfuse monitoring platform; do namespace "$ns"; done

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

# Копия API-ключей проекта platform для глобального колбэка LiteLLM: туда идут вызовы
# ключей без metadata.logging, например master key.
apply llm langfuse-api \
  "LANGFUSE_PUBLIC_KEY=$(get langfuse langfuse-init LANGFUSE_INIT_PROJECT_PUBLIC_KEY)" \
  "LANGFUSE_SECRET_KEY=$(get langfuse langfuse-init LANGFUSE_INIT_PROJECT_SECRET_KEY)"

backup_secrets
