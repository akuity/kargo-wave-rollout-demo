SHELL := /bin/bash
S := scripts

.PHONY: help up status watch release promote ui down

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

up: ## Build everything (or finish a partial build); every Stage ends on the baseline
	@$(S)/up.sh

status: ## Every Stage's Freight, verification and health
	@$(S)/status.sh

watch: ## status, refreshed every 5s
	@while :; do clear; $(S)/status.sh; sleep 5; done

release: ## New Freight for a rollouts-demo tag: make release TAG=green
	@test -n "$(TAG)" || { echo "usage: make release TAG=green"; exit 2; }
	@$(S)/release.sh $(TAG)

promote: ## Promote a release to a Stage: make promote STAGE=qa [TAG=green]
	@test -n "$(STAGE)" || { echo "usage: make promote STAGE=qa [TAG=green]"; exit 2; }
	@$(S)/promote.sh $(STAGE) $(TAG)

ui: ## Port-forward the app UIs (:8080) and Prometheus (:9090)
	@$(S)/ui.sh

down: ## Delete everything the demo created
	@$(S)/down.sh --yes
