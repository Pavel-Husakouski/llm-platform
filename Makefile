# Платформа в kind: make up поднимает кластер и Argo CD, остальное Argo CD синхронизирует из
# git. Тенанты подключаются через make tenant и кладут свои Application в тот же Argo CD.
# Ключ DeepSeek берётся только из переменной окружения DEEPSEEK_API_KEY, .env не читается.
# Остальные секреты (LiteLLM, Langfuse) make secret генерирует сам, один раз.

CLUSTER        := llm-platform
KIND_CONFIG    := deploy/kind/cluster.yaml
KIND_IMAGE     := kindest/node:v1.37.0
ARGOCD_CHART   := 10.11.6
ARGOCD_REPO    := https://argoproj.github.io/argo-helm
# Ветка, из которой Argo CD берёт deploy/: make up REVISION=feature-x
REVISION       ?= main
WAIT_TIMEOUT   ?= 900
# Application платформы: make wait не ждёт Application тенантов.
APPS           := llm-platform argo-rollouts prometheus clickhouse langfuse litellm

# make tenant NAME=agent NS=agent BUDGET=1 MODELS=deepseek-flash
NS             ?= $(NAME)
BUDGET         ?= 1
MODELS         ?= deepseek-flash

KUBECTL := kubectl --context kind-$(CLUSTER)
HELM    := helm --kube-context kind-$(CLUSTER)

.PHONY: up down cluster secret argocd root wait status tenant llm-budget argocd-password \
  langfuse-password litellm-password clickhouse-password

up: cluster secret argocd root wait status

down:
	kind delete cluster --name $(CLUSTER)

cluster:
	@if kind get clusters | grep -qx '$(CLUSTER)'; then \
	  echo "cluster $(CLUSTER) уже есть"; \
	else \
	  kind create cluster --config $(KIND_CONFIG) --image $(KIND_IMAGE); \
	fi

secret:
	@KUBECTL="$(KUBECTL)" scripts/platform-secrets.sh

argocd:
	$(HELM) upgrade --install argocd argo-cd --repo $(ARGOCD_REPO) --version $(ARGOCD_CHART) \
	  --namespace argocd --create-namespace \
	  --values deploy/bootstrap/argocd-values.yaml --wait --timeout 10m

root:
	sed 's/targetRevision: main/targetRevision: $(REVISION)/' deploy/bootstrap/root-app.yaml \
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
	@echo "Argo CD UI: http://localhost:18080 (admin, пароль: make argocd-password)"
	@echo "Prometheus: http://localhost:19090"
	@echo "Langfuse:   http://localhost:13300 (admin@llm-platform.local, make langfuse-password)"
	@echo "LiteLLM:    http://localhost:14000/ui (admin, make litellm-password)"
	@echo "ClickHouse: http://localhost:18123/play, native :19000 (clickhouse, make clickhouse-password)"

# Virtual key, проект Langfuse и Secret platform-llm в namespace тенанта. Идемпотентна:
# повторный запуск не пересоздаёт ключи, только копирует platform-llm.
tenant:
	@test -n "$(NAME)" || { echo "укажите NAME=<tenant> [NS=] [BUDGET=] [MODELS=]" >&2; exit 1; }
	@KUBECTL="$(KUBECTL)" scripts/tenant.sh '$(NAME)' '$(NS)' '$(BUDGET)' '$(MODELS)'

# Бюджет virtual key тенанта в долларах: make llm-budget KEY=agent BUDGET=0
llm-budget:
	@test -n "$(KEY)" || { echo "укажите KEY=<alias тенанта>" >&2; exit 1; }
	@test -n "$(BUDGET)" || { echo "укажите BUDGET=<usd>" >&2; exit 1; }
	@KUBECTL="$(KUBECTL)" scripts/llm-budget.sh '$(KEY)' '$(BUDGET)'

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

clickhouse-password:
	@$(KUBECTL) -n langfuse get secret langfuse-clickhouse-auth \
	  -o jsonpath='{.data.password}' | base64 -d; echo
