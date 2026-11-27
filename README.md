# llm-platform

Общая LLM-инфраструктура для локальных проектов в k3s на выделенном хосте (или в локальном
kind): LiteLLM (шлюз к провайдерам, virtual keys с бюджетом), Langfuse (трейсы и score) на
общем ClickHouse, n8n (автоматизация, queue mode) и Dify (LLM-платформа с RAG) — каждый со
своим хранилищем, общие ClickHouse и Postgres (pgvector) для баз проектов, Prometheus,
Grafana и Argo Rollouts.
Всё ставит Argo CD из этого репо. Проекты подключаются как тенанты: каждый получает свой
virtual key и свой проект Langfuse, а свои Application кладёт в тот же Argo CD.

Контракт тенанта и устройство — в [SPEC.md](SPEC.md).

## Кластер

Нужны `kubectl`, `helm`, `jq`, `curl`, `openssl`, `ssh` (для kind ещё `docker` и `kind`).

По умолчанию (`TARGET=k3s`) платформа живёт в k3s на хосте `HOST=192.168.50.195`: один узел,
без Traefik и ServiceLB, хранилище `local-path` в `/srv/llm-platform/volumes`.

```sh
make k3s-install              # один раз, сам: ssh -t на хост, спросит пароль sudo
make kubeconfig               # context llm-platform в ~/.kube/config (старый — в .bak)
export DEEPSEEK_API_KEY=...   # только из окружения, .env не читается; без него make secret оставляет прежний
make up                       # проверка кластера, секреты, Argo CD, root-app, ожидание
make status
make k3s-uninstall            # удаляет k3s с хоста; данные платформы в /srv/llm-platform остаются
```

### Данные переживают переустановку k3s

Тома платформы (ClickHouse, Postgres — LiteLLM, Langfuse, n8n, Dify и общий, Redis и S3
Langfuse, Redis n8n, Weaviate Dify, Grafana) — на StorageClass
`platform` (`deploy/storage`): каталог `/srv/llm-platform/volumes/<ns>/<pvc>/` на хосте,
`Retain`. Секреты, без которых эти данные не прочитать, `make secret`, `make tenant`,
`make tenant-delete` и `make grafana-token` копируют на хост в `/srv/llm-platform/secrets/`
(права 700, ssh-пользователь), а `make secret` восстанавливает недостающие оттуда.

```sh
make k3s-uninstall && make k3s-install && make kubeconfig && make up   # данные на месте
```

k3s, поставленный раньше без пути `/srv/llm-platform/volumes`: один раз `make k3s-storage` (сам,
sudo на хосте, перезапускает k3s). Тома тенантов на `local-path` по умолчанию тоже лежат в
`/srv/llm-platform/volumes`, но под именами с UID и при переустановке не подхватываются: нужен
`storageClassName: platform`. В kind (`TARGET=kind`) данных вне кластера нет.

`make up REVISION=<ветка>` — Argo CD берёт `deploy/` из этой ветки. `HOST=` и `SSH=user@host`
меняют хост. Локальный kind: `TARGET=kind` для любой цели (`make up TARGET=kind`, `make down
TARGET=kind` удаляет kind-кластер).

| Что        | k3s (`HOST`)                    | kind                                | Вход                                          |
|------------|---------------------------------|-------------------------------------|-----------------------------------------------|
| Argo CD    | https://argocd.llm.internal      | — (port-forward)                   | admin, `make argocd-password`                 |
| Prometheus | http://HOST:30090               | http://localhost:19090              |                                               |
| Grafana    | https://grafana.llm.internal     | — (port-forward)                   | admin, `make grafana-password`                |
| Langfuse   | https://langfuse.llm.internal    | — (port-forward)                   | admin@llm-platform.local, `make langfuse-password` |
| LiteLLM    | https://litellm.llm.internal     | — (port-forward)                   | admin, `make litellm-password` (master key)   |
| n8n        | https://n8n.llm.internal         | — (port-forward)                   | owner-аккаунт при первом входе                |
| Dify       | https://console.dify.llm.internal | — (port-forward)                  | admin при первом входе (см. примечание ниже)  |
| Embeddings | http://HOST:30180/health        | http://localhost:18180/health       | TEI `intfloat/multilingual-e5-base`, в LiteLLM alias `embed` |
| ClickHouse | http://HOST:30123/play, :30900  | http://localhost:18123/play, :19000 | clickhouse, `make clickhouse-password`        |
| Postgres   | postgres.platform:5432 (в кластере) | postgres.platform:5432 (в кластере) | роль `<name>`, пароль в `platform-postgres`   |

В k3s HTTPS даёт `edge` (`deploy/edge`): nginx на hostPort 80/443 терминирует TLS по wildcard
`*.llm.internal`/`*.dify.llm.internal` и проксирует по Host-заголовку. Сертификат выпускает
приватный CA (`make edge-tls`; Let's Encrypt для `.internal` невозможен), его корень `ca.crt`
надо один раз установить как доверенный на каждом устройстве LAN, иначе браузер предупредит
(шифрование работает и без этого). NodePort-ы пользовательских сервисов сняты — наружу только
через edge; Keycloak-issuer SSO остался http (`http://keycloak.llm.internal`). Для API тенантов
зарезервированы NodePort 30000–30009; в kind они проброшены на localhost:13000–13009 (у kind
edge нет — пользовательские сервисы снаружи через port-forward).

Langfuse пускает в UI только по адресу из `langfuseURL` (NEXTAUTH_URL), его подставляет
`make root` по `TARGET`.

n8n и Dify **не** подключены к Keycloak: SSO (OIDC) в обоих — функция Enterprise-редакции
(n8n к тому же требует HTTPS). Вход — по локальному аккаунту, который создаётся при первом
открытии UI. Gateway Dify (Caddy) роутит по Host-заголовку, поэтому Dify живёт на поддоменах
одного IP: вход в консоль — `console.dify.llm.internal` в k3s (резолвит локальный dnsmasq,
`deploy/dns`, на роутере должен стоять DNS Server 1 = 192.168.50.195) и `console.localhost` в
kind (`.localhost` резолвится в 127.0.0.1). Базовый домен и порт задают `difyHost`/`difyPort`
(их подставляет `make root`), а секреты — `difySecretKey`/`difyInnerApiKey`/
`difyPostgresPassword`/`difyRedisPassword`, которые `make root` берёт из Secret `dify/dify`
(создаёт `make secret`).

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
- создаёт в общем Postgres роль `agent` и базу `agent` (pgvector из template1) и пишет
  Secrets `platform-llm` и `platform-postgres` в namespace `agent` — проект подключает их
  через `envFrom`;
- повторный запуск ключи не пересоздаёт: проект Langfuse не трогается, ключ LiteLLM
  перевыпускается, только если его нет в БД, роль и пароль Postgres сверяются, `platform-*`
  копируются заново.

`NS` по умолчанию равен `NAME`, `BUDGET=1`, `MODELS=deepseek-flash` (список через запятую).

Бюджет ключа: `make llm-budget KEY=agent BUDGET=0` — вызовы тенанта получают отказ (422),
`BUDGET=1` — вернуть.

Удаление тенанта:

```sh
make tenant-delete NAME=agent                 # только показывает, что будет удалено
make tenant-delete NAME=agent CONFIRM=agent   # удаляет
```

Удаляются ключ LiteLLM, проект Langfuse с трейсами, БД и роль Postgres, namespace тенанта
со всем содержимым и Secret `llm/tenant-<name>`. Application тенанта в Argo CD удалите
заранее, иначе Argo CD создаст namespace заново.

## ClickHouse и Grafana

ClickHouse общий: в базе `default` — данные Langfuse, рядом базы проектов. Живёт в namespace
`platform` — общем data plane платформы. Пользователи, права и квоты описаны в
`deploy/clickhouse/clickhouse.yaml` (`platform-users.xml`), пароли — в Secret
`platform/clickhouse-users`, их создаёт `make secret`.

| Пользователь    | Права                                   | Пароль                                           |
|-----------------|-----------------------------------------|--------------------------------------------------|
| `clickhouse`    | всё (им ходит Langfuse)                 | `make clickhouse-password`                       |
| `layers_writer` | CREATE TABLE, ALTER TABLE, INSERT, SELECT `layers.*` | `make clickhouse-password CH_USER=layers_writer` |
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
`scripts/platform-secrets.sh` (`passwords platform clickhouse-users ...`), база в Job
`clickhouse-databases`, поднять `config/revision`, затем `make secret` и `make tenant` — тот
положит Secret `platform-clickhouse` в namespace проекта.

## Общий Postgres

Postgres общий: `pgvector/pgvector:pg17` в namespace `platform` (`deploy/postgres`), тот же
образ, что в docker-compose соседнего проекта, — дампы переносятся в обе стороны. `make tenant`
создаёт роль `<name>` и базу `<name>` (роль — OWNER, `REVOKE CONNECT` от PUBLIC,
`CONNECTION LIMIT 20`, `statement_timeout` 60 с) и кладёт в namespace тенанта Secret
`platform-postgres` с `POSTGRES_HOST/PORT/DB/USER/PASSWORD` и готовым `DATABASE_URL`.
pgvector есть в каждой базе без `CREATE EXTENSION` (PostSync Job держит его в template1).
Пароль роли — в `llm/tenant-<name>`, роль и базу удаляет `make tenant-delete` (`DROP DATABASE
... WITH (FORCE)`). Суперпользователь — Secret `platform/postgres`, пароль:
`make postgres-password`.

## Модели

Список моделей и цены — в `deploy/litellm/litellm.yaml` (`model_list`), ключ провайдера есть
только у LiteLLM. Тенант обращается к модели по alias: `deepseek-flash` и `fast` — одна модель
(deepseek-v4-flash, thinking выключен), `smart` — deepseek-v4-pro с thinking и fallback на
`fast`, `embed` — локальные эмбеддинги (TEI `intfloat/multilingual-e5-base`,
`deploy/embeddings`). Ответы кэшируются в Redis (TTL 1 ч, на запрос кэш отключается флагом
`cache_exact_enabled`). Тенанту: `make tenant ... MODELS=deepseek-flash,embed` (или
`smart,fast,embed`); virtual key для приложений вне кластера — `make tenant-key NAME=<name>`.

## Проверки

CI на каждый PR и push в `main`: kubeconform по манифестам `deploy/` и shellcheck скриптов.
