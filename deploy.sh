#!/usr/bin/env bash
# deploy.sh — Setup automatico cluster Kind per Market Predictor v2
# Requisiti: kind, kubectl, docker installati e nel PATH

set -euo pipefail

# ── Parametri ─────────────────────────────────────────────────────────────────
CLUSTER_NAME="${1:-marketpred-v2}"
K8S_DIR="${2:-./k8s}"
FRONTEND_PORT="${3:-8080}"
HEADLAMP_PORT="${4:-4444}"

# ── Colori ────────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}>>> $1${NC}"; }
ok()    { echo -e "    ${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "    ${YELLOW}[!!]${NC} $1"; }
fail()  { echo -e "    ${RED}[ERR]${NC} $1"; exit 1; }

# ── 0. Prerequisiti ───────────────────────────────────────────────────────────
step "Verifica prerequisiti"
for tool in kind kubectl docker; do
    command -v "$tool" &>/dev/null || fail "$tool non trovato nel PATH"
    ok "$tool trovato"
done

# ── 1. Elimina cluster esistente se presente ──────────────────────────────────
step "Pulizia cluster esistente"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '$CLUSTER_NAME' gia esistente — eliminazione in corso..."
    kind delete cluster --name "$CLUSTER_NAME"
    ok "Cluster eliminato"
else
    ok "Nessun cluster esistente da eliminare"
fi

# ── 2. Crea cluster ───────────────────────────────────────────────────────────
step "Creazione cluster Kind '$CLUSTER_NAME'"
kind create cluster --name "$CLUSTER_NAME" --config "$K8S_DIR/kind-config.yaml"
ok "Cluster creato"

# ── 3. Load immagini Docker nel cluster ───────────────────────────────────────
step "Caricamento immagini Docker nel cluster"
images=(
    "market-predictor-v2-db"
    "market-predictor-v2-ingestion"
    "market-predictor-v2-backend"
    "market-predictor-v2-frontend"
)
for img in "${images[@]}"; do
    echo "    Loading $img..."
    kind load docker-image "$img" --name "$CLUSTER_NAME"
    ok "$img caricato"
done

# ── 4. Apply manifest nell'ordine corretto ────────────────────────────────────
step "Apply manifest Kubernetes"

# Manifest specifico per kind: include gia nodeSelector ingress-ready=true
# MA il pod potrebbe schedulare su un worker — applichiamo il patch dopo
echo "    Applying ingress-nginx controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

kubectl apply -f "$K8S_DIR/metrics-server.yaml"
ok "metrics-server applicato"

kubectl apply -f "$K8S_DIR/secret.yaml"
ok "secret applicato"

kubectl apply -f https://raw.githubusercontent.com/kinvolk/headlamp/main/kubernetes-headlamp.yaml
kubectl -n kube-system create serviceaccount headlamp-admin --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding headlamp-admin \
    --serviceaccount=kube-system:headlamp-admin \
    --clusterrole=cluster-admin \
    --dry-run=client -o yaml | kubectl apply -f -
ok "headlamp applicato"

kubectl apply -f "$K8S_DIR/postgres-db.yaml"
ok "postgres applicato"

# ── 5. Patch ingress-nginx: forza sul control-plane ───────────────────────────
step "Patch ingress-nginx → control-plane (ingress-ready=true)"
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/nodeSelector",
    "value": {
      "kubernetes.io/os": "linux",
      "ingress-ready": "true"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/tolerations",
    "value": [
      {
        "key": "node-role.kubernetes.io/control-plane",
        "operator": "Equal",
        "effect": "NoSchedule"
      }
    ]
  }
]'
ok "Patch applicato"

# ── 6. Attendi ingress-nginx ready sul control-plane ──────────────────────────
step "Attesa ingress-nginx ready sul control-plane"
kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=120s
ok "ingress-nginx pronto"

# Verifica che giri sul control-plane
NGINX_NODE=$(kubectl get pods -n ingress-nginx -o jsonpath='{.items[0].spec.nodeName}')
ok "ingress-nginx schedulato su: $NGINX_NODE"
if [[ "$NGINX_NODE" != *"control-plane"* ]]; then
    warn "Attenzione: il pod non e sul control-plane, il port mapping potrebbe non funzionare"
fi

# ── 7. Attendi postgres ready ─────────────────────────────────────────────────
step "Attesa postgres ready"
kubectl wait --for=condition=ready pod --selector=app=db --timeout=120s
ok "Postgres pronto"

# ── 8. Apply job ingestion e servizi ──────────────────────────────────────────
kubectl apply -f "$K8S_DIR/ingestion-job.yaml"
ok "ingestion job applicato"

kubectl apply -f "$K8S_DIR/backend.yaml"
ok "backend applicato"

kubectl apply -f "$K8S_DIR/frontend.yaml"
ok "frontend applicato"

kubectl apply -f "$K8S_DIR/hpa-backend.yaml"
ok "hpa applicato"

kubectl apply -f "$K8S_DIR/ingress.yaml"
ok "ingress applicato"

# ── 9. Attendi backend e frontend ready ───────────────────────────────────────
step "Attesa backend ready"
kubectl wait --for=condition=ready pod --selector=app=backend --timeout=180s
ok "Backend pronto"

step "Attesa frontend ready"
kubectl wait --for=condition=ready pod --selector=app=frontend --timeout=180s
ok "Frontend pronto"

# ── 10. Verifica finale ───────────────────────────────────────────────────────
step "Stato finale cluster"
kubectl get pods -o wide
echo ""
kubectl get pods -n ingress-nginx -o wide
echo ""
kubectl get svc
echo ""
kubectl get hpa
echo ""
kubectl get ingress

# ── 11. Port-forward headlamp in background ───────────────────────────────────
step "Avvio port-forward Headlamp"
kubectl port-forward -n kube-system service/headlamp "$HEADLAMP_PORT:80" &
HEADLAMP_PID=$!
ok "Headlamp disponibile su http://localhost:$HEADLAMP_PORT (PID $HEADLAMP_PID)"

# ── 12. Token headlamp ────────────────────────────────────────────────────────
step "Token di accesso Headlamp"
kubectl -n kube-system create token headlamp-admin

# ── Verifica hosts ────────────────────────────────────────────────────────────
step "Verifica file hosts"
if grep -q "marketpred.local" /etc/hosts 2>/dev/null; then
    ok "marketpred.local trovato nel file hosts"
else
    warn "Aggiungi al file /etc/hosts: 127.0.0.1 marketpred.local"
fi

echo -e "\n${GREEN}========================================"
echo "  Cluster pronto!"
echo "  Frontend  -> http://marketpred.local:$FRONTEND_PORT"
echo "  Headlamp  -> http://localhost:$HEADLAMP_PORT"
echo -e "========================================${NC}\n"
