#!/usr/bin/env bash
# Отключает тенанта от платформы: tenant-delete.sh <name> [confirm]. Без confirm=<name> только
# показывает, что будет удалено. Обратное make tenant:
#   1. virtual key LiteLLM тенанта;
#   2. проект Langfuse тенанта вместе с трейсами и API-ключами;
#   3. БД и роль <name> в общем Postgres (DROP DATABASE ... WITH (FORCE), DROP ROLE);
#   4. namespace тенанта со всем содержимым. Платформенный namespace не удаляется, только
#      Secret platform-llm (platform-clickhouse и platform-postgres) в нём; namespace, который
#      делят несколько тенантов, не трогается вовсе: platform-llm в нём один на всех;
#   5. Secret llm/tenant-<name>.
# Данные берутся из llm/tenant-<name>. После каждого шага его поле удаляется из Secret, поэтому
# повторный запуск после сбоя продолжает с невыполненного шага.
# База и пользователь тенанта в ClickHouse описаны в deploy/clickhouse, их убирают там; БД и
# роль Postgres создал make tenant императивно — их удаляет этот скрипт.
# Application тенанта в Argo CD не трогает: его нужно удалить до этого, иначе Argo CD создаст
# namespace заново.
set -euo pipefail

name=${1:?usage: tenant-delete.sh <name> [confirm]}
confirm=${2:-}

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "NAME=$name: нужны a-z, 0-9 и -"
exists llm "tenant-$name" || die "тенанта $name нет (Secret llm/tenant-$name не найден)"

key=$(field llm "tenant-$name" LLM_API_KEY)
project_id=$(field llm "tenant-$name" LANGFUSE_PROJECT_ID)
ns=$(field llm "tenant-$name" NAMESPACE)

# Namespace удаляется целиком, только если он принадлежит одному этому тенанту.
platform_ns=' default kube-system kube-public kube-node-lease argocd argo-rollouts monitoring llm langfuse platform '
shared=''
if [ -n "$ns" ]; then
  for s in $($KUBECTL -n llm get secret -o name | sed -n 's#^secret/tenant-##p'); do
    [ "$s" = "$name" ] && continue
    [ "$(field llm "tenant-$s" NAMESPACE)" = "$ns" ] && shared="$shared $s"
  done
fi
whole_ns=''
[ -n "$ns" ] && [ -z "$shared" ] && [[ $platform_ns != *" $ns "* ]] && whole_ns=1

echo "тенант $name:"
[ -n "$key" ] && echo "  - ключ LiteLLM $name"
[ -n "$project_id" ] && echo "  - проект Langfuse $name ($project_id) вместе с трейсами"
[ -n "$(field llm "tenant-$name" POSTGRES_PASSWORD)" ] && echo "  - БД и роль Postgres $name"
if [ -n "$whole_ns" ]; then
  echo "  - namespace $ns со всем содержимым"
elif [ -n "$shared" ]; then
  echo "  - namespace $ns и platform-llm в нём не трогаются, их используют:$shared"
elif [ -n "$ns" ]; then
  echo "  - Secret $ns/platform-llm, platform-clickhouse и platform-postgres (namespace $ns платформенный, остаётся)"
fi
echo "  - Secret llm/tenant-$name"

if [ "$confirm" != "$name" ]; then
  echo "ничего не удалено: подтвердите CONFIRM=$name"
  exit 0
fi

# drop <field>: шаг выполнен, при повторном запуске его не повторять.
drop() {
  $KUBECTL -n llm patch secret "tenant-$name" --type=json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/$1\"}]" >/dev/null
}

health

if [ -n "$key" ]; then
  jq -n --arg k "$key" '{keys: [$k]}' > "$tmp/delete.json"
  litellm /key/delete "$tmp/delete.json" >/dev/null
  drop LLM_API_KEY
  echo "ключ LiteLLM $name удалён"
fi

if [ -n "$project_id" ]; then
  langfuse_login
  trpc projects.delete "$(jq -n --arg p "$project_id" '{projectId: $p}')" >/dev/null
  drop LANGFUSE_PROJECT_ID
  echo "проект Langfuse $name удалён"
fi

if [ -n "$(field llm "tenant-$name" POSTGRES_PASSWORD)" ] && [[ ! $name =~ - ]]; then
  $KUBECTL -n platform exec postgres-0 -- \
    env PGPASSWORD="$(get platform postgres POSTGRES_PASSWORD)" \
    psql -v ON_ERROR_STOP=1 -U platform -d postgres \
    -c "DROP DATABASE IF EXISTS $name WITH (FORCE); DROP ROLE IF EXISTS $name" >/dev/null \
    || die "Postgres: БД и роль $name не удалены"
  drop POSTGRES_PASSWORD
  echo "БД и роль Postgres $name удалены"
fi

if [ -n "$whole_ns" ]; then
  $KUBECTL delete namespace "$ns" --ignore-not-found --timeout=5m >/dev/null
  echo "namespace $ns удалён"
elif [ -n "$ns" ] && [ -z "$shared" ]; then
  $KUBECTL -n "$ns" delete secret platform-llm platform-clickhouse platform-postgres --ignore-not-found >/dev/null
  echo "Secret $ns/platform-llm, $ns/platform-clickhouse и $ns/platform-postgres удалены"
fi

$KUBECTL -n llm delete secret "tenant-$name" >/dev/null
echo "тенант $name удалён"
backup_secrets
