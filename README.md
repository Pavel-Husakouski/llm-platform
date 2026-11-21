# llm-platform

Общая LLM-инфраструктура для локальных проектов в k3s на выделенном хосте (или в локальном
kind): LiteLLM (шлюз к провайдерам, virtual keys с бюджетом), Langfuse (трейсы и score) на
своём ClickHouse, Prometheus и Argo Rollouts.
Всё ставит Argo CD из этого репо. Проекты подключаются как тенанты: каждый получает свой
virtual key и свой проект Langfuse, а свои Application кладёт в тот же Argo CD.

Контракт тенанта и устройство — в [SPEC.md](SPEC.md).

## Кластер

Нужны `kubectl`, `helm`, `jq`, `curl`, `openssl`, `ssh` (для kind ещё `docker` и `kind`).

По умолчанию (`TARGET=k3s`) платформа живёт в k3s на хосте `HOST=192.168.50.195`: один узел,
без Traefik и ServiceLB, хранилище `local-path`.

```sh
make k3s-install              # один раз, сам: ssh -t на хост, спросит пароль sudo
make kubeconfig               # context llm-platform в ~/.kube/config (старый — в .bak)
export DEEPSEEK_API_KEY=...   # только из окружения, .env не читается
make up                       # проверка кластера, секреты, Argo CD, root-app, ожидание
make status
make k3s-uninstall            # удаляет k3s с хоста вместе со всеми данными
```

`make up REVISION=<ветка>` — Argo CD берёт `deploy/` из этой ветки. `HOST=` и `SSH=user@host`
меняют хост. Локальный kind: `TARGET=kind` для любой цели (`make up TARGET=kind`, `make down
TARGET=kind` удаляет kind-кластер).

| Что        | k3s (`HOST`)                    | kind                                | Вход                                          |
|------------|---------------------------------|-------------------------------------|-----------------------------------------------|
| Argo CD    | http://HOST:30080               | http://localhost:18080              | admin, `make argocd-password`                 |
| Prometheus | http://HOST:30090               | http://localhost:19090              |                                               |
| Langfuse   | http://HOST:30300               | http://localhost:13300              | admin@llm-platform.local, `make langfuse-password` |
| LiteLLM    | http://HOST:30400/ui            | http://localhost:14000/ui           | admin, `make litellm-password` (master key)   |
| ClickHouse | http://HOST:30123/play, :30900  | http://localhost:18123/play, :19000 | clickhouse, `make clickhouse-password`        |

В k3s сервисы открыты всей LAN без TLS. Для API тенантов зарезервированы NodePort 30000–30009;
в kind они проброшены на localhost:13000–13009, потому что порты kind задаются только при
создании кластера.

Langfuse пускает в UI только по адресу из `langfuseURL` (NEXTAUTH_URL), его подставляет
`make root` по `TARGET`.

Плагин kubectl для выкаток тенантов (`kubectl argo rollouts get/promote/abort/retry`):

```sh
make tools                    # kubectl-argo-rollouts в ~/.local/bin, TOOLS_DIR=... — в другой каталог
```

Версия плагина (`ROLLOUTS_PLUGIN` в Makefile) равна версии контроллера, то есть appVersion
chart `argoRollouts` в `deploy/apps/values.yaml`, и обновляется вместе с ним. `make tools`
сверяет бинарник с sha256 из релиза, повторно не скачивает и падает, если версия контроллера в
кластере другая.

## Тенанты

```sh
make tenant NAME=agent NS=agent BUDGET=1 MODELS=deepseek-flash
```

- создаёт проект Langfuse `agent` с API-ключами и virtual key LiteLLM с alias `agent`,
  бюджетом $1 на 30 дней и доступом к перечисленным моделям;
- пишет Secret `platform-llm` в namespace `agent`, проект подключает его через `envFrom`;
- повторный запуск ключи не пересоздаёт, только заново копирует `platform-llm`.

`NS` по умолчанию равен `NAME`, `BUDGET=1`, `MODELS=deepseek-flash` (список через запятую).

Бюджет ключа: `make llm-budget KEY=agent BUDGET=0` — вызовы тенанта получают отказ (422),
`BUDGET=1` — вернуть.

Удаление тенанта:

```sh
make tenant-delete NAME=agent                 # только показывает, что будет удалено
make tenant-delete NAME=agent CONFIRM=agent   # удаляет
```

Удаляются ключ LiteLLM, проект Langfuse с трейсами, namespace тенанта со всем содержимым и
Secret `llm/tenant-<name>`. Application тенанта в Argo CD удалите заранее, иначе Argo CD
создаст namespace заново.

## Модели

Список моделей и цены — в `deploy/litellm/litellm.yaml` (`model_list`). Тенант обращается к
модели по alias (`deepseek-flash`), ключ провайдера есть только у LiteLLM.

## Проверки

CI на каждый PR и push в `main`: kubeconform по манифестам `deploy/` и shellcheck скриптов.
