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
