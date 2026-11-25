SHELL := /bin/bash
S := scripts

.PHONY: help up status watch release flag promote functions ui down

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

up: ## Build everything (or finish a partial build); every Stage ends on the baseline
	@$(S)/up.sh

status: ## Every Stage's Freight, verification and health
	@$(S)/status.sh

watch: ## status, refreshed every 5s
	@while :; do clear; $(S)/status.sh; sleep 5; done

release: ## New Freight for a tag, any number of times: make release TAG=green [FLAGS="CHECKOUT_V2=on"] [LANE=fn]
	@test -n "$(TAG)" || { echo "usage: make release TAG=green [FLAGS=\"CHECKOUT_V2=on DARK_MODE=off\"] [LANE=fn]"; exit 2; }
	@$(S)/release.sh $(or $(LANE),web) $(TAG) $(FLAGS)

flag: ## Change a feature flag (web lane); new Freight: make flag NAME=CHECKOUT_V2 VALUE=on
	@test -n "$(NAME)" -a -n "$(VALUE)" || { echo "usage: make flag NAME=CHECKOUT_V2 VALUE=on"; exit 2; }
	@$(S)/flag.sh $(NAME) $(VALUE)

promote: ## Promote to a Stage: make promote STAGE=qa [TAG=green or a Freight alias]  (fn-* Stages are the Lambda lane)
	@test -n "$(STAGE)" || { echo "usage: make promote STAGE=qa [TAG=green]"; exit 2; }
	@$(S)/promote.sh $(STAGE) $(TAG)

functions: ## The simulated Lambda: which version each function/region alias points at
	@kubectl --context kind-$${CLUSTER:-waves} -n lambda-sim exec deploy/lambda-sim -- \
	  python -c 'import urllib.request; print(urllib.request.urlopen("http://localhost:8080/").read().decode())' \
	  | jq -r 'to_entries[] | "\(.key)\tv\(.value.version)\t\(.value.image)\t\(.value.updatedAt)"' | column -t

ui: ## Port-forward the app UIs (:8080) and Prometheus (:9090)
	@$(S)/ui.sh

down: ## Delete everything the demo created
	@$(S)/down.sh --yes
