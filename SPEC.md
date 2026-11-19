# llm-platform: спецификация

## Состав

| Application     | Namespace       | Источник                                   |
|-----------------|-----------------|--------------------------------------------|
| `llm-platform`  | `argocd`        | root-app, chart `deploy/apps`              |
| `argo-rollouts` | `argo-rollouts` | chart argo-rollouts                        |
| `prometheus`    | `monitoring`    | chart prometheus, только server            |
| `clickhouse`    | `langfuse`      | `deploy/langfuse`                          |
| `langfuse`      | `langfuse`      | chart langfuse, внешний ClickHouse         |
| `litellm`       | `llm`           | `deploy/litellm`, свой Postgres            |

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

- Трейс каждого вызова пишет LiteLLM в проект Langfuse тенанта: у virtual key в
  `metadata.logging` задан колбэк `langfuse_otel` с ключами этого проекта. В проект
  `platform` такие трейсы не дублируются.
- Score и свои трейсы тенант пишет теми же ключами из `platform-llm`, в тот же проект.
- Бюджет ключа — `max_budget` на 30 дней (`budget_duration: 30d`). Сверх бюджета LiteLLM
  отвечает ошибкой, spend виден в LiteLLM UI.
- Для API тенанта зарезервированы NodePort 30000–30009 (на хосте 13000–13009). Тенант
  выбирает свободный порт сам.

## Секреты

В git секретов нет. `make secret` (`scripts/platform-secrets.sh`) создаёт их один раз,
существующие не перезаписывает. Ключ DeepSeek берётся из `DEEPSEEK_API_KEY` и обновляется
при каждом запуске.

- `llm/deepseek`, `llm/litellm` (master key, пароль Postgres);
- `langfuse/*`: ключи приложения, headless init (org `llm-platform`, проект `platform`,
  пользователь `admin@llm-platform.local`), пароли Postgres, Redis, S3, ClickHouse;
- `llm/langfuse-api`: ключи проекта `platform` для глобального колбэка LiteLLM. Туда идут
  вызовы ключей без `metadata.logging`, например master key;
- `llm/tenant-<name>`: ключи тенанта (virtual key, id и API-ключи проекта Langfuse), источник
  для `platform-llm`.

## make tenant

`scripts/tenant.sh` работает с хоста через NodePort: LiteLLM на `localhost:14000` (master
key), Langfuse на `localhost:13300` (пользователь init).

1. Если есть Secret `llm/tenant-<name>`, проект и ключ не создаются, только копируется
   `platform-llm`. Так `make tenant` идемпотентна.
2. Иначе вход в Langfuse (`GET /api/auth/csrf`, `POST /api/auth/callback/credentials`) и
   tRPC `projects.create` и `projectApiKeys.create`.
3. LiteLLM `POST /key/generate` с `key_alias`, `models`, `max_budget`, `budget_duration` и
   `metadata.logging`.
4. Ключи сохраняются в `llm/tenant-<name>`, затем пишется `platform-llm`.

Если шаги 2–4 падают, созданные проект и ключ удаляются, и повторный запуск начинает заново.

Org API keys и `POST /api/public/projects` в OSS-версии Langfuse недоступны, поэтому проекты
создаются через tRPC — внутренний API UI. Он может поменяться между версиями: версия chart
Langfuse зафиксирована, скрипт проверяет ответы и падает с понятной ошибкой. После обновления
Langfuse прогнать `make tenant` на тестовом тенанте.
