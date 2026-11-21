#!/usr/bin/env bash
# Подключает тенанта к платформе: tenant.sh <name> <namespace> <budget-usd> <model,...>.
#   1. проект Langfuse <name> и его API-ключи (внутренний tRPC UI, см. SPEC.md);
#   2. virtual key LiteLLM с alias <name>, бюджетом на 30 дней и metadata.logging: трейсы его
#      вызовов уходят в проект тенанта;
#   3. Secret platform-llm в namespace тенанта (контракт тенанта).
# Ключи тенанта хранятся в Secret llm/tenant-<name>. Если он уже есть, шаги 1–2 пропускаются
# и только заново копируется platform-llm: повторный запуск ничего не пересоздаёт.
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
}

if exists llm "tenant-$name"; then
  echo "тенант $name уже есть, ключи не пересоздаются"
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
jq -n --arg name "$name" --arg models "$models" --argjson budget "$budget" \
  --arg pk "$pk" --arg sk "$sk" --arg host "$LANGFUSE_HOST" '{
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
llm_key=$(litellm /key/generate "$tmp/generate.json" | jq -er .key) \
  || die "LiteLLM: /key/generate без key"
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
