# llm-platform

Общая LLM-инфраструктура для локальных проектов в kind: LiteLLM (шлюз к провайдерам, virtual
keys с бюджетом), Langfuse (трейсы и score) на своём ClickHouse, Prometheus и Argo Rollouts.
Всё ставит Argo CD из этого репо. Проекты подключаются как тенанты: каждый получает свой
virtual key и свой проект Langfuse, а свои Application кладёт в тот же Argo CD.

Контракт тенанта и устройство — в [SPEC.md](SPEC.md).

## Кластер

Нужны `docker`, `kind`, `kubectl`, `helm`, `jq`, `curl`, `openssl`.

```sh
export DEEPSEEK_API_KEY=...   # только из окружения, .env не читается
make up                       # кластер, секреты, Argo CD, root-app, ожидание
make status
make down                     # удаляет кластер целиком, вместе с тенантами
```

`make up REVISION=<ветка>` — Argo CD берёт `deploy/` из этой ветки.

| Что        | Адрес                          | Вход                                          |
|------------|--------------------------------|-----------------------------------------------|
| Argo CD    | http://localhost:18080         | admin, `make argocd-password`                 |
| Prometheus | http://localhost:19090         |                                               |
| Langfuse   | http://localhost:13300         | admin@llm-platform.local, `make langfuse-password` |
| LiteLLM    | http://localhost:14000/ui      | admin, `make litellm-password` (master key)   |
| ClickHouse | http://localhost:18123/play, :19000 | clickhouse, `make clickhouse-password`   |

Порты 13000–13009 на хосте проброшены на NodePort 30000–30009: они зарезервированы под API
тенантов, потому что порты kind задаются только при создании кластера.

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

Удаление тенанта пока вручную: ключ в LiteLLM UI, проект в Langfuse UI, Secret
`llm/tenant-<name>` и namespace тенанта.

## Модели

Список моделей и цены — в `deploy/litellm/litellm.yaml` (`model_list`). Тенант обращается к
модели по alias (`deepseek-flash`), ключ провайдера есть только у LiteLLM.

## Проверки

CI на каждый PR и push в `main`: kubeconform по манифестам `deploy/` и shellcheck скриптов.
