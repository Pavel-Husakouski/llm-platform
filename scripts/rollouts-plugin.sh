#!/usr/bin/env bash
# Ставит kubectl-плагин Argo Rollouts (kubectl argo rollouts get/promote/abort/retry) той же
# версии, что контроллер платформы: rollouts-plugin.sh <версия> <каталог>. Бинарник сверяется
# с sha256 из релиза; если нужная версия уже стоит, ничего не скачивается. В конце версия
# сверяется с образом контроллера в кластере: расхождение значит, что chart обновили без плагина.
set -euo pipefail

version=${1:?usage: rollouts-plugin.sh <version> <dir>}
dir=${2:?usage: rollouts-plugin.sh <version> <dir>}

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "архитектура $(uname -m) не поддерживается" ;;
esac
asset=kubectl-argo-rollouts-$os-$arch
bin=$dir/kubectl-argo-rollouts
url=https://github.com/argoproj/argo-rollouts/releases/download/$version

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi; }

# version --short печатает «kubectl-argo-rollouts: v1.10.1+<sha>».
if "$bin" version --short 2>/dev/null | grep -qF "$version+"; then
  echo "kubectl-argo-rollouts $version уже есть: $bin"
else
  curl -fsSL -o "$tmp/$asset" "$url/$asset"
  curl -fsSL -o "$tmp/checksums.txt" "$url/argo-rollouts-checksums.txt"
  want=$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/checksums.txt")
  [[ -n $want ]] || die "в checksums релиза $version нет $asset"
  got=$(sha256 "$tmp/$asset" | awk '{print $1}')
  [[ $got == "$want" ]] || die "sha256 $asset не совпал с релизом: $got != $want"
  mkdir -p "$dir"
  install -m 755 "$tmp/$asset" "$bin"
  echo "kubectl-argo-rollouts $version: $bin"
fi

command -v kubectl-argo-rollouts >/dev/null \
  || echo "добавьте $dir в PATH, иначе kubectl не найдёт плагин" >&2

image=$($KUBECTL -n argo-rollouts get deploy argo-rollouts \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [[ -z $image ]]; then
  echo "кластера или контроллера нет: версию не сверить"
elif [[ ${image##*:} != "$version" ]]; then
  die "контроллер $image, плагин $version: обновите ROLLOUTS_PLUGIN в Makefile вместе с chart"
else
  echo "контроллер $image: версии совпадают"
fi
