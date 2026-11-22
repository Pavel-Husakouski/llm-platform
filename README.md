# llm-platform

Общая LLM-инфраструктура для локальных проектов в k3s на выделенном хосте (или в локальном
kind): LiteLLM (шлюз к провайдерам, virtual keys с бюджетом), Langfuse (трейсы и score) на
общем ClickHouse (он же для баз проектов), Prometheus, Grafana и Argo Rollouts.
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
export DEEPSEEK_API_KEY=...   # только из окружения, .env не читается; без него make secret оставляет прежний
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
| Grafana    | http://HOST:30030               | http://localhost:13030              | admin, `make grafana-password`                |
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

## ClickHouse и Grafana

ClickHouse общий: в базе `default` — данные Langfuse, рядом базы проектов. Пользователи, права и
квоты описаны в `deploy/clickhouse/clickhouse.yaml` (`platform-users.xml`), пароли — в Secret
`langfuse/clickhouse-users`, их создаёт `make secret`.

| Пользователь    | Права                                   | Пароль                                           |
|-----------------|-----------------------------------------|--------------------------------------------------|
| `clickhouse`    | всё (им ходит Langfuse)                 | `make clickhouse-password`                       |
| `layers_writer` | CREATE TABLE, INSERT, SELECT `layers.*` | `make clickhouse-password CH_USER=layers_writer` |
| `grafana_ro`    | SELECT `layers.*`, лимиты и квота       | `make clickhouse-password CH_USER=grafana_ro`    |

Grafana берёт источники из provisioning: `uid: prometheus` и `uid: clickhouse` (пользователь
`grafana_ro`, база по умолчанию `layers`). Дашборды проект держит у себя и заливает по API
токеном service account:

```sh
make grafana-token NAME=layers   # папка layers, service account с Edit только на неё, токен
curl -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  http://HOST:30030/api/dashboards/db \
  -d '{"dashboard": {...}, "folderUid": "layers", "overwrite": true}'
```

Токен хранится в `monitoring/grafana-token-<name>`, повторный запуск печатает его же.

Новый проект в ClickHouse: пользователь `<name>_writer` в `platform-users.xml`, ключ в
`scripts/platform-secrets.sh` (`passwords langfuse clickhouse-users ...`), база в Job
`clickhouse-databases`, поднять `config/revision`, затем `make secret` и `make tenant` — тот
положит Secret `platform-clickhouse` в namespace проекта.

## Модели

Список моделей и цены — в `deploy/litellm/litellm.yaml` (`model_list`). Тенант обращается к
модели по alias (`deepseek-flash`), ключ провайдера есть только у LiteLLM.

## Проверки

CI на каждый PR и push в `main`: kubeconform по манифестам `deploy/` и shellcheck скриптов.
