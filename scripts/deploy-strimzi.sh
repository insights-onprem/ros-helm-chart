#!/bin/bash

# Strimzi Operator and Kafka Cluster Deployment Script
# This script automates the deployment of Strimzi operator and Kafka cluster
# for the ROS-OCP platform with support for both Kubernetes/KIND and OpenShift
#
# PREREQUISITE: This script should be run BEFORE install-helm-chart.sh
#
# Typical workflow:
#   1. ./deploy-strimzi.sh         # Deploy Kafka infrastructure (this script)
#   2. ./install-helm-chart.sh     # Deploy ROS-OCP application

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - Strimzi/Kafka settings
KAFKA_NAMESPACE=${KAFKA_NAMESPACE:-kafka}
KAFKA_CLUSTER_NAME=${KAFKA_CLUSTER_NAME:-ros-ocp-kafka}
KAFKA_VERSION=${KAFKA_VERSION:-3.8.0}
STRIMZI_VERSION=${STRIMZI_VERSION:-0.45.1}
KAFKA_ENVIRONMENT=${KAFKA_ENVIRONMENT:-dev}  # "dev" or "ocp"
STORAGE_CLASS=${STORAGE_CLASS:-}  # Auto-detect if empty

# Advanced options
STRIMZI_NAMESPACE=${STRIMZI_NAMESPACE:-}  # If set, use existing Strimzi operator
KAFKA_BOOTSTRAP_SERVERS=${KAFKA_BOOTSTRAP_SERVERS:-}  # If set, use external Kafka (skip deployment)

# Platform-specific configuration (auto-detected)
PLATFORM=""

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_header() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

# Function to detect platform (Kubernetes vs OpenShift)
detect_platform() {
    echo_info "Detecting platform..."

    if kubectl get routes.route.openshift.io >/dev/null 2>&1; then
        echo_success "Detected OpenShift platform"
        PLATFORM="openshift"
        # Auto-detect default storage class if not provided
        if [ -z "$STORAGE_CLASS" ]; then
            STORAGE_CLASS=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
            if [ -n "$STORAGE_CLASS" ]; then
                echo_info "Auto-detected default storage class: $STORAGE_CLASS"
            else
                echo_warning "No default storage class found. Storage class must be explicitly set."
            fi
        fi
        if [ "$KAFKA_ENVIRONMENT" = "dev" ]; then
            KAFKA_ENVIRONMENT="ocp"
        fi
    else
        echo_success "Detected Kubernetes platform"
        PLATFORM="kubernetes"
        # Auto-detect default storage class if not provided
        if [ -z "$STORAGE_CLASS" ]; then
            STORAGE_CLASS=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
            if [ -n "$STORAGE_CLASS" ]; then
                echo_info "Auto-detected default storage class: $STORAGE_CLASS"
            fi
        fi
    fi
}

# Function to check prerequisites
check_prerequisites() {
    echo_header "CHECKING PREREQUISITES"

    # Check if kubectl is available
    if ! command -v kubectl >/dev/null 2>&1; then
        echo_error "kubectl command not found. Please install kubectl."
        exit 1
    fi
    echo_success "✓ kubectl is available"

    # Check if helm is available
    if ! command -v helm >/dev/null 2>&1; then
        echo_error "helm command not found. Please install Helm."
        exit 1
    fi
    echo_success "✓ helm is available"

    # Check kubectl connectivity
    if ! kubectl get nodes >/dev/null 2>&1; then
        echo_error "Cannot connect to cluster. Please check your kubectl configuration."
        exit 1
    fi
    echo_success "✓ Connected to cluster"

    local current_context=$(kubectl config current-context 2>/dev/null || echo "none")
    echo_info "Current kubectl context: $current_context"

    # Detect platform
    detect_platform

    # Check storage class if specified
    if [ -n "$STORAGE_CLASS" ]; then
        if kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
            echo_success "✓ Storage class '$STORAGE_CLASS' is available"
        else
            echo_warning "Storage class '$STORAGE_CLASS' not found. Available storage classes:"
            kubectl get storageclass --no-headers -o custom-columns=NAME:.metadata.name | sed 's/^/  - /' || true
        fi
    fi

    echo_success "Prerequisites check completed successfully"
}

# Function to create namespace
create_namespace() {
    echo_header "CREATING NAMESPACE"

    if kubectl get namespace "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Namespace '$KAFKA_NAMESPACE' already exists"
    else
        echo_info "Creating namespace: $KAFKA_NAMESPACE"
        kubectl create namespace "$KAFKA_NAMESPACE"
        echo_success "✓ Namespace '$KAFKA_NAMESPACE' created"
    fi
}


# Function to verify existing Strimzi operator
verify_existing_strimzi() {
    local strimzi_namespace="$1"

    echo_info "Verifying existing Strimzi operator in namespace: $strimzi_namespace"

    # Check if Strimzi operator exists
    if ! kubectl get pods -n "$strimzi_namespace" -l name=strimzi-cluster-operator >/dev/null 2>&1; then
        echo_error "Strimzi operator not found in namespace: $strimzi_namespace"
        return 1
    fi

    # Check Strimzi operator version compatibility
    echo_info "Checking Strimzi operator version compatibility..."
    local strimzi_pod=$(kubectl get pods -n "$strimzi_namespace" -l name=strimzi-cluster-operator -o jsonpath='{.items[0].metadata.name}')
    if [ -n "$strimzi_pod" ]; then
        local strimzi_image=$(kubectl get pod -n "$strimzi_namespace" "$strimzi_pod" -o jsonpath='{.spec.containers[0].image}')
        echo_info "Found Strimzi operator image: $strimzi_image"

        # Check if it's a compatible version (should contain 0.45.x for Kafka 3.8.0 support)
        if [[ "$strimzi_image" =~ :0\.45\. ]] || [[ "$strimzi_image" =~ :0\.44\. ]] || [[ "$strimzi_image" =~ :0\.43\. ]]; then
            echo_success "Strimzi operator version is compatible with Kafka 3.8.0"
            return 0
        else
            echo_error "Strimzi operator version may not be compatible with Kafka 3.8.0"
            echo_error "Found: $strimzi_image"
            echo_error "Required: Strimzi 0.43.x, 0.44.x, or 0.45.x for Kafka 3.8.0 support"
            return 1
        fi
    fi

    return 0
}

# Function to verify existing Kafka cluster
verify_existing_kafka() {
    local kafka_namespace="$1"

    echo_info "Verifying existing Kafka cluster in namespace: $kafka_namespace"

    # Check if Kafka cluster exists
    if ! kubectl get kafka -n "$kafka_namespace" >/dev/null 2>&1; then
        echo_error "Kafka cluster not found in namespace: $kafka_namespace"
        return 1
    fi

    # Check Kafka cluster version
    echo_info "Checking Kafka cluster version compatibility..."
    local kafka_cluster=$(kubectl get kafka -n "$kafka_namespace" -o jsonpath='{.items[0].metadata.name}')
    if [ -n "$kafka_cluster" ]; then
        local kafka_version=$(kubectl get kafka -n "$kafka_namespace" "$kafka_cluster" -o jsonpath='{.spec.kafka.version}')
        echo_info "Found Kafka cluster version: $kafka_version"

        # Check if it's Kafka 3.8.0
        if [ "$kafka_version" = "3.8.0" ]; then
            echo_success "Kafka cluster version is compatible: $kafka_version"
            return 0
        else
            echo_error "Kafka cluster version is not compatible"
            echo_error "Found: $kafka_version"
            echo_error "Required: 3.8.0"
            return 1
        fi
    fi

    return 0
}

# Function to install Strimzi operator
install_strimzi_operator() {
    echo_header "INSTALLING STRIMZI OPERATOR"

    local target_namespace="$KAFKA_NAMESPACE"

    # Check if there's already a Strimzi operator we can reuse
    local existing_strimzi_ns=$(kubectl get pods -A -l name=strimzi-cluster-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")

    if [ -n "$existing_strimzi_ns" ]; then
        echo_info "Found existing Strimzi operator in namespace: $existing_strimzi_ns"

        # Verify if it's compatible
        if verify_existing_strimzi "$existing_strimzi_ns" 2>/dev/null; then
            echo_success "Existing Strimzi operator is compatible, reusing it"
            target_namespace="$existing_strimzi_ns"
            KAFKA_NAMESPACE="$target_namespace"
            return 0
        else
            echo_error "Existing Strimzi operator in namespace '$existing_strimzi_ns' is not compatible"
            echo_error "Required: Strimzi 0.43.x, 0.44.x, or 0.45.x for Kafka 3.8.0 support"
            echo_info "Run '$0 cleanup' to remove incompatible operator"
            exit 1
        fi
    fi

    echo_info "No existing Strimzi operator found, installing fresh"

    # Add Strimzi Helm repo
    echo_info "Adding Strimzi Helm repository..."
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update
    echo_success "✓ Strimzi Helm repository added"

    # Install Strimzi operator using Helm
    echo_info "Installing Strimzi operator version $STRIMZI_VERSION (supports Kafka $KAFKA_VERSION)..."
    helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
        --namespace "$target_namespace" \
        --version "$STRIMZI_VERSION" \
        --wait \
        --timeout=600s

    echo_success "✓ Strimzi operator installed"

    # Wait for Strimzi operator pod to be ready
    echo_info "Waiting for Strimzi operator to be ready..."
    local timeout=300
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if kubectl get pod -n "$target_namespace" -l name=strimzi-cluster-operator >/dev/null 2>&1; then
            if kubectl wait --for=condition=ready pod -l name=strimzi-cluster-operator -n "$target_namespace" --timeout=10s >/dev/null 2>&1; then
                echo_success "✓ Strimzi operator is ready"
                break
            fi
        fi

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo_info "Still waiting for Strimzi operator... (${elapsed}s elapsed)"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $timeout ]; then
        echo_error "Timeout waiting for Strimzi operator to be ready"
        exit 1
    fi

    # Wait for CRDs to be established
    echo_info "Waiting for Strimzi CRDs to be ready..."
    kubectl wait --for condition=established --timeout=60s crd/kafkas.kafka.strimzi.io 2>/dev/null || true
    kubectl wait --for condition=established --timeout=60s crd/kafkatopics.kafka.strimzi.io 2>/dev/null || true
    echo_success "✓ Strimzi CRDs are ready"
}

# Function to deploy Kafka cluster
deploy_kafka_cluster() {
    echo_header "DEPLOYING KAFKA CLUSTER"

    # Check if Kafka cluster already exists
    if kubectl get kafka "$KAFKA_CLUSTER_NAME" -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Kafka cluster '$KAFKA_CLUSTER_NAME' already exists in namespace '$KAFKA_NAMESPACE'"
        return 0
    fi

    # Set environment-specific Kafka configuration
    local kafka_replicas=1
    local kafka_storage_size="10Gi"
    local kafka_storage_class=""
    local zookeeper_replicas=1
    local zookeeper_storage_size="5Gi"
    local zookeeper_storage_class=""
    local tls_enabled="false"

    case "$KAFKA_ENVIRONMENT" in
        "ocp"|"openshift")
            kafka_replicas=3
            kafka_storage_size="100Gi"
            kafka_storage_class="$STORAGE_CLASS"
            zookeeper_replicas=3
            zookeeper_storage_size="20Gi"
            zookeeper_storage_class="$STORAGE_CLASS"
            tls_enabled="true"
            ;;
        "dev"|"development")
            # Use defaults
            ;;
    esac

    echo_info "Creating Kafka cluster with configuration:"
    echo_info "  Name: $KAFKA_CLUSTER_NAME"
    echo_info "  Version: $KAFKA_VERSION"
    echo_info "  Kafka replicas: $kafka_replicas"
    echo_info "  Kafka storage: $kafka_storage_size"
    if [ -n "$kafka_storage_class" ]; then
        echo_info "  Kafka storage class: $kafka_storage_class"
    fi
    echo_info "  ZooKeeper replicas: $zookeeper_replicas"
    echo_info "  ZooKeeper storage: $zookeeper_storage_size"
    if [ -n "$zookeeper_storage_class" ]; then
        echo_info "  ZooKeeper storage class: $zookeeper_storage_class"
    fi
    echo_info "  TLS enabled: $tls_enabled"

    # Build Kafka YAML
    local kafka_yaml="apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: $KAFKA_CLUSTER_NAME
  namespace: $KAFKA_NAMESPACE
spec:
  kafka:
    version: $KAFKA_VERSION
    replicas: $kafka_replicas
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false"

    # Add TLS listener if enabled
    if [ "$tls_enabled" = "true" ]; then
        kafka_yaml="$kafka_yaml
      - name: tls
        port: 9093
        type: internal
        tls: true"
    fi

    # Add storage configuration
    kafka_yaml="$kafka_yaml
    storage:
      type: persistent-claim
      size: $kafka_storage_size
      deleteClaim: false"

    # Add storage class if specified
    if [ -n "$kafka_storage_class" ]; then
        kafka_yaml="$kafka_yaml
      class: $kafka_storage_class"
    fi

    # Add Kafka configuration
    kafka_yaml="$kafka_yaml
    config:
      auto.create.topics.enable: \"true\"
      default.replication.factor: \"$kafka_replicas\"
      log.retention.hours: \"168\"
      log.segment.bytes: \"1073741824\"
      min.insync.replicas: \"$((kafka_replicas / 2 + 1))\"
      offsets.topic.replication.factor: \"$kafka_replicas\"
      transaction.state.log.min.isr: \"$((kafka_replicas / 2 + 1))\"
      transaction.state.log.replication.factor: \"$kafka_replicas\"
  zookeeper:
    replicas: $zookeeper_replicas
    storage:
      type: persistent-claim
      size: $zookeeper_storage_size
      deleteClaim: false"

    # Add Zookeeper storage class if specified
    if [ -n "$zookeeper_storage_class" ]; then
        kafka_yaml="$kafka_yaml
      class: $zookeeper_storage_class"
    fi

    # Add entity operator
    kafka_yaml="$kafka_yaml
  entityOperator:
    topicOperator: {}
    userOperator: {}"

    # Apply Kafka cluster
    if echo "$kafka_yaml" | kubectl apply -f -; then
        echo_success "✓ Kafka cluster '$KAFKA_CLUSTER_NAME' created in namespace '$KAFKA_NAMESPACE'"

        # Wait for Kafka cluster to be ready
        echo_info "Waiting for Kafka cluster to be ready (this may take several minutes)..."
        local timeout=600
        local elapsed=0

        while [ $elapsed -lt $timeout ]; do
            local status=$(kubectl get kafka "$KAFKA_CLUSTER_NAME" -n "$KAFKA_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
            if [ "$status" = "True" ]; then
                echo_success "✓ Kafka cluster is ready"
                return 0
            fi

            if [ $((elapsed % 60)) -eq 0 ]; then
                echo_info "Still waiting for Kafka cluster... (${elapsed}s elapsed)"
            fi

            sleep 10
            elapsed=$((elapsed + 10))
        done

        if [ $elapsed -ge $timeout ]; then
            echo_error "Timeout waiting for Kafka cluster to be ready"
            exit 1
        fi
    else
        echo_error "Failed to create Kafka cluster"
        exit 1
    fi
}

# Function to create Kafka topics
create_kafka_topics() {
    echo_header "CREATING KAFKA TOPICS"

    local replication_factor=1
    if [ "$KAFKA_ENVIRONMENT" = "ocp" ] || [ "$KAFKA_ENVIRONMENT" = "openshift" ]; then
        replication_factor=3
    fi

    echo_info "Creating Kafka topics with replication factor: $replication_factor"

    # Required topics (topic_name:partitions:replication_factor)
    local required_topics=(
        "hccm.ros.events:3:$replication_factor"
        "platform.sources.event-stream:3:$replication_factor"
        "rosocp.kruize.recommendations:3:$replication_factor"
        "platform.upload.announce:3:$replication_factor"
        "platform.payload-status:3:$replication_factor"
    )

    for topic_config in "${required_topics[@]}"; do
        IFS=':' read -r topic_name partitions replication_factor <<< "$topic_config"

        # Check if topic already exists
        if kubectl get kafkatopic "$topic_name" -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
            echo_info "Topic '$topic_name' already exists, skipping"
            continue
        fi

        echo_info "Creating topic: $topic_name (partitions: $partitions, replication: $replication_factor)"

        # Create topic YAML
        cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: $topic_name
  namespace: $KAFKA_NAMESPACE
  labels:
    strimzi.io/cluster: $KAFKA_CLUSTER_NAME
spec:
  partitions: $partitions
  replicas: $replication_factor
  config:
    retention.ms: "604800000"
    segment.ms: "86400000"
EOF

        if [ $? -eq 0 ]; then
            echo_success "✓ Topic '$topic_name' created"
        else
            echo_warning "Failed to create topic '$topic_name'"
        fi
    done

    echo_success "Kafka topics creation completed"
}

# Function to validate deployment
validate_deployment() {
    echo_header "VALIDATING DEPLOYMENT"

    local validation_errors=0

    # Check namespace
    if kubectl get namespace "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        echo_success "✓ Namespace '$KAFKA_NAMESPACE' exists"
    else
        echo_error "✗ Namespace '$KAFKA_NAMESPACE' not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check Strimzi operator
    if kubectl get pods -n "$KAFKA_NAMESPACE" -l name=strimzi-cluster-operator >/dev/null 2>&1; then
        local ready=$(kubectl get pods -n "$KAFKA_NAMESPACE" -l name=strimzi-cluster-operator -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$ready" = "True" ]; then
            echo_success "✓ Strimzi operator is running"
        else
            echo_error "✗ Strimzi operator is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Strimzi operator not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check Kafka cluster
    if kubectl get kafka "$KAFKA_CLUSTER_NAME" -n "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
        local status=$(kubectl get kafka "$KAFKA_CLUSTER_NAME" -n "$KAFKA_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$status" = "True" ]; then
            echo_success "✓ Kafka cluster '$KAFKA_CLUSTER_NAME' is ready"
        else
            echo_error "✗ Kafka cluster '$KAFKA_CLUSTER_NAME' is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Kafka cluster '$KAFKA_CLUSTER_NAME' not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check topics
    echo_info "Checking Kafka topics..."
    local topic_count=$(kubectl get kafkatopic -n "$KAFKA_NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$topic_count" -gt 0 ]; then
        echo_success "✓ Found $topic_count Kafka topic(s)"
        kubectl get kafkatopic -n "$KAFKA_NAMESPACE" -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].status 2>/dev/null || true
    else
        echo_warning "⚠ No Kafka topics found (may be created later)"
    fi

    if [ $validation_errors -eq 0 ]; then
        echo_success "All validation checks passed!"
        return 0
    else
        echo_error "$validation_errors validation error(s) found"
        return 1
    fi
}

# Function to display deployment summary
display_summary() {
    echo_header "DEPLOYMENT SUMMARY"

    echo_info "Strimzi/Kafka Deployment Information:"
    echo_info "  Platform: $PLATFORM"
    echo_info "  Namespace: $KAFKA_NAMESPACE"
    echo_info "  Kafka Cluster: $KAFKA_CLUSTER_NAME"
    echo_info "  Kafka Version: $KAFKA_VERSION"
    echo_info "  Strimzi Version: $STRIMZI_VERSION"
    echo ""

    # Get Kafka bootstrap servers from deployed cluster
    local kafka_bootstrap_servers=""

    # Query from Kafka resource status (most reliable - Strimzi populates this)
    local bootstrap_address=$(kubectl get kafka "$KAFKA_CLUSTER_NAME" -n "$KAFKA_NAMESPACE" -o jsonpath='{.status.listeners[?(@.name=="plain")].bootstrapServers}' 2>/dev/null || echo "")

    if [ -n "$bootstrap_address" ]; then
        # Use address from Kafka status (includes correct DNS suffix for the cluster)
        kafka_bootstrap_servers="$bootstrap_address"
        echo_info "Kafka Connection Information:"
        echo_info "  Bootstrap Servers: $kafka_bootstrap_servers"
        echo_info "  Source: Kafka cluster status"
    else
        # Fallback to short service name (works for cross-namespace communication)
        kafka_bootstrap_servers="${KAFKA_CLUSTER_NAME}-kafka-bootstrap.${KAFKA_NAMESPACE}:9092"
        echo_info "Kafka Connection Information:"
        echo_info "  Bootstrap Servers: $kafka_bootstrap_servers"
        echo_info "  Source: Service name (auto-generated)"
        echo_warning "Could not read from Kafka status, using service name fallback"
    fi
    echo ""

    # Export bootstrap servers for parent scripts
    echo "export KAFKA_BOOTSTRAP_SERVERS=\"$kafka_bootstrap_servers\"" > /tmp/kafka-bootstrap-servers.env
    echo_success "✓ Kafka bootstrap servers exported to: /tmp/kafka-bootstrap-servers.env"
    echo ""

    echo_info "Verification Commands:"
    echo_info "  kubectl get kafka -n $KAFKA_NAMESPACE"
    echo_info "  kubectl get kafkatopic -n $KAFKA_NAMESPACE"
    echo ""

    echo_info "Troubleshooting:"
    echo_info "  Kafka logs: kubectl logs -n $KAFKA_NAMESPACE -l strimzi.io/name=${KAFKA_CLUSTER_NAME}-kafka"
    echo_info "  Operator logs: kubectl logs -n $KAFKA_NAMESPACE -l name=strimzi-cluster-operator"
    echo ""

    echo_success "Kafka infrastructure deployment completed successfully!"
    echo ""
    echo_info "Next Steps:"
    echo_info "  1. (Optional) Verify Kafka cluster: kubectl get kafka $KAFKA_CLUSTER_NAME -n $KAFKA_NAMESPACE"
    echo_info "  2. Deploy ROS-OCP application: ./install-helm-chart.sh"
    echo ""
}

# Function to clean up deployment (for troubleshooting)
cleanup_deployment() {
    echo_header "CLEANING UP DEPLOYMENT"
    echo_info "Removing Strimzi and Kafka resources..."

    # Remove Kafka resources (with timeout to prevent hanging)
    kubectl delete kafka --all -A --timeout 60s 2>/dev/null || \
        kubectl patch kafka --all -A -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete kafkatopic --all -A --timeout 30s 2>/dev/null || \
        kubectl patch kafkatopic --all -A -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete kafkauser --all -A --timeout 30s 2>/dev/null || \
        kubectl patch kafkauser --all -A -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete kafkaconnect --all -A --timeout 30s 2>/dev/null || true
    kubectl delete kafkaconnector --all -A --timeout 30s 2>/dev/null || true

    # Remove Strimzi operators
    kubectl get pods -A -l name=strimzi-cluster-operator --no-headers 2>/dev/null | while read namespace pod_name rest; do
        kubectl delete deployment -n "$namespace" -l name=strimzi-cluster-operator --timeout 30s 2>/dev/null || true
        helm uninstall strimzi-kafka-operator -n "$namespace" --timeout 2m0s 2>/dev/null || true
        helm uninstall strimzi-cluster-operator -n "$namespace" --timeout 2m0s 2>/dev/null || true
    done

    # Remove RBAC resources
    kubectl delete clusterrolebinding strimzi-cluster-operator 2>/dev/null || true
    kubectl delete clusterrole strimzi-cluster-operator-global 2>/dev/null || true
    kubectl delete clusterrole strimzi-cluster-operator-leader-election 2>/dev/null || true
    kubectl delete clusterrole strimzi-cluster-operator-namespaced 2>/dev/null || true
    kubectl delete clusterrole strimzi-cluster-operator-watched 2>/dev/null || true
    kubectl delete clusterrole strimzi-entity-operator 2>/dev/null || true
    kubectl delete clusterrole strimzi-kafka-broker 2>/dev/null || true
    kubectl delete clusterrole strimzi-kafka-client 2>/dev/null || true
    kubectl delete clusterrolebinding strimzi-cluster-operator-kafka-broker-delegation 2>/dev/null || true
    kubectl delete clusterrolebinding strimzi-cluster-operator-kafka-client-delegation 2>/dev/null || true

    # Remove CRDs (with timeout to prevent hanging)
    kubectl delete crd kafkas.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkatopics.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkausers.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkaconnects.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkaconnectors.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkamirrormakers.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkamirrormaker2s.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkabridges.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkarebalances.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd kafkanodepools.kafka.strimzi.io --timeout 30s 2>/dev/null || true
    kubectl delete crd strimzipodsets.core.strimzi.io --timeout 30s 2>/dev/null || true

    # Remove namespace (with timeout to prevent hanging)
    kubectl delete namespace "$KAFKA_NAMESPACE" --timeout 60s 2>/dev/null || true

    # Wait for namespace to be fully deleted
    echo_info "Waiting for namespace to be fully deleted..."
    local timeout=120
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if ! kubectl get namespace "$KAFKA_NAMESPACE" >/dev/null 2>&1; then
            echo_success "✓ Namespace '$KAFKA_NAMESPACE' fully deleted"
            break
        fi
        if [ $((elapsed % 10)) -eq 0 ]; then
            echo_info "Still waiting for namespace deletion... (${elapsed}s elapsed)"
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ $elapsed -ge $timeout ]; then
        echo_warning "Timeout waiting for namespace deletion. Namespace may still be terminating."
        echo_info "You may need to manually remove finalizers if the namespace remains stuck."
    fi

    echo_success "Cleanup completed"
}

# Main execution function
main() {
    echo_header "STRIMZI/KAFKA DEPLOYMENT SCRIPT"

    # Handle existing Kafka on cluster (bootstrap servers provided by user)
    if [ -n "$KAFKA_BOOTSTRAP_SERVERS" ]; then
        echo_info "Using existing Kafka cluster (provided bootstrap servers)"
        echo_info ""
        echo_info "Configuration:"
        echo_info "  Bootstrap Servers: $KAFKA_BOOTSTRAP_SERVERS"
        echo_info "  Deployment: Skipped (using external Kafka)"
        echo ""

        # Export bootstrap servers for parent scripts
        echo "export KAFKA_BOOTSTRAP_SERVERS=\"$KAFKA_BOOTSTRAP_SERVERS\"" > /tmp/kafka-bootstrap-servers.env
        echo_success "✓ Kafka bootstrap servers exported to /tmp/kafka-bootstrap-servers.env"
        echo ""
        echo_success "Kafka configuration completed successfully!"
        exit 0
    fi

    echo_info "This script will deploy Strimzi operator and Kafka cluster"
    echo_info "Deployment Configuration:"
    echo_info "  Namespace: $KAFKA_NAMESPACE"
    echo_info "  Cluster Name: $KAFKA_CLUSTER_NAME"
    echo_info "  Kafka Version: $KAFKA_VERSION"
    echo_info "  Strimzi Version: $STRIMZI_VERSION"
    echo_info "  Environment: $KAFKA_ENVIRONMENT"
    if [ -n "$STORAGE_CLASS" ]; then
        echo_info "  Storage Class: $STORAGE_CLASS"
    fi
    if [ -n "$STRIMZI_NAMESPACE" ]; then
        echo_info "  Existing Strimzi: $STRIMZI_NAMESPACE"
    fi
    echo ""

    # Execute deployment steps
    check_prerequisites

    # Handle existing infrastructure if specified
    if [ -n "$STRIMZI_NAMESPACE" ]; then
        echo_info "Using existing Strimzi operator in namespace: $STRIMZI_NAMESPACE"
        if ! verify_existing_strimzi "$STRIMZI_NAMESPACE"; then
            exit 1
        fi
        if ! verify_existing_kafka "$STRIMZI_NAMESPACE"; then
            exit 1
        fi
        # Update namespace to use existing one
        KAFKA_NAMESPACE="$STRIMZI_NAMESPACE"
    else
        create_namespace
        install_strimzi_operator
        deploy_kafka_cluster
        create_kafka_topics
    fi

    # Validate and summarize
    if validate_deployment; then
        display_summary
    else
        echo_error "Deployment validation failed. Check the logs above for details."
        exit 1
    fi
}

# Handle script arguments
case "${1:-}" in
    "cleanup"|"clean")
        detect_platform
        cleanup_deployment
        exit 0
        ;;
    "validate"|"check")
        detect_platform
        validate_deployment
        exit $?
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo '  (no command)     Deploy Strimzi operator and Kafka cluster'
        echo "  validate         Validate existing deployment"
        echo "  cleanup          Remove all Strimzi and Kafka resources"
        echo "  help             Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  KAFKA_BOOTSTRAP_SERVERS Bootstrap servers for existing Kafka on cluster (skips deployment)"
        echo "  KAFKA_NAMESPACE         Target namespace (default: kafka)"
        echo "  KAFKA_CLUSTER_NAME      Kafka cluster name (default: ros-ocp-kafka)"
        echo "  KAFKA_VERSION           Kafka version (default: 3.8.0)"
        echo "  STRIMZI_VERSION         Strimzi operator version (default: 0.45.1)"
        echo "  KAFKA_ENVIRONMENT       Environment type: dev or ocp (default: dev)"
        echo "  STORAGE_CLASS           Storage class name (auto-detected if empty)"
        echo "  STRIMZI_NAMESPACE       Use existing Strimzi operator in this namespace"
        echo ""
        echo "Examples:"
        echo "  # Deploy with default settings"
        echo "  $0"
        echo ""
        echo "  # Deploy for OpenShift with custom storage"
        echo "  KAFKA_ENVIRONMENT=ocp STORAGE_CLASS=gp2 $0"
        echo ""
        echo "  # Use existing Strimzi operator"
        echo "  STRIMZI_NAMESPACE=existing-strimzi $0"
        echo ""
        echo "  # Use existing Kafka on cluster (no deployment)"
        echo "  KAFKA_BOOTSTRAP_SERVERS=my-kafka-bootstrap.my-namespace:9092 $0"
        echo ""
        echo "  # Validate existing deployment"
        echo "  $0 validate"
        echo ""
        echo "  # Clean up deployment"
        echo "  $0 cleanup"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo_error "Unknown command: $1"
        echo_info "Use '$0 help' for usage information"
        exit 1
        ;;
esac

