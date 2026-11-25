#!/usr/bin/env bash
# Останавливает/возобновляет проект: project-ctl.sh <stop|start> <tenant>.
# Проект — это namespace: <tenant> = имя namespace и имя root-Application (записи-входа в
# Argo CD). stop выключает auto-sync у всех записей проекта (иначе selfHeal вернёт реплики) и
# гасит ворклоады в namespace в 0; start возвращает auto-sync, и Argo CD поднимает реплики из
# git. PVC и данные тенанта в общих Postgres/ClickHouse не трогаются.
set -euo pipefail

mode=${1:?usage: project-ctl.sh <stop|start> <tenant>}
tenant=${2:?usage: project-ctl.sh <stop|start> <tenant>}

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ $mode == stop || $mode == start ]] || die "режим должен быть stop или start, а не $mode"

# Записи проекта: листья по destination.namespace, root по имени (имя проекта == namespace).
apps=$($KUBECTL -n argocd get applications -o json \
  | jq -r --arg t "$tenant" '.items[]
      | select(.spec.destination.namespace == $t or .metadata.name == $t)
      | .metadata.name') \
  || die "не удалось получить Application из Argo CD"
[ -n "$apps" ] || die "проект $tenant не найден: нет Application с name или destination.namespace == $tenant"

if [[ $mode == stop ]]; then
  # Сначала auto-sync, потом scale — иначе selfHeal откатит масштабирование.
  for app in $apps; do
    $KUBECTL -n argocd patch application "$app" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
    echo "auto-sync выключен: $app"
  done
  for kind in rollout deployment statefulset; do
    for r in $($KUBECTL -n "$tenant" get "$kind" -o name 2>/dev/null || true); do
      $KUBECTL -n "$tenant" patch "$r" --type=merge -p '{"spec":{"replicas":0}}' >/dev/null
      echo "replicas=0: $r"
    done
  done
  echo "проект $tenant остановлен (PVC и данные не тронуты)"
else
  for app in $apps; do
    $KUBECTL -n argocd patch application "$app" --type=merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
    $KUBECTL -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    echo "auto-sync включён: $app"
  done
  echo "проект $tenant возобновляется: Argo CD поднимет реплики из git (до ~3 мин)"
fi
