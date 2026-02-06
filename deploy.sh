#!/bin/bash
#
# Vault Unsealer Deployment Script for Kubernetes
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="${NAMESPACE:-vault}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-your-registry}"
IMAGE_NAME="${IMAGE_NAME:-vault-k8s-unsealer}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-all}"  # all, cronjob, watcher, manual

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

check_dependencies() {
    log_step "Kiểm tra dependencies..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl không được cài đặt"
        exit 1
    fi
    
    if ! command -v docker &> /dev/null; then
        log_warn "docker không được cài đặt (chỉ cần nếu build image)"
    fi
    
    log_info "✓ Dependencies OK"
}

check_cluster_connection() {
    log_step "Kiểm tra kết nối K8s cluster..."
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Không thể kết nối đến K8s cluster"
        exit 1
    fi
    
    local context=$(kubectl config current-context)
    log_info "✓ Đã kết nối đến cluster: $context"
}

create_namespace() {
    log_step "Tạo namespace '$NAMESPACE'..."
    
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Namespace '$NAMESPACE' đã tồn tại"
    else
        kubectl create namespace "$NAMESPACE"
        log_info "✓ Đã tạo namespace '$NAMESPACE'"
    fi
}

create_secret() {
    log_step "Tạo Secret chứa unseal keys..."
    
    echo ""
    echo "Nhập unseal keys (nhấn Enter nếu muốn skip):"
    echo ""
    
    read -p "Unseal Key 1: " KEY1
    read -p "Unseal Key 2: " KEY2
    read -p "Unseal Key 3: " KEY3
    
    if [ -z "$KEY1" ] && [ -z "$KEY2" ] && [ -z "$KEY3" ]; then
        log_warn "Không có keys nào được nhập, sử dụng placeholder"
        KEY1="placeholder-key-1"
        KEY2="placeholder-key-2"
        KEY3="placeholder-key-3"
        log_warn "CHÚ Ý: Bạn cần update Secret sau khi deploy!"
    fi
    
    kubectl create secret generic vault-unseal-keys \
        --from-literal=VAULT_UNSEAL_KEY_1="$KEY1" \
        --from-literal=VAULT_UNSEAL_KEY_2="$KEY2" \
        --from-literal=VAULT_UNSEAL_KEY_3="$KEY3" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "✓ Đã tạo/update Secret"
}

build_image() {
    log_step "Build Docker image..."
    
    docker build -f Dockerfile.k8s -t "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" .
    log_info "✓ Đã build image: ${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
}

push_image() {
    log_step "Push Docker image to registry..."
    
    docker push "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    log_info "✓ Đã push image to registry"
}

update_manifests() {
    log_step "Update manifests với image mới..."
    
    sed -i.bak "s|your-registry/vault-k8s-unsealer:latest|${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}|g" vault-unsealer-k8s.yaml
    log_info "✓ Đã update manifests"
}

deploy_resources() {
    log_step "Deploy Kubernetes resources..."
    
    case $DEPLOYMENT_MODE in
        all)
            kubectl apply -f vault-unsealer-k8s.yaml
            log_info "✓ Đã deploy tất cả resources"
            ;;
        cronjob)
            kubectl apply -f vault-unsealer-k8s.yaml
            kubectl delete deployment vault-unsealer-watcher -n "$NAMESPACE" --ignore-not-found=true
            log_info "✓ Đã deploy CronJob"
            ;;
        watcher)
            kubectl apply -f vault-unsealer-k8s.yaml
            kubectl delete cronjob vault-unsealer -n "$NAMESPACE" --ignore-not-found=true
            log_info "✓ Đã deploy Watcher"
            ;;
        manual)
            log_info "Tạo manual job..."
            kubectl create job "vault-unseal-$(date +%s)" \
                --from=cronjob/vault-unsealer \
                -n "$NAMESPACE" 2>/dev/null || \
            kubectl apply -f vault-unsealer-k8s.yaml
            log_info "✓ Đã tạo manual job"
            ;;
        *)
            log_error "Invalid deployment mode: $DEPLOYMENT_MODE"
            exit 1
            ;;
    esac
}

verify_deployment() {
    log_step "Verify deployment..."
    
    echo ""
    log_info "ServiceAccount:"
    kubectl get serviceaccount vault-unsealer -n "$NAMESPACE" || true
    
    echo ""
    log_info "Secret:"
    kubectl get secret vault-unseal-keys -n "$NAMESPACE" || true
    
    if [ "$DEPLOYMENT_MODE" = "all" ] || [ "$DEPLOYMENT_MODE" = "cronjob" ]; then
        echo ""
        log_info "CronJob:"
        kubectl get cronjob vault-unsealer -n "$NAMESPACE" || true
    fi
    
    if [ "$DEPLOYMENT_MODE" = "all" ] || [ "$DEPLOYMENT_MODE" = "watcher" ]; then
        echo ""
        log_info "Deployment:"
        kubectl get deployment vault-unsealer-watcher -n "$NAMESPACE" || true
        
        echo ""
        log_info "Pods:"
        kubectl get pods -n "$NAMESPACE" -l component=watcher || true
    fi
}

show_logs() {
    log_step "Xem logs..."
    
    if [ "$DEPLOYMENT_MODE" = "watcher" ] || [ "$DEPLOYMENT_MODE" = "all" ]; then
        echo ""
        log_info "Watcher logs (Ctrl+C để thoát):"
        kubectl logs -f -n "$NAMESPACE" -l component=watcher --tail=50 || true
    fi
}

cleanup() {
    log_step "Cleanup resources..."
    
    read -p "Bạn có chắc muốn xóa tất cả unsealer resources? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        kubectl delete -f vault-unsealer-k8s.yaml || true
        log_info "✓ Đã xóa resources"
    else
        log_info "Hủy cleanup"
    fi
}

show_status() {
    log_step "Trạng thái hiện tại..."
    
    echo ""
    echo "=== Vault Pods ==="
    kubectl get pods -n "$NAMESPACE" -l app=vault
    
    echo ""
    echo "=== Unsealer Resources ==="
    kubectl get all -n "$NAMESPACE" -l app=vault-unsealer
    
    echo ""
    echo "=== Recent CronJob Runs ==="
    kubectl get jobs -n "$NAMESPACE" -l component=job --sort-by=.metadata.creationTimestamp | tail -5
}

manual_unseal() {
    log_step "Chạy manual unseal..."
    
    local job_name="vault-unseal-manual-$(date +%s)"
    
    kubectl create job "$job_name" \
        --from=cronjob/vault-unsealer \
        -n "$NAMESPACE"
    
    log_info "✓ Đã tạo job: $job_name"
    
    echo ""
    read -p "Xem logs của job? (y/n): " watch_logs
    if [ "$watch_logs" = "y" ]; then
        sleep 2
        kubectl logs -f "job/$job_name" -n "$NAMESPACE"
    fi
}

update_keys() {
    log_step "Update unseal keys..."
    
    echo ""
    echo "Nhập unseal keys mới:"
    read -p "Unseal Key 1: " KEY1
    read -p "Unseal Key 2: " KEY2
    read -p "Unseal Key 3: " KEY3
    
    kubectl create secret generic vault-unseal-keys \
        --from-literal=VAULT_UNSEAL_KEY_1="$KEY1" \
        --from-literal=VAULT_UNSEAL_KEY_2="$KEY2" \
        --from-literal=VAULT_UNSEAL_KEY_3="$KEY3" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "✓ Đã update keys"
    
    # Restart watcher nếu có
    if kubectl get deployment vault-unsealer-watcher -n "$NAMESPACE" &> /dev/null; then
        log_info "Restarting watcher deployment..."
        kubectl rollout restart deployment/vault-unsealer-watcher -n "$NAMESPACE"
    fi
}

show_help() {
    cat << EOF
Vault Unsealer Deployment Script for Kubernetes

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    deploy              Deploy unsealer to K8s (default)
    build              Build Docker image
    push               Push image to registry
    status             Show deployment status
    unseal             Run manual unseal
    logs               Show logs
    update-keys        Update unseal keys
    cleanup            Remove all unsealer resources
    help               Show this help

Options:
    -n, --namespace    Kubernetes namespace (default: vault)
    -r, --registry     Docker registry (default: your-registry)
    -t, --tag          Image tag (default: latest)
    -m, --mode         Deployment mode: all, cronjob, watcher, manual (default: all)

Environment Variables:
    NAMESPACE          Kubernetes namespace
    IMAGE_REGISTRY     Docker registry
    IMAGE_TAG          Image tag
    DEPLOYMENT_MODE    Deployment mode

Examples:
    # Deploy tất cả
    $0 deploy

    # Deploy chỉ watcher
    $0 deploy --mode watcher

    # Build và push image
    $0 build
    $0 push

    # Xem status
    $0 status

    # Manual unseal
    $0 unseal

    # Update keys
    $0 update-keys

EOF
}

# Main
main() {
    local command="${1:-deploy}"
    shift || true
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--registry)
                IMAGE_REGISTRY="$2"
                shift 2
                ;;
            -t|--tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            -m|--mode)
                DEPLOYMENT_MODE="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    case $command in
        deploy)
            check_dependencies
            check_cluster_connection
            create_namespace
            create_secret
            update_manifests
            deploy_resources
            verify_deployment
            ;;
        build)
            check_dependencies
            build_image
            ;;
        push)
            check_dependencies
            push_image
            ;;
        status)
            check_dependencies
            check_cluster_connection
            show_status
            ;;
        unseal)
            check_dependencies
            check_cluster_connection
            manual_unseal
            ;;
        logs)
            check_dependencies
            check_cluster_connection
            show_logs
            ;;
        update-keys)
            check_dependencies
            check_cluster_connection
            update_keys
            ;;
        cleanup)
            check_dependencies
            check_cluster_connection
            cleanup
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
    
    log_info "Hoàn thành!"
}

# Run main
main "$@"
