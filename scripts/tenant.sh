#!/usr/bin/env bash
# Подключает тенанта к платформе: tenant.sh <name> <namespace> <budget-usd> <model,...>.
#   1. проект Langfuse <name> и его API-ключи (внутренний tRPC UI, см. SPEC.md);
#   2. virtual key LiteLLM с alias <name>, бюджетом на 30 дней и metadata.logging: трейсы его
#      вызовов уходят в проект тенанта;
#   3. Secret platform-llm в namespace тенанта (контракт тенанта) и platform-clickhouse, если у
#      тенанта есть пользователь <name>_writer в общем ClickHouse (deploy/clickhouse);
#   4. роль <name> и БД <name> в общем Postgres (deploy/postgres) и Secret platform-postgres.
#      Роль — OWNER своей БД, REVOKE CONNECT от PUBLIC, CONNECTION LIMIT 20, statement_timeout
#      60 с. Пароль роли — в llm/tenant-<name> (источник истины, как ключи LiteLLM).
# Ключи тенанта хранятся в Secret llm/tenant-<name>. Если он уже есть, проект Langfuse не
# трогается; ключ LiteLLM перевыпускается, только если токена из секрета нет в БД LiteLLM
# (Postgres LiteLLM пересоздавался), иначе модели ключа сверяются с MODELS и обновляются при
# расхождении. platform-llm копируется заново всегда.
# Работает снаружи кластера через NodePort: адреса LITELLM_URL и LANGFUSE_URL задаёт make
# по TARGET, по умолчанию — адреса kind на localhost.
set -euo pipefail

name=${1:?usage: tenant.sh <name> <namespace> <budget-usd> <model,...>}
ns=${2:?usage: tenant.sh <name> <namespace> <budget-usd> <model,...>}
budget=${3:?usage: tenant.sh <name> <namespace> <budget-usd> <model,...>}
models=${4:?usage: tenant.sh <name> <namespace> <budget-usd> <model,...>}

# Адреса, которые видят поды внутри кластера.
LLM_BASE_URL=http://litellm.llm:4000
LANGFUSE_HOST=http://langfuse-web.langfuse:3000
CLICKHOUSE_URL=http://clickhouse.platform:8123
POSTGRES_HOST=postgres.platform

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NAME=$name: нужны a-z, 0-9 и -"
[[ $ns =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NS=$ns: нужны a-z, 0-9 и -"
[[ $budget =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "BUDGET=$budget: нужно число в долларах"

# Копия ключей тенанта в его namespace. Адреса берутся из констант выше, а не из
# tenant-<name>, чтобы их смена доходила до тенантов при следующем make tenant.
publish() {
  namespace "$ns"
  apply "$ns" platform-llm \
    "LLM_BASE_URL=$LLM_BASE_URL" \
    "LLM_API_KEY=$(get llm "tenant-$name" LLM_API_KEY)" \
    "LANGFUSE_HOST=$LANGFUSE_HOST" \
    "LANGFUSE_PUBLIC_KEY=$(get llm "tenant-$name" LANGFUSE_PUBLIC_KEY)" \
    "LANGFUSE_SECRET_KEY=$(get llm "tenant-$name" LANGFUSE_SECRET_KEY)"
  # База <name> и пользователь <name>_writer описаны в deploy/clickhouse, пароль — в
  # platform/clickhouse-users. Нет пользователя — нет и секрета.
  local ch_password
  ch_password=$(field platform clickhouse-users "${name}_writer" 2>/dev/null || true)
  if [ -n "$ch_password" ]; then
    apply "$ns" platform-clickhouse \
      "CLICKHOUSE_URL=$CLICKHOUSE_URL" \
      "CLICKHOUSE_DATABASE=$name" \
      "CLICKHOUSE_USER=${name}_writer" \
      "CLICKHOUSE_PASSWORD=$ch_password"
  fi
  # БД и роль Postgres тенанта: создаёт postgres(), пароль — из llm/tenant-<name>.
  local pg_pw
  pg_pw=$(postgres)
  apply "$ns" platform-postgres \
    "POSTGRES_HOST=$POSTGRES_HOST" \
    "POSTGRES_PORT=5432" \
    "POSTGRES_DB=$name" \
    "POSTGRES_USER=$name" \
    "POSTGRES_PASSWORD=$pg_pw" \
    "DATABASE_URL=postgresql://$name:$pg_pw@$POSTGRES_HOST:5432/$name"
}

# pg_sql: SQL из stdin суперпользователем общего Postgres (deploy/postgres), в stdout — вывод
# psql. Пароль — в env пода, не в argv; SQL — во временных файлах, как у остальных секретов.
pg_sql() {
  $KUBECTL -n platform exec -i postgres-0 -- \
    env PGPASSWORD="$(get platform postgres POSTGRES_PASSWORD)" \
    psql -v ON_ERROR_STOP=1 -tA -U platform -d postgres -f -
}

# Пароль роли Postgres тенанта из llm/tenant-<name>; нет ключа — генерируется и дописывается
# (merge: остальные ключи секрета не трогаются).
pg_password() {
  local pw
  pw=$(field llm "tenant-$name" POSTGRES_PASSWORD)
  if [ -z "$pw" ]; then
    pw=$(rand 20)
    $KUBECTL -n llm patch secret "tenant-$name" --type=merge \
      -p "{\"data\":{\"POSTGRES_PASSWORD\":\"$(printf %s "$pw" | base64 -w0)\"}}" >/dev/null
    echo "пароль Postgres $name сгенерирован и сохранён в llm/tenant-$name" >&2
  fi
  echo "$pw"
}

# БД и роль Postgres тенанта, печатает пароль роли. Идемпотентно: роль сверяется с паролем из
# секрета, БД не пересоздаётся. Имя — без дефиса: идентификаторы Postgres без кавычек (то же
# ограничение, что у ClickHouse). pgvector тенанту даёт template1, отдельно создавать не нужно.
postgres() {
  [[ $name =~ - ]] && die "Postgres: NAME=$name с дефисом не подходит, БД и роль Postgres без кавычек"
  local pw exists
  pw=$(pg_password)
  cat > "$tmp/pg-create.sql" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$name') THEN
    CREATE ROLE $name;
  END IF;
END
\$\$;
ALTER ROLE $name WITH LOGIN PASSWORD '$pw' CONNECTION LIMIT 20;
ALTER ROLE $name SET statement_timeout = '60s';
ALTER ROLE $name SET idle_in_transaction_session_timeout = '5min';
SQL
  pg_sql < "$tmp/pg-create.sql" >/dev/null \
    || die "Postgres: роль $name не создана (postgres.platform недоступен?)"
  exists=$(pg_sql <<< "SELECT 1 FROM pg_database WHERE datname = '$name'" \
    || die "Postgres: postgres.platform недоступен")
  if [ -z "$exists" ]; then
    printf 'CREATE DATABASE %s OWNER %s;\nREVOKE CONNECT ON DATABASE %s FROM PUBLIC;\n' \
      "$name" "$name" "$name" > "$tmp/pg-db.sql"
    pg_sql < "$tmp/pg-db.sql" >/dev/null || die "Postgres: БД $name не создана"
    echo "БД Postgres $name (OWNER $name, vector из template1)" >&2
  else
    echo "БД Postgres $name уже есть, роль сверена с паролем из секрета" >&2
  fi
  echo "$pw"
}

# generate_key <public-key> <secret-key>: virtual key LiteLLM с alias <name>, бюджетом на 30 дней
# и metadata.logging — трейсы вызовов уходят в проект Langfuse с этими ключами. Печатает ключ.
generate_key() {
  jq -n --arg name "$name" --arg models "$models" --argjson budget "$budget" \
    --arg pk "$1" --arg sk "$2" --arg host "$LANGFUSE_HOST" '{
      key_alias: $name,
      models: ($models | split(",")),
      max_budget: $budget,
      budget_duration: "30d",
      metadata: {logging: [{
        callback_name: "langfuse_otel",
        callback_type: "success_and_failure",
        callback_vars: {langfuse_public_key: $pk, langfuse_secret_key: $sk, langfuse_host: $host}
      }]}
    }' > "$tmp/generate.json"
  litellm /key/generate "$tmp/generate.json" | jq -er .key
}

if exists llm "tenant-$name"; then
  # Ключ из секрета сверяется с БД LiteLLM по токену. Токена нет (Postgres LiteLLM
  # пересоздавался) — перевыпускаем с моделями и бюджетом из аргументов; есть — сверяем модели
  # и при расхождении обновляем через /key/update (бюджет не трогаем: для него make llm-budget).
  # Проект Langfuse не трогается: его ключи уже в tenant-<name>.
  token=$(get llm "tenant-$name" LLM_API_KEY)
  if litellm_get "/key/info?key=$token" > "$tmp/key-info.json"; then
    current=$(jq -r '.info.models | sort | join(",")' "$tmp/key-info.json")
    desired=$(echo "$models" | tr ',' '\n' | sort | paste -sd, -)
    if [ "$current" != "$desired" ]; then
      jq -n --arg key "$token" --arg models "$models" \
        '{key: $key, models: ($models | split(","))}' > "$tmp/update.json"
      litellm /key/update "$tmp/update.json" >/dev/null
      echo "ключ LiteLLM $name: модели $current -> $desired"
    else
      echo "тенант $name уже есть, ключ не пересоздаётся (модели $current)"
    fi
  else
    echo "ключа LiteLLM $name нет в БД (Postgres LiteLLM пересоздавался?), перевыпускаю"
    llm_key=$(generate_key "$(get llm "tenant-$name" LANGFUSE_PUBLIC_KEY)" \
                          "$(get llm "tenant-$name" LANGFUSE_SECRET_KEY)") \
      || die "LiteLLM: /key/generate без key"
    echo "ключ LiteLLM $name перевыпущен (бюджет \$$budget на 30 дней, модели $models)"
    apply llm "tenant-$name" \
      "NAMESPACE=$(get llm "tenant-$name" NAMESPACE)" \
      "LLM_API_KEY=$llm_key" \
      "LANGFUSE_PROJECT_ID=$(get llm "tenant-$name" LANGFUSE_PROJECT_ID)" \
      "LANGFUSE_PUBLIC_KEY=$(get llm "tenant-$name" LANGFUSE_PUBLIC_KEY)" \
      "LANGFUSE_SECRET_KEY=$(get llm "tenant-$name" LANGFUSE_SECRET_KEY)"
    backup_secrets
  fi
  publish
  exit 0
fi

# Откат при ошибке до записи tenant-<name>: без него повторный запуск создал бы второй проект Langfuse и второй ключ.
project_id='' llm_key=''
rollback() {
  if [ -n "$llm_key" ]; then
    jq -n --arg k "$llm_key" '{keys: [$k]}' > "$tmp/delete.json"
    (litellm /key/delete "$tmp/delete.json") >/dev/null || echo "не удалось удалить ключ LiteLLM" >&2
  fi
  if [ -n "$project_id" ]; then
    (trpc projects.delete "$(jq -n --arg p "$project_id" '{projectId: $p}')") >/dev/null \
      || echo "не удалось удалить проект Langfuse $project_id, удалите его в UI" >&2
  fi
}
on_exit() {
  local status=$?
  [ "$status" -eq 0 ] || rollback
  rm -rf "$tmp"
}
trap on_exit EXIT

health
langfuse_login
org_id=$(get langfuse langfuse-init LANGFUSE_INIT_ORG_ID)

project_id=$(trpc projects.create "$(jq -n --arg n "$name" --arg o "$org_id" \
  '{name: $n, orgId: $o}')" | jq -er .id) || die "Langfuse: projects.create без id"
echo "проект Langfuse $name ($project_id)"
trpc projectApiKeys.create "$(jq -n --arg p "$project_id" \
  '{projectId: $p, note: "llm-platform tenant"}')" > "$tmp/lf-keys"
pk=$(jq -er .publicKey "$tmp/lf-keys") || die "Langfuse: projectApiKeys.create без publicKey"
sk=$(jq -er .secretKey "$tmp/lf-keys") || die "Langfuse: projectApiKeys.create без secretKey"

# Колбэк в metadata.logging ключа: трейсы его вызовов идут в проект тенанта, а не в platform.
llm_key=$(generate_key "$pk" "$sk") || die "LiteLLM: /key/generate без key"
echo "ключ LiteLLM $name (бюджет \$$budget на 30 дней, модели $models)"

apply llm "tenant-$name" \
  "NAMESPACE=$ns" \
  "LLM_API_KEY=$llm_key" \
  "LANGFUSE_PROJECT_ID=$project_id" \
  "LANGFUSE_PUBLIC_KEY=$pk" \
  "LANGFUSE_SECRET_KEY=$sk"
# Ключи сохранены: дальше откат не нужен, повторный запуск возьмёт их из tenant-<name>.
project_id='' llm_key=''
publish
backup_secrets
