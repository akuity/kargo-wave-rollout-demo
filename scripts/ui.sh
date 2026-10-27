#!/usr/bin/env bash
# Port-forward the ingress controller (app UIs) and Prometheus to localhost. Ctrl-C to stop.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
echo "App UIs:    http://demo-<stage>.localhost:8080/   e.g. http://demo-prod-wave1.localhost:8080/"
echo "Prometheus: http://localhost:9090/"
kubectl --context "$KCTX" -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80 >/dev/null &
kubectl --context "$KCTX" -n monitoring port-forward svc/prometheus-server 9090:80 >/dev/null &
trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM
wait
