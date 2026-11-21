#!/usr/bin/env bash
# Меняет бюджет virtual key тенанта в LiteLLM: llm-budget.sh <alias> <usd>. BUDGET=0 —
# проверить отказ по бюджету (вызовы тенанта получат 422), прежнее значение — вернуть.
# Ключ берётся из Secret llm/tenant-<alias>, запрос идёт снаружи кластера через NodePort
# (LITELLM_URL задаёт make).
set -euo pipefail

alias=${1:?usage: llm-budget.sh <alias> <usd>}
budget=${2:?usage: llm-budget.sh <alias> <usd>}
LITELLM_URL=${LITELLM_URL:-http://localhost:14000}

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[[ $budget =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "BUDGET=$budget: нужно число в долларах"
exists llm "tenant-$alias" || die "тенанта $alias нет: make tenant NAME=$alias ..."

printf 'authorization: Bearer %s\n' "$(get llm litellm LITELLM_MASTER_KEY)" > "$tmp/auth"
jq -n --arg k "$(get llm "tenant-$alias" LLM_API_KEY)" --argjson b "$budget" \
  '{key: $k, max_budget: $b}' > "$tmp/body.json"
curl -sSf -X POST "$LITELLM_URL/key/update" -H @"$tmp/auth" \
  -H 'content-type: application/json' --data-binary @"$tmp/body.json" \
  | jq -r '"max_budget: \(.max_budget) spend: \(.spend)"'
