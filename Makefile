CLUSTER   ?= observability
NAMESPACE ?= monitoring

# Chart versions are pinned so a run today gives the same result next month.
KPS_CHART_VERSION   ?= 93.9.0
ALLOY_CHART_VERSION ?= 1.16.0

PROM_POD := prometheus-kps-prometheus-0

# Every command is pinned to the kind cluster, so a different current kubectl
# context can never receive the installs.
CONTEXT := kind-$(CLUSTER)
KUBECTL := kubectl --context $(CONTEXT)
HELM    := helm --kube-context $(CONTEXT)

.DEFAULT_GOAL := help
.NOTPARALLEL:
.PHONY: help up down cluster repos namespace secret prometheus tempo alloy slo \
        smoke lint render grafana-password port-forward-grafana

help: ## Show this list
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-22s %s\n", $$1, $$2}'

up: cluster repos namespace secret prometheus tempo alloy slo ## Create the kind cluster and install the whole stack
	@echo "Stack is up. Next: make smoke, then make port-forward-grafana"

down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)

cluster: ## Create the kind cluster if it does not exist
	@kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config kind/cluster.yaml

repos: ## Add and update the Helm repositories
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo update

namespace: ## Create the namespace
	$(KUBECTL) create namespace $(NAMESPACE) --dry-run=client -o yaml | $(KUBECTL) apply -f -

secret: ## Create the Grafana admin Secret with a random password, if it is missing
	@$(KUBECTL) -n $(NAMESPACE) get secret grafana-admin >/dev/null 2>&1 || \
		$(KUBECTL) -n $(NAMESPACE) create secret generic grafana-admin \
			--from-literal=admin-user=admin \
			--from-literal=admin-password="$$(openssl rand -base64 18)"

prometheus: ## Install kube-prometheus-stack (Prometheus, Alertmanager, Grafana)
	$(HELM) upgrade --install kps prometheus-community/kube-prometheus-stack \
		--version $(KPS_CHART_VERSION) --namespace $(NAMESPACE) \
		--values prometheus/values.yaml --wait --timeout 10m

tempo: ## Install Tempo
	$(KUBECTL) apply -f tempo/tempo.yaml
	$(KUBECTL) -n $(NAMESPACE) rollout status deployment/tempo --timeout=180s

alloy: ## Install Grafana Alloy with the pipeline in alloy/config.alloy
	$(HELM) upgrade --install alloy grafana/alloy \
		--version $(ALLOY_CHART_VERSION) --namespace $(NAMESPACE) \
		--values alloy/values.yaml \
		--set-file alloy.configMap.content=alloy/config.alloy \
		--wait --timeout 5m

slo: ## Install the SLO recording rules and burn-rate alerts
	$(HELM) upgrade --install slo charts/slo-rules --namespace $(NAMESPACE) --wait

smoke: ## Send test traces and metrics through Alloy and check the metric in Prometheus
	-$(KUBECTL) -n $(NAMESPACE) delete job telemetrygen --ignore-not-found
	$(KUBECTL) apply -f examples/telemetrygen.yaml
	$(KUBECTL) -n $(NAMESPACE) wait --for=condition=complete job/telemetrygen --timeout=180s
	@sleep 5
	@echo "Metric 'gen' in Prometheus:"
	$(KUBECTL) -n $(NAMESPACE) exec $(PROM_POD) -c prometheus -- \
		wget -qO- 'http://localhost:9090/api/v1/query?query=gen'
	@echo
	@echo "For the traces open Grafana > Explore > Tempo and search service.name = telemetrygen"

lint: ## Lint and render the Helm chart
	helm lint charts/slo-rules
	helm template slo charts/slo-rules > /dev/null

render: ## Print the rendered PrometheusRule
	helm template slo charts/slo-rules

grafana-password: ## Print the Grafana admin password
	@$(KUBECTL) -n $(NAMESPACE) get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

port-forward-grafana: ## Open Grafana on http://localhost:3000 (user: admin)
	$(KUBECTL) -n $(NAMESPACE) port-forward svc/kps-grafana 3000:80
