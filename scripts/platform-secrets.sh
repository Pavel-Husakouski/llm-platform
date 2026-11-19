#!/usr/bin/env bash
# Секреты платформы в kind, в git их нет. Ключ DeepSeek берётся из окружения и обновляется при
# каждом запуске, остальное генерируется один раз: существующий секрет не перезаписывается,
# иначе Langfuse потеряет доступ к своим данным, а LiteLLM — к ключам тенантов.
set -euo pipefail

: "${DEEPSEEK_API_KEY:?задайте DEEPSEEK_API_KEY в окружении}"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

for ns in llm langfuse; do namespace "$ns"; done

apply llm deepseek "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY"

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
once langfuse langfuse-clickhouse-auth "password=$(rand 20)"

# LiteLLM: master key и пароль его Postgres. Virtual keys тенантов выдаёт tenant.sh.
once llm litellm \
  "LITELLM_MASTER_KEY=sk-master-$(rand 16)" \
  "POSTGRES_PASSWORD=$(rand 20)"

# Копия API-ключей проекта platform для глобального колбэка LiteLLM: туда идут вызовы
# ключей без metadata.logging, например master key.
apply llm langfuse-api \
  "LANGFUSE_PUBLIC_KEY=$(get langfuse langfuse-init LANGFUSE_INIT_PROJECT_PUBLIC_KEY)" \
  "LANGFUSE_SECRET_KEY=$(get langfuse langfuse-init LANGFUSE_INIT_PROJECT_SECRET_KEY)"
