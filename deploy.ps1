# deploy.ps1 — Setup automatico cluster Kind per Market Predictor v2
# Requisiti: kind, kubectl, docker installati e nel PATH

param(
    [string]$ClusterName = "marketpred-v2",
    [string]$K8sDir = ".\k8s",
    [int]$FrontendPort = 8080,
    [int]$HeadlampPort = 4444
)

$ErrorActionPreference = "Stop"

# ── Colori per output leggibile ───────────────────────────────────────────────
function Write-Step  { param($msg) Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "    [ERR] $msg" -ForegroundColor Red; exit 1 }

# ── 0. Prerequisiti ───────────────────────────────────────────────────────────
Write-Step "Verifica prerequisiti"
foreach ($tool in @("kind", "kubectl", "docker")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Fail "$tool non trovato nel PATH"
    }
    Write-Ok "$tool trovato"
}

# ── 1. Elimina cluster esistente se presente ──────────────────────────────────
Write-Step "Pulizia cluster esistente"
$existing = kind get clusters 2>$null | Where-Object { $_ -eq $ClusterName }
if ($existing) {
    Write-Warn "Cluster '$ClusterName' gia esistente — eliminazione in corso..."
    kind delete cluster --name $ClusterName
    Write-Ok "Cluster eliminato"
} else {
    Write-Ok "Nessun cluster esistente da eliminare"
}

# ── 2. Crea cluster ───────────────────────────────────────────────────────────
Write-Step "Creazione cluster Kind '$ClusterName'"
kind create cluster --name $ClusterName --config "$K8sDir\kind-config.yaml"
Write-Ok "Cluster creato"

# ── 3. Load immagini Docker nel cluster ───────────────────────────────────────
Write-Step "Caricamento immagini Docker nel cluster"
$images = @(
    "market-predictor-v2-db",
    "market-predictor-v2-ingestion",
    "market-predictor-v2-backend",
    "market-predictor-v2-frontend"
)
foreach ($img in $images) {
    Write-Host "    Loading $img..." -ForegroundColor Gray
    kind load docker-image $img --name $ClusterName
    Write-Ok "$img caricato"
}

# ── 4. Apply manifest nell'ordine corretto ────────────────────────────────────
Write-Step "Apply manifest Kubernetes"

# Manifest specifico per kind: include gia nodeSelector ingress-ready=true
# MA il pod potrebbe schedulare su un worker — applichiamo il patch dopo
Write-Host "    Applying ingress-nginx controller..." -ForegroundColor Gray
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# metrics-server
kubectl apply -f "$K8sDir\metrics-server.yaml"
Write-Ok "metrics-server applicato"

# secret
kubectl apply -f "$K8sDir\secret.yaml"
Write-Ok "secret applicato"

# headlamp
kubectl apply -f https://raw.githubusercontent.com/kinvolk/headlamp/main/kubernetes-headlamp.yaml
kubectl -n kube-system create serviceaccount headlamp-admin --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding headlamp-admin `
    --serviceaccount=kube-system:headlamp-admin `
    --clusterrole=cluster-admin `
    --dry-run=client -o yaml | kubectl apply -f -
Write-Ok "headlamp applicato"

# postgres
kubectl apply -f "$K8sDir\postgres-db.yaml"
Write-Ok "postgres applicato"

# ── 5. Patch ingress-nginx: forza sul control-plane ───────────────────────────
Write-Step "Patch ingress-nginx → control-plane (ingress-ready=true)"
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
Write-Ok "Patch applicato"

# ── 6. Attendi ingress-nginx ready sul control-plane ──────────────────────────
Write-Step "Attesa ingress-nginx ready sul control-plane"
kubectl wait --namespace ingress-nginx `
    --for=condition=ready pod `
    --selector=app.kubernetes.io/component=controller `
    --timeout=120s
Write-Ok "ingress-nginx pronto"

# Verifica che giri sul control-plane
$nginxNode = kubectl get pods -n ingress-nginx -o jsonpath='{.items[0].spec.nodeName}'
Write-Ok "ingress-nginx schedulato su: $nginxNode"
if ($nginxNode -notlike "*control-plane*") {
    Write-Warn "Attenzione: il pod non e sul control-plane, il port mapping potrebbe non funzionare"
}

# ── 7. Attendi postgres ready ─────────────────────────────────────────────────
Write-Step "Attesa postgres ready"
kubectl wait --for=condition=ready pod --selector=app=db --timeout=120s
Write-Ok "Postgres pronto"

# ── 8. Apply job ingestion e servizi ──────────────────────────────────────────
kubectl apply -f "$K8sDir\ingestion-job.yaml"
Write-Ok "ingestion job applicato"

kubectl apply -f "$K8sDir\backend.yaml"
Write-Ok "backend applicato"

kubectl apply -f "$K8sDir\frontend.yaml"
Write-Ok "frontend applicato"

kubectl apply -f "$K8sDir\hpa-backend.yaml"
Write-Ok "hpa applicato"

kubectl apply -f "$K8sDir\ingress.yaml"
Write-Ok "ingress applicato"

# ── 9. Attendi backend e frontend ready ───────────────────────────────────────
Write-Step "Attesa backend ready"
kubectl wait --for=condition=ready pod --selector=app=backend --timeout=180s
Write-Ok "Backend pronto"

Write-Step "Attesa frontend ready"
kubectl wait --for=condition=ready pod --selector=app=frontend --timeout=180s
Write-Ok "Frontend pronto"

# ── 10. Verifica finale ───────────────────────────────────────────────────────
Write-Step "Stato finale cluster"
kubectl get pods -o wide
Write-Host ""
kubectl get pods -n ingress-nginx -o wide
Write-Host ""
kubectl get svc
Write-Host ""
kubectl get hpa
Write-Host ""
kubectl get ingress

# ── 11. Port-forward headlamp in background ───────────────────────────────────
Write-Step "Avvio port-forward Headlamp"
Start-Process kubectl -ArgumentList "port-forward -n kube-system service/headlamp $HeadlampPort`:80" -WindowStyle Hidden
Write-Ok "Headlamp disponibile su http://localhost:$HeadlampPort"

# ── 12. Token headlamp ────────────────────────────────────────────────────────
Write-Step "Token di accesso Headlamp"
kubectl -n kube-system create token headlamp-admin

# ── Verifica hosts ────────────────────────────────────────────────────────────
Write-Step "Verifica file hosts"
$hostsContent = Get-Content "C:\Windows\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue
if ($hostsContent -match "marketpred\.local") {
    Write-Ok "marketpred.local trovato nel file hosts"
} else {
    Write-Warn "Aggiungi al file hosts (come Amministratore):"
    Write-Warn "  127.0.0.1 marketpred.local"
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Cluster pronto!" -ForegroundColor Green
Write-Host "  Frontend  -> http://marketpred.local:$FrontendPort" -ForegroundColor Green
Write-Host "  Headlamp  -> http://localhost:$HeadlampPort" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
