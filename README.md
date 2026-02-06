# Vault Unsealer for Kubernetes

A lightweight Kubernetes tool that automatically detects and unseals HashiCorp Vault pods with multiple operation modes.

## Helm chart description
Automated Vault unsealer for Kubernetes with CronJob, Watcher, and on-demand modes.

## 🎯 Features

- ✅ Auto-detect Vault pods via label selectors

- ✅ Unseal all pods in a namespace

- ✅ CronJob mode for periodic unsealing

- ✅ Watcher mode for real-time unsealing

- ✅ Manual on-demand unsealing

- ✅ Built-in health checks

- ✅ RBAC-ready

- ✅ Security-hardened

- ✅ JSON output support

- ✅ Minimal dependencies

## 📋 Requirements

- Kubernetes cluster (1.19+)
- kubectl configured
- Docker (for building images)
- Python 3.11+ (for local development)

## 🚀 Quick Start

### 1. Prepare unseal keys

```bash
# Expose keys environment variables
export VAULT_UNSEAL_KEY_1="your-key-1"
export VAULT_UNSEAL_KEY_2="your-key-2"
export VAULT_UNSEAL_KEY_3="your-key-3"
```

## 📦 Deployment Options


### Using Helm

```bash
# Install with Helm
helm install vault-unsealer ./helm-chart \
  --namespace vault \
  --set vault.unsealKeys[0]="key1" \
  --set vault.unsealKeys[1]="key2" \
  --set vault.unsealKeys[2]="key3"
```

## 🔧 Configuration

## 🔍 Monitoring và Troubleshooting

### Xem logs

```bash
# Watcher logs
kubectl logs -f -n vault -l component=watcher

# CronJob logs
kubectl logs -n vault -l component=job --tail=100

# Specific job
kubectl logs -n vault job/vault-unsealer-xxxxx
```

### Check status

```bash
# All unsealer resources
kubectl get all -n vault -l app=vault-unsealer

# CronJob
kubectl get cronjobs -n vault

# Jobs history
kubectl get jobs -n vault -l component=job

# Watcher deployment
kubectl get deployment vault-unsealer-watcher -n vault
```

### Troubleshooting

#### The unsealer cannot find any pods

```bash
# Check label Vault pods
kubectl get pods -n vault --show-labels

# Update label selector in ConfigMap
kubectl edit configmap vault-unsealer-config -n vault
# Sửa VAULT_LABEL_SELECTOR
```

#### Permission errors

```bash
# Check RBAC
kubectl describe role vault-unsealer -n vault
kubectl describe rolebinding vault-unsealer -n vault

# Test permissions
kubectl auth can-i list pods \
  --as=system:serviceaccount:vault:vault-unsealer \
  -n vault
```

#### Unsealer can't connect Vault

```bash
# Check Vault pods
kubectl get pods -n vault

# Check Vault service
kubectl get svc -n vault

# Test connectivity từ unsealer pod
kubectl run -it --rm debug \
  --image=curlimages/curl \
  --restart=Never \
  -- curl -v http://vault-0.vault-internal.vault.svc.cluster.local:8200/v1/sys/health
```

#### Invalid keys

```bash
# Verify secret
kubectl get secret vault-unseal-keys -n vault -o yaml

# Update keys
./deploy.sh update-keys
```

## 🏗️ Build Custom Image

### Build locally

```bash
# Build
docker build -f Dockerfile.k8s -t vault-k8s-unsealer:latest .

# Test locally
docker run --rm vault-k8s-unsealer:latest --help

# Tag for registry
docker tag vault-k8s-unsealer:latest your-registry/vault-k8s-unsealer:v1.0.0

# Push
docker push your-registry/vault-k8s-unsealer:v1.0.0
```

## 📊 Usage Examples

### CronJob - Unseal schedule

The unsealer runs every 5 minutes (by default) and unseals any pods that are sealed.

```yaml
schedule: "*/5 * * * *"  # Every 5 mintues
```

Customize schedule:

```bash
kubectl edit cronjob vault-unsealer -n vault
# Sửa .spec.schedule
```

### Watcher - Real-time monitoring

The watcher deployment runs continuously and checks every 30 seconds.

```bash
# Check logs real-time
kubectl logs -f -n vault deployment/vault-unsealer-watcher

# Scale watcher
kubectl scale deployment vault-unsealer-watcher --replicas=1 -n vault
```

### Health check only

```bash
# Run as job
kubectl run vault-health-check \
  --rm -it \
  --image=your-registry/vault-k8s-unsealer:latest \
  --restart=Never \
  --env="VAULT_NAMESPACE=vault" \
  -- --health-check --json
```


## 📜 License

MIT License

## 🤝 Contributing

Contributions welcome! Please submit PR.
