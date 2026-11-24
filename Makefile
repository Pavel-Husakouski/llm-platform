# Платформа в k3s на выделенном хосте (TARGET=k3s, по умолчанию) или в локальном kind
# (TARGET=kind): make up поднимает Argo CD, остальное Argo CD синхронизирует из git. Тенанты подключаются через make tenant и кладут свои Application в тот же Argo CD.
# Ключ DeepSeek берётся только из переменной окружения DEEPSEEK_API_KEY, .env не читается.
# Остальные секреты (LiteLLM, Langfuse) make secret генерирует сам, один раз.

# Где кластер: k3s на хосте HOST (ставит make k3s-install) или kind в локальном docker.
TARGET         ?= k3s
HOST           ?= 192.168.50.195
# ssh-адрес хоста для make k3s-install/kubeconfig/k3s-uninstall: SSH=user@host
SSH            ?= $(HOST)
K3S_VERSION    := v1.37.2+k3s1
# Данные платформы на хосте вне k3s, переживают k3s-uninstall: тома (default-local-storage-path
# k3s, StorageClass platform) и бэкап секретов, без которого тома бесполезны.
STORAGE_DIR    := /srv/llm-platform

CLUSTER        := llm-platform
KIND_CONFIG    := deploy/kind/cluster.yaml
KIND_IMAGE     := kindest/node:v1.37.0
ARGOCD_CHART   := 10.11.6
ARGOCD_REPO    := https://argoproj.github.io/argo-helm
# kubectl-плагин Argo Rollouts (make tools) = appVersion chart charts.argoRollouts из
# deploy/apps/values.yaml: обновляются вместе, make tools сверяет с контроллером в кластере.
ROLLOUTS_PLUGIN := v1.10.1
# Куда make tools кладёт бинарники, каталог должен быть в PATH.
TOOLS_DIR      ?= $(HOME)/.local/bin
# Ветка, из которой Argo CD берёт deploy/: make up REVISION=feature-x
REVISION       ?= main
WAIT_TIMEOUT   ?= 900
# Application платформы: make wait не ждёт Application тенантов.
APPS           := llm-platform storage argo-rollouts prometheus clickhouse postgres langfuse litellm embeddings grafana

# make tenant NAME=agent NS=agent BUDGET=1 MODELS=deepseek-flash
NS             ?= $(NAME)
BUDGET         ?= 1
MODELS         ?= deepseek-flash

# Контекст kubectl и адреса NodePort-сервисов. В kind NodePort проброшены на localhost
# (deploy/kind/cluster.yaml), в k3s они открыты на IP хоста напрямую.
ifeq ($(TARGET),k3s)
CONTEXT        := $(CLUSTER)
URL            := http://$(HOST)
ARGOCD_URL     := $(URL):30080
PROMETHEUS_URL := $(URL):30090
GRAFANA_URL    := $(URL):30030
LANGFUSE_URL   := $(URL):30300
LITELLM_URL    := $(URL):30400
EMBEDDINGS_URL := $(URL):30180
CLICKHOUSE_URL := $(URL):30123
CLICKHOUSE_TCP := $(HOST):30900
TENANT_PORTS   := $(HOST):30000-30009
# Скрипты кладут бэкап секретов на хост по ssh и восстанавливают из него (scripts/lib.sh).
SECRETS_BACKUP := SECRETS_SSH=$(SSH) SECRETS_DIR=$(STORAGE_DIR)/secrets
else ifeq ($(TARGET),kind)
CONTEXT        := kind-$(CLUSTER)
URL            := http://localhost
ARGOCD_URL     := $(URL):18080
PROMETHEUS_URL := $(URL):19090
GRAFANA_URL    := $(URL):13030
LANGFUSE_URL   := $(URL):13300
LITELLM_URL    := $(URL):14000
EMBEDDINGS_URL := $(URL):18180
CLICKHOUSE_URL := $(URL):18123
CLICKHOUSE_TCP := localhost:19000
TENANT_PORTS   := localhost:13000-13009 (NodePort 30000-30009)
# В kind данные живут, пока жив кластер: бэкапа секретов нет.
SECRETS_BACKUP :=
else
$(error TARGET=$(TARGET): нужно k3s или kind)
endif

KUBECTL := kubectl --context $(CONTEXT)
HELM    := helm --kube-context $(CONTEXT)

.PHONY: up down cluster secret argocd root wait status tenant tenant-key tenant-delete llm-budget tools \
  argocd-password langfuse-password litellm-password clickhouse-password postgres-password grafana-password \
  grafana-token k3s-install k3s-storage k3s-uninstall kubeconfig

up: cluster secret argocd root wait status

ifeq ($(TARGET),kind)
down:
	kind delete cluster --name $(CLUSTER)

cluster:
	@if kind get clusters | grep -qx '$(CLUSTER)'; then \
	  echo "cluster $(CLUSTER) уже есть"; \
	else \
	  kind create cluster --config $(KIND_CONFIG) --image $(KIND_IMAGE); \
	fi
else
# k3s ставится один раз (make k3s-install, нужен sudo на хосте), make up его только проверяет.
down:
	@echo "k3s не удаляется через make down: make k3s-uninstall удалит k3s с $(HOST) вместе с данными" >&2
	@exit 1

cluster:
	@$(KUBECTL) get --raw /readyz >/dev/null \
	  || { echo "k3s на $(HOST) недоступен: make k3s-install, затем make kubeconfig" >&2; exit 1; }
	@echo "k3s на $(HOST) доступен (context $(CONTEXT))"
endif

# Каталоги $(STORAGE_DIR) на хосте: volumes — тома, secrets — бэкап секретов, его пишет и читает
# ssh-пользователь (make secret, tenant, grafana-token).
STORAGE_DIRS = sudo install -d -m 755 $(STORAGE_DIR) $(STORAGE_DIR)/volumes && \
  sudo install -d -m 700 -o $$(id -u) -g $$(id -g) $(STORAGE_DIR)/secrets

# k3s на хосте: один узел, без Traefik и ServiceLB, сервисы платформы открыты через NodePort,
# тома в $(STORAGE_DIR)/volumes. Нужен sudo с паролем, поэтому ssh -t: запускать самому, не из агента.
k3s-install:
	ssh -t $(SSH) '$(STORAGE_DIRS) && curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$(K3S_VERSION) sh -s - server \
	  --disable traefik --disable servicelb --tls-san $(HOST) --write-kubeconfig-mode 644 \
	  --default-local-storage-path $(STORAGE_DIR)/volumes'

# Для k3s, поставленного без --default-local-storage-path: каталоги, путь томов в
# /etc/rancher/k3s/config.yaml и перезапуск k3s (поды перезапустятся). Самому, нужен sudo.
k3s-storage:
	ssh -t $(SSH) 'set -e; $(STORAGE_DIRS); \
	  if sudo grep -qs "^default-local-storage-path:" /etc/rancher/k3s/config.yaml; then \
	    sudo grep "^default-local-storage-path:" /etc/rancher/k3s/config.yaml; \
	  else \
	    echo "default-local-storage-path: $(STORAGE_DIR)/volumes" | sudo tee -a /etc/rancher/k3s/config.yaml; \
	  fi; \
	  sudo systemctl restart k3s'

# Удаляет k3s с хоста. Данные платформы в $(STORAGE_DIR) остаются: после k3s-install и make up
# сервисы поднимаются на них, секреты восстанавливаются из бэкапа. Тома тенантов на local-path
# удаляются.
k3s-uninstall:
	ssh -t $(SSH) 'sudo /usr/local/bin/k3s-uninstall.sh'

# kubeconfig k3s с хоста, в ~/.kube/config как context $(CLUSTER). Старый файл — в .bak.
kubeconfig:
	@set -eu; dir=$$(mktemp -d); trap 'rm -rf "$$dir"' EXIT; umask 077; \
	ssh $(SSH) cat /etc/rancher/k3s/k3s.yaml \
	  | sed -e 's#https://127.0.0.1:6443#https://$(HOST):6443#' -e 's/\bdefault\b/$(CLUSTER)/g' \
	  > "$$dir/k3s.yaml"; \
	mkdir -p ~/.kube; touch ~/.kube/config; cp ~/.kube/config ~/.kube/config.bak; \
	kubectl config delete-context $(CLUSTER) >/dev/null 2>&1 || true; \
	kubectl config delete-cluster $(CLUSTER) >/dev/null 2>&1 || true; \
	kubectl config delete-user $(CLUSTER) >/dev/null 2>&1 || true; \
	KUBECONFIG=~/.kube/config:"$$dir/k3s.yaml" kubectl config view --flatten > "$$dir/merged"; \
	mv "$$dir/merged" ~/.kube/config; \
	echo "context $(CLUSTER) → https://$(HOST):6443"

secret:
	@KUBECTL="$(KUBECTL)" $(SECRETS_BACKUP) scripts/platform-secrets.sh

argocd:
	$(HELM) upgrade --install argocd argo-cd --repo $(ARGOCD_REPO) --version $(ARGOCD_CHART) \
	  --namespace argocd --create-namespace \
	  --values deploy/bootstrap/argocd-values.yaml --wait --timeout 10m

# Подставляет ветку и адрес Langfuse, по которому браузер открывает UI (NEXTAUTH_URL).
root:
	sed -e 's#targetRevision: main#targetRevision: $(REVISION)#' \
	  -e 's#langfuseURL: .*#langfuseURL: $(LANGFUSE_URL)#' deploy/bootstrap/root-app.yaml \
	  | $(KUBECTL) apply -f -

# Ждём, пока все Application платформы станут Synced и Healthy.
wait:
	@echo "ждём Synced/Healthy (до $(WAIT_TIMEOUT)s)"
	@end=$$(( $$(date +%s) + $(WAIT_TIMEOUT) )); \
	while :; do \
	  pending=''; \
	  for app in $(APPS); do \
	    s=$$($(KUBECTL) -n argocd get application $$app \
	      -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true); \
	    [ "$$s" = Synced/Healthy ] || pending="$$pending $$app=$${s:-missing}"; \
	  done; \
	  if [ -z "$$pending" ]; then echo "все Application платформы готовы"; break; fi; \
	  if [ $$(date +%s) -ge $$end ]; then echo "timeout:$$pending"; exit 1; fi; \
	  sleep 5; \
	done

status:
	@$(KUBECTL) -n argocd get applications
	@$(KUBECTL) get pods -n llm
	@$(KUBECTL) get pods -n langfuse
	@$(KUBECTL) get pods -n monitoring
	@$(KUBECTL) get pods -n platform
	@echo "Argo CD UI: $(ARGOCD_URL) (admin, пароль: make argocd-password)"
	@echo "Prometheus: $(PROMETHEUS_URL)"
	@echo "Langfuse:   $(LANGFUSE_URL) (admin@llm-platform.local, make langfuse-password)"
	@echo "LiteLLM:    $(LITELLM_URL)/ui (admin, make litellm-password)"
	@echo "Embeddings: $(EMBEDDINGS_URL)/health (alias embed в LiteLLM)"
	@echo "Grafana:    $(GRAFANA_URL) (admin, make grafana-password)"
	@echo "ClickHouse: $(CLICKHOUSE_URL)/play, native $(CLICKHOUSE_TCP) (clickhouse, make clickhouse-password)"
	@echo "Postgres:   postgres.platform:5432 (БД тенантов, make postgres-password)"
	@echo "Тенанты:    $(TENANT_PORTS)"

# Virtual key, проект Langfuse и Secret platform-llm в namespace тенанта. Идемпотентна:
# повторный запуск не пересоздаёт ключи, только копирует platform-llm.
tenant:
	@test -n "$(NAME)" || { echo "укажите NAME=<tenant> [NS=] [BUDGET=] [MODELS=]" >&2; exit 1; }
	@KUBECTL="$(KUBECTL)" $(SECRETS_BACKUP) LITELLM_URL=$(LITELLM_URL) LANGFUSE_URL=$(LANGFUSE_URL) scripts/tenant.sh '$(NAME)' '$(NS)' '$(BUDGET)' '$(MODELS)'

# Удаляет тенанта: ключ LiteLLM, проект Langfuse, namespace и llm/tenant-<name>. Без
# CONFIRM=<name> только показывает, что будет удалено: make tenant-delete NAME=agent CONFIRM=agent
tenant-delete:
	@test -n "$(NAME)" || { echo "укажите NAME=<tenant> [CONFIRM=<tenant>]" >&2; exit 1; }
	@KUBECTL="$(KUBECTL)" $(SECRETS_BACKUP) LITELLM_URL=$(LITELLM_URL) LANGFUSE_URL=$(LANGFUSE_URL) \
	  scripts/tenant-delete.sh '$(NAME)' '$(CONFIRM)'

# Virtual key тенанта (для приложений вне кластера): make tenant-key NAME=layers
tenant-key:
	@test -n "$(NAME)" || { echo "укажите NAME=<tenant>" >&2; exit 1; }
	@$(KUBECTL) -n llm get secret tenant-$(NAME) -o jsonpath='{.data.LLM_API_KEY}' | base64 -d; echo

# Бюджет virtual key тенанта в долларах: make llm-budget KEY=agent BUDGET=0
llm-budget:
	@test -n "$(KEY)" || { echo "укажите KEY=<alias тенанта>" >&2; exit 1; }
	@test -n "$(BUDGET)" || { echo "укажите BUDGET=<usd>" >&2; exit 1; }
	@KUBECTL="$(KUBECTL)" LITELLM_URL=$(LITELLM_URL) scripts/llm-budget.sh '$(KEY)' '$(BUDGET)'

# kubectl-плагин Argo Rollouts версии контроллера: get, promote, abort, retry выкатки тенанта.
tools:
	@KUBECTL="$(KUBECTL)" scripts/rollouts-plugin.sh '$(ROLLOUTS_PLUGIN)' '$(TOOLS_DIR)'

argocd-password:
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \
	  | base64 -d; echo

langfuse-password:
	@$(KUBECTL) -n langfuse get secret langfuse-init \
	  -o jsonpath='{.data.LANGFUSE_INIT_USER_PASSWORD}' | base64 -d; echo

# Master key LiteLLM, он же пароль admin в UI
litellm-password:
	@$(KUBECTL) -n llm get secret litellm \
	  -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d; echo

# Без CH_USER — пароль администратора clickhouse (им ходит Langfuse), с CH_USER — пароль
# пользователя из deploy/clickhouse: make clickhouse-password CH_USER=layers_writer
clickhouse-password:
	@if [ -z '$(CH_USER)' ]; then \
	  $(KUBECTL) -n platform get secret clickhouse-auth -o jsonpath='{.data.password}'; \
	else \
	  $(KUBECTL) -n platform get secret clickhouse-users -o jsonpath='{.data.$(CH_USER)}'; \
	fi | base64 -d; echo

# Пароль суперпользователя общего Postgres тенантов (Secret platform/postgres).
postgres-password:
	@$(KUBECTL) -n platform get secret postgres -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo

grafana-password:
	@$(KUBECTL) -n monitoring get secret grafana-admin \
	  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# Токен service account Grafana для заливки дашбордов проекта в папку NAME:
# make grafana-token NAME=layers. Повторный запуск печатает сохранённый токен.
grafana-token:
	@test -n "$(NAME)" || { echo "укажите NAME=<project>" >&2; exit 1; }
	@KUBECTL="$(KUBECTL)" $(SECRETS_BACKUP) GRAFANA_URL=$(GRAFANA_URL) scripts/grafana-token.sh '$(NAME)'
