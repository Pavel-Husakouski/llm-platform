# llm-platform: спецификация

## Состав

| Application     | Namespace       | Источник                                   |
|-----------------|-----------------|--------------------------------------------|
| `llm-platform`  | `argocd`        | root-app, chart `deploy/apps`              |
| `storage`       | —               | `deploy/storage`, StorageClass `platform`  |
| `argo-rollouts` | `argo-rollouts` | chart argo-rollouts                        |
| `prometheus`    | `monitoring`    | chart prometheus, только server            |
| `clickhouse`    | `platform`      | `deploy/clickhouse`, общий                 |
| `postgres`      | `platform`      | `deploy/postgres`, общий (БД тенантов), NodePort :30432 |
| `langfuse`      | `langfuse`      | chart langfuse, внешний ClickHouse         |
| `litellm`       | `llm`           | `deploy/litellm`, свой Postgres            |
| `embeddings`    | `tei`           | `deploy/embeddings`, TEI, alias `embed`    |
| `grafana`       | `monitoring`    | chart grafana (grafana-community)          |

Кластер — k3s на выделенном хосте (`TARGET=k3s`, по умолчанию) или локальный kind
(`TARGET=kind`). Манифесты одинаковы, различаются только адреса NodePort снаружи и
`langfuseURL`, который подставляет `make root`.

Argo CD ставит `make argocd` из helm (`deploy/bootstrap/argocd-values.yaml`), всё остальное
синхронизируется из git. Argo Rollouts (CRD) и Prometheus (scrape подов по аннотациям
`prometheus.io/*`) работают на весь кластер и доступны тенантам.

Root-app платформы называется `llm-platform`, не `root`: тенанты кладут свои root-app в тот
же Argo CD и должны выбирать уникальные имена. `make wait` ждёт только Application платформы.

## Контракт тенанта

`make tenant NAME=<name> NS=<namespace> BUDGET=<usd> MODELS=<alias,...>` создаёт в namespace
тенанта Secret `platform-llm`:

| Ключ                  | Значение                                        |
|-----------------------|-------------------------------------------------|
| `LLM_BASE_URL`        | `http://litellm.llm:4000` (OpenAI-совместимый)  |
| `LLM_API_KEY`         | virtual key LiteLLM с alias `<name>`            |
| `LANGFUSE_HOST`       | `http://langfuse-web.langfuse:3000`             |
| `LANGFUSE_PUBLIC_KEY` | API-ключи проекта Langfuse `<name>`             |
| `LANGFUSE_SECRET_KEY` |                                                 |

Тенант подключает его через `envFrom: [{secretRef: {name: platform-llm}}]`.

Если у тенанта есть пользователь `<name>_writer` в общем ClickHouse (`deploy/clickhouse`),
`make tenant` кладёт рядом Secret `platform-clickhouse`:

| Ключ                  | Значение                                        |
|-----------------------|-------------------------------------------------|
| `CLICKHOUSE_URL`      | `http://clickhouse.platform:8123`               |
| `CLICKHOUSE_DATABASE` | `<name>`                                        |
| `CLICKHOUSE_USER`     | `<name>_writer`                                 |
| `CLICKHOUSE_PASSWORD` | из `platform/clickhouse-users`                  |

`make tenant` также создаёт в общем Postgres (`deploy/postgres`) роль `<name>` и базу `<name>`
(роль — OWNER) и кладёт рядом Secret `platform-postgres`:

| Ключ               | Значение                                             |
|--------------------|------------------------------------------------------|
| `POSTGRES_HOST`    | `postgres.platform`                                  |
| `POSTGRES_PORT`    | `5432`                                               |
| `POSTGRES_DB`      | `<name>`                                             |
| `POSTGRES_USER`    | `<name>`                                             |
| `POSTGRES_PASSWORD`| из `llm/tenant-<name>`                               |
| `DATABASE_URL`     | `postgresql://<name>:<пароль>@postgres.platform:5432/<name>` |

Имя тенанта с ClickHouse или Postgres — без `-`: пароль попадает в под ClickHouse переменной
`CH_PASSWORD_<user>`, а БД и роль Postgres — идентификаторы без кавычек.

- Трейс каждого вызова пишет LiteLLM в проект Langfuse тенанта: у virtual key в
  `metadata.logging` задан колбэк `langfuse_otel` с ключами этого проекта. В проект
  `platform` такие трейсы не дублируются.
- Score и свои трейсы тенант пишет теми же ключами из `platform-llm`, в тот же проект.
- Бюджет ключа — `max_budget` на 30 дней (`budget_duration: 30d`). Сверх бюджета LiteLLM
  отвечает ошибкой, spend виден в LiteLLM UI.
- Для API тенанта зарезервированы NodePort 30000–30009 (в k3s на `HOST:3000x`, в kind на
  `localhost:1300x`). Тенант выбирает свободный порт сам.

## ClickHouse и Grafana

ClickHouse — один на платформу, в namespace `platform` (общий data plane, рядом общий Postgres
тенантов, там его PVC с трейсами Langfuse и базами тенантов). Пользователи,
профили и квоты — XML в ConfigMap `clickhouse-config`, пароли — из Secret `clickhouse-users`
через env `CH_PASSWORD_<user>` (`<password from_env=.../>`). Базы создаёт PostSync Job
`clickhouse-databases` (`CREATE DATABASE IF NOT EXISTS`). Ручных `CREATE USER` нет.

`grafana_ro`: `readonly=2`, `max_memory_usage` 1 ГБ, `max_execution_time` 30 с,
`max_concurrent_queries_for_user` 4; лимиты можно только уменьшить (constraints min 1 / max),
квота 20000 запросов и 3600 с выполнения в час. Плагин Grafana (clickhouse-go) шлёт
`max_execution_time` = таймаут источника + 5 с, поэтому `queryTimeout` источника — 25.

Grafana: источники `prometheus` и `clickhouse` (uid — контракт для дашбордов тенантов),
база Grafana на PVC. `make grafana-token NAME=<p>` (`scripts/grafana-token.sh`, через admin API
по NodePort) создаёт папку `<p>`, service account `<p>` с ролью Viewer и Edit на эту папку и
токен в `monitoring/grafana-token-<p>`; если секрет есть — печатает сохранённый.

## Общий Postgres

Postgres — один на платформу, в namespace `platform` (`deploy/postgres`), образ
`pgvector/pgvector` — тот же, что в docker-compose соседнего проекта: дампы совместимы в обе
стороны. PostSync Job `postgres-init` держит `CREATE EXTENSION vector` в `template1`: каждая
новая БД наследует расширение. Суперпользователь и пароль — Secret `platform/postgres`
(`make secret`), пароль роли тенанта — в `llm/tenant-<name>`.

Роль и БД тенанта создаёт `make tenant` идемпотентно (роль сверяется с паролем из секрета,
БД не пересоздаётся), удаляет `make tenant-delete` (`DROP DATABASE ... WITH (FORCE)`,
`DROP ROLE`). Изоляция тенантов: `REVOKE CONNECT ... FROM PUBLIC` на каждую БД (у служебной
`postgres` его отзывает Job `postgres-init`), `CONNECTION LIMIT 20`, `statement_timeout` 60 с и
`idle_in_transaction_session_timeout` 5 мин
на роль; тенант может поднять таймауты сессионным `SET`. Квот CPU/памяти на базу у vanilla
Postgres нет: тяжёлому тенанту — отдельный CNPG-кластер в его namespace, платформу менять не
нужно. LiteLLM-овский `litellm-postgres` — отдельный, с общим не смешивается.

Service `postgres` — ещё и NodePort `:30432` (в kind проброшен на `localhost:15432`): приложения
тенантов вне кластера (локальный `npm run dev`) ходят в БД напрямую, пароль роли — из
`llm/tenant-<name>`, как у ClickHouse. Внутри кластера тенант использует `platform-postgres`
(`postgres.platform:5432`), наружный адрес в контракт не входит.

## Данные и переустановка k3s

`/srv/llm-platform` на хосте вне каталогов k3s, `k3s-uninstall` его не трогает:

- `volumes/` — `default-local-storage-path` k3s (флаг в `make k3s-install`, для старой установки
  `make k3s-storage`). StorageClass `platform` (Application `storage`, sync-wave -2): тот же
  local-path, `pathPattern: <ns>/<pvc>/` и `Retain`. PVC с тем же именем после переустановки
  получает тот же каталог с данными.
- `secrets/secrets.json` — бэкап секретов платформы: Opaque в `llm`, `langfuse`, `monitoring`,
  `platform` без метки `app.kubernetes.io/instance` (те создают чарты). Пишется по ssh в конце `make secret`,
  `tenant`, `tenant-delete`, `grafana-token`; `make secret` в начале создаёт из него секреты,
  которых нет в кластере, и только потом генерирует недостающие. Без него тома бесполезны:
  пароли Postgres заданы при инициализации, данные Langfuse зашифрованы `encryption-key`.

Не переживают переустановку: метрики Prometheus (без тома), состояние Argo CD (восстанавливается
из git, пароль admin новый), `platform-llm`, `platform-clickhouse` и `platform-postgres` в
namespace тенантов (`make tenant` копирует заново).

## Секреты

В git секретов нет. `make secret` (`scripts/platform-secrets.sh`) создаёт их один раз,
существующие не перезаписывает, после переустановки k3s берёт из бэкапа на хосте. Ключ
DeepSeek берётся из `DEEPSEEK_API_KEY` и обновляется при каждом запуске.

- `llm/deepseek`, `llm/litellm` (master key, пароль Postgres);
- `langfuse/*`: ключи приложения, headless init (org `llm-platform`, проект `platform`,
  пользователь `admin@llm-platform.local`), пароли Postgres, Redis, S3, ClickHouse;
- `llm/langfuse-api`: ключи проекта `platform` для глобального колбэка LiteLLM. Туда идут
  вызовы ключей без `metadata.logging`, например master key;
- `platform/clickhouse-users`: пароли пользователей общего ClickHouse, ключ = имя; новые
  ключи дописываются, существующие не меняются;
- `platform/clickhouse-auth`: копия пароля `clickhouse` из `langfuse/langfuse-clickhouse-auth`
  (тот нужен чарту Langfuse), `make secret` сверяет копию с источником при каждом запуске;
- `platform/postgres`: суперпользователь общего Postgres тенантов, пароли ролей тенантов — в
  `llm/tenant-<name>`;
- `monitoring/grafana-admin`, `monitoring/grafana-clickhouse` (пароль `grafana_ro`),
  `monitoring/grafana-token-<p>`;
- `llm/tenant-<name>`: ключи тенанта (virtual key, id и API-ключи проекта Langfuse, пароль
  роли Postgres), источник для `platform-llm` и `platform-postgres`.

## make tenant

`scripts/tenant.sh` работает снаружи кластера через NodePort: LiteLLM (master key) и Langfuse
(пользователь init) по адресам `LITELLM_URL` и `LANGFUSE_URL`, которые задаёт make по
`TARGET`.

1. Если есть Secret `llm/tenant-<name>`, проект Langfuse не трогается; ключ LiteLLM
   перевыпускается только когда токена из секрета нет в БД LiteLLM (`/key/info?key=<token>` —
   404, бывает после пересоздания Postgres LiteLLM), иначе модели ключа сверяются с `MODELS` и
   обновляются при расхождении (бюджет не трогается — для него `make llm-budget`). Затем
   копируются `platform-llm` и `platform-postgres`. Так `make tenant` идемпотентна, чинит
   потерянные ключи и держит модели ключа в заявленном состоянии.
2. Иначе вход в Langfuse (`GET /api/auth/csrf`, `POST /api/auth/callback/credentials`) и
   tRPC `projects.create` и `projectApiKeys.create`.
3. LiteLLM `POST /key/generate` с `key_alias`, `models`, `max_budget`, `budget_duration` и
   `metadata.logging`.
4. Ключи сохраняются в `llm/tenant-<name>`, затем пишется `platform-llm`.
5. Роль и БД `<name>` в общем Postgres (идемпотентно, пароль роли — из `llm/tenant-<name>`),
   затем пишется `platform-postgres`.

Если шаги 2–4 падают, созданные проект и ключ удаляются, и повторный запуск начинает заново.

Org API keys и `POST /api/public/projects` в OSS-версии Langfuse недоступны, поэтому проекты
создаются через tRPC — внутренний API UI. Он может поменяться между версиями: версия chart
Langfuse зафиксирована, скрипт проверяет ответы и падает с понятной ошибкой. После обновления
Langfuse прогнать `make tenant` на тестовом тенанте.

## make tenant-delete

`scripts/tenant-delete.sh` обратна `make tenant` и работает с теми же адресами. Без
`CONFIRM=<name>` только печатает, что будет удалено.

1. LiteLLM `POST /key/delete` с ключом из `llm/tenant-<name>`.
2. Вход в Langfuse и tRPC `projects.delete`. Langfuse помечает проект удалённым, его трейсы
   стирает worker асинхронно.
3. БД и роль `<name>` в общем Postgres: `DROP DATABASE ... WITH (FORCE)` и `DROP ROLE`.
4. Namespace тенанта удаляется целиком. Если это namespace платформы, удаляются только
   `platform-llm`, `platform-clickhouse` и `platform-postgres`; если его делят несколько
   тенантов, он не трогается: `platform-llm` в нём один на всех.
5. Secret `llm/tenant-<name>`.

После шагов 1–3 их поле (`LLM_API_KEY`, `LANGFUSE_PROJECT_ID`, `POSTGRES_PASSWORD`) удаляется
из `llm/tenant-<name>`, поэтому повторный запуск после сбоя продолжает с невыполненного шага.
Application тенанта в Argo CD скрипт не трогает.
