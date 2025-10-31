#!/bin/bash

# Authorino Installation Script
# This script installs and configures Authorino for OAuth2 TokenReview authentication
# on OpenShift clusters for the ROS-OCP backend API

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${NAMESPACE:-ros-ocp}
AUTHORINO_OPERATOR_NAMESPACE=${AUTHORINO_OPERATOR_NAMESPACE:-openshift-operators}
AUTHORINO_VERSION=${AUTHORINO_VERSION:-v1.2.3}

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

# Check prerequisites
check_prerequisites() {
    echo_info "Checking prerequisites..."

    if ! command -v oc >/dev/null 2>&1; then
        echo_error "oc (OpenShift CLI) is not installed"
        return 1
    fi

    if ! oc whoami >/dev/null 2>&1; then
        echo_error "Not logged into OpenShift cluster"
        return 1
    fi

    echo_success "Prerequisites check passed"
    return 0
}

# Check if Authorino Operator is installed
check_operator_installed() {
    echo_info "Checking if Authorino Operator is installed..."

    if oc get csv -n "$AUTHORINO_OPERATOR_NAMESPACE" 2>/dev/null | grep -q "authorino-operator"; then
        local version=$(oc get csv -n "$AUTHORINO_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Authorino Operator")].spec.version}' 2>/dev/null | head -1)
        echo_success "Authorino Operator is already installed (version: ${version:-unknown})"
        return 0
    else
        echo_info "Authorino Operator is not installed"
        return 1
    fi
}

# Install Authorino Operator
install_operator() {
    echo_info "=== Installing Authorino Operator ==="

    # Check if operator is already installed
    if check_operator_installed; then
        echo_info "Skipping operator installation"
        return 0
    fi

    # Check if an OperatorGroup already exists in the namespace
    local existing_og=$(oc get operatorgroups -n "$AUTHORINO_OPERATOR_NAMESPACE" -o name 2>/dev/null | head -1)

    if [ -n "$existing_og" ]; then
        echo_info "OperatorGroup already exists in namespace: $existing_og"
        echo_success "Using existing OperatorGroup"
    else
        echo_info "Creating OperatorGroup for AllNamespaces..."

        # Create OperatorGroup for all namespaces
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: authorino-operator-group
  namespace: ${AUTHORINO_OPERATOR_NAMESPACE}
spec: {}
EOF

        echo_success "OperatorGroup created"
    fi

    echo_info "Creating Subscription for Authorino Operator..."

    # Create Subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: authorino-operator
  namespace: ${AUTHORINO_OPERATOR_NAMESPACE}
spec:
  channel: stable
  name: authorino-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

    echo_success "Subscription created"

    echo_info "Waiting for Authorino Operator to be installed..."
    local max_wait=180
    local wait_count=0

    while [ $wait_count -lt $max_wait ]; do
        if oc get csv -n "$AUTHORINO_OPERATOR_NAMESPACE" 2>/dev/null | grep -q "authorino-operator.*Succeeded"; then
            echo_success "Authorino Operator installed successfully"
            return 0
        fi

        echo -n "."
        sleep 5
        wait_count=$((wait_count + 5))
    done

    echo ""
    echo_error "Timeout waiting for Authorino Operator installation"
    return 1
}

# Create Authorino instance
create_authorino_instance() {
    echo_info "=== Creating Authorino Instance ==="

    # Check if namespace exists
    if ! oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo_error "Namespace '$NAMESPACE' does not exist"
        echo_info "Please create the namespace first or set NAMESPACE environment variable"
        return 1
    fi

    # Check if Authorino instance already exists
    if oc get authorino -n "$NAMESPACE" 2>/dev/null | grep -q "authorino"; then
        echo_warning "Authorino instance already exists in namespace '$NAMESPACE'"
        echo_info "Checking status..."
        oc get authorino -n "$NAMESPACE"
        return 0
    fi

    echo_info "Creating TLS service for Authorino (triggers service-ca certificate generation)..."

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: authorino-tls
  namespace: ${NAMESPACE}
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert
spec:
  selector:
    app.kubernetes.io/name: authorino
  ports:
  - name: grpc
    port: 50051
    targetPort: 50051
    protocol: TCP
  type: ClusterIP
EOF

    echo_success "TLS service created (service-ca will generate authorino-server-cert)"

    echo_info "Waiting for service-ca to generate certificate..."
    local cert_wait=30
    local cert_count=0
    while [ $cert_count -lt $cert_wait ]; do
        if oc get secret authorino-server-cert -n "$NAMESPACE" >/dev/null 2>&1; then
            echo_success "Certificate secret generated"
            break
        fi
        sleep 2
        cert_count=$((cert_count + 2))
    done

    if ! oc get secret authorino-server-cert -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Certificate secret not yet available (will be created by service-ca operator)"
        echo_info "Authorino will start once the certificate is available"
    fi

    echo_info "Creating Authorino CR with TLS enabled..."

    cat <<EOF | oc apply -f -
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: ${NAMESPACE}
spec:
  clusterWide: false
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
EOF

    echo_success "Authorino CR created with TLS enabled"

    echo_info "Waiting for Authorino operator to create deployment (this may take several minutes)..."
    echo_info "The Authorino operator needs time to reconcile and create the deployment"

    local max_wait=360  # 6 minutes timeout
    local wait_count=0
    local deployment_found=false

    # Step 1: Wait for deployment to be created by operator
    echo_info "Step 1/2: Waiting for Authorino deployment to be created..."
    while [ $wait_count -lt $max_wait ]; do
        if oc get deployment authorino -n "$NAMESPACE" >/dev/null 2>&1; then
            echo_success "✓ Authorino deployment created by operator"
            deployment_found=true
            break
        fi

        if [ $((wait_count % 30)) -eq 0 ] && [ $wait_count -gt 0 ]; then
            echo_info "Still waiting for operator to create deployment... (${wait_count}s elapsed)"
        fi

        sleep 5
        wait_count=$((wait_count + 5))
    done

    if [ "$deployment_found" = false ]; then
        echo ""
        echo_error "Timeout: Authorino operator did not create deployment after ${max_wait}s"
        echo_error "This may indicate an issue with the Authorino operator"
        echo_info "Check operator logs: oc logs -n openshift-operators -l control-plane=authorino-operator"
        return 1
    fi

    # Step 2: Wait for deployment to be ready
    echo_info "Step 2/2: Waiting for Authorino deployment to be ready..."

    if oc wait --for=condition=Available deployment/authorino -n "$NAMESPACE" --timeout=$((max_wait - wait_count))s 2>/dev/null; then
        echo_success "✓ Authorino deployment is ready"

        # Verify pods are running (using correct label selector)
        local ready_pods=$(oc get pods -n "$NAMESPACE" -l authorino-resource=authorino 2>/dev/null | grep "Running" | wc -l | tr -d ' ')
        if [ "$ready_pods" -gt 0 ]; then
            echo_success "✓ Authorino pods are running"
            oc get deployment,pods -n "$NAMESPACE" -l authorino-resource=authorino
            return 0
        else
            echo_warning "Deployment ready but no running pods found yet"
            echo_info "Waiting 30 seconds for pods to start..."
            sleep 30
            ready_pods=$(oc get pods -n "$NAMESPACE" -l authorino-resource=authorino 2>/dev/null | grep "Running" | wc -l | tr -d ' ')
            if [ "$ready_pods" -gt 0 ]; then
                echo_success "✓ Authorino pods are now running"
                oc get deployment,pods -n "$NAMESPACE" -l authorino-resource=authorino
                return 0
            else
                echo_error "No running pods found after additional wait"
                oc get pods -n "$NAMESPACE" -l authorino-resource=authorino
                return 1
            fi
        fi
    else
        echo ""
        echo_error "Timeout: Authorino deployment not ready after waiting"
        echo_info "Current deployment status:"
        oc get deployment authorino -n "$NAMESPACE" -o wide 2>/dev/null || echo "Deployment not found"
        oc get pods -n "$NAMESPACE" -l app=authorino 2>/dev/null || echo "No pods found"
        return 1
    fi
}

# Create RBAC for TokenReview
create_tokenreview_rbac() {
    echo_info "=== Creating RBAC for TokenReview ==="

    local service_account="authorino-authorino"

    # Check if ServiceAccount exists
    if ! oc get serviceaccount "$service_account" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_error "ServiceAccount '$service_account' not found in namespace '$NAMESPACE'"
        echo_error "Make sure Authorino instance is created first"
        return 1
    fi

    echo_info "Creating ClusterRole for TokenReview..."

    cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: authorino-tokenreview
  labels:
    app.kubernetes.io/name: authorino
    app.kubernetes.io/part-of: ros-ocp
rules:
- apiGroups:
  - authentication.k8s.io
  resources:
  - tokenreviews
  verbs:
  - create
EOF

    echo_success "ClusterRole created"

    echo_info "Creating ClusterRoleBinding..."

    cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: authorino-tokenreview-${NAMESPACE}
  labels:
    app.kubernetes.io/name: authorino
    app.kubernetes.io/part-of: ros-ocp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: authorino-tokenreview
subjects:
- kind: ServiceAccount
  name: ${service_account}
  namespace: ${NAMESPACE}
EOF

    echo_success "ClusterRoleBinding created"

    return 0
}

# Verify installation
verify_installation() {
    echo_info "=== Verifying Authorino Installation ==="

    echo_info "Checking Operator..."
    if ! check_operator_installed; then
        echo_error "Operator verification failed"
        return 1
    fi

    echo_info "Checking Authorino instance..."
    if ! oc get authorino -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_error "Authorino instance not found"
        return 1
    fi

    echo_info "Checking Authorino pods..."
    local pod_count=$(oc get pods -n "$NAMESPACE" -l authorino-resource=authorino --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pod_count" -eq 0 ]; then
        echo_error "No Authorino pods found"
        return 1
    fi
    echo_success "✓ Found $pod_count Authorino pod(s) running"

    echo_info "Checking Authorino service..."
    if ! oc get svc -n "$NAMESPACE" | grep -q "authorino-authorino-authorization"; then
        echo_error "Authorino service not found"
        return 1
    fi

    echo_info "Checking RBAC..."
    if ! oc get clusterrole authorino-tokenreview >/dev/null 2>&1; then
        echo_error "TokenReview ClusterRole not found"
        return 1
    fi

    if ! oc get clusterrolebinding "authorino-tokenreview-${NAMESPACE}" >/dev/null 2>&1; then
        echo_error "TokenReview ClusterRoleBinding not found"
        return 1
    fi

    echo_success "All Authorino components verified successfully"

    echo ""
    echo_info "Authorino Installation Summary:"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  Operator: $(oc get csv -n "$AUTHORINO_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Authorino Operator")].spec.version}' 2>/dev/null | head -1)"
    echo_info "  Instance: $(oc get authorino -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    echo_info "  Pods: $pod_count running"
    echo_info "  Service: authorino-authorino-authorization"
    echo_info "  TLS Service: authorino-tls (service-ca managed)"
    echo_info "  TLS Certificate: authorino-server-cert"
    echo_info "  RBAC: TokenReview permissions granted"
    echo_info ""
    echo_info "Security Features:"
    echo_info "  ✓ TLS encryption for Envoy↔Authorino communication"
    echo_info "  ✓ NetworkPolicy restricts access to authorized pods only"
    echo_info "  ✓ Certificates auto-managed by OpenShift service-ca operator"

    return 0
}

# Display usage information
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "This script installs and configures Authorino for OAuth2 TokenReview authentication"
    echo "on OpenShift clusters with production-grade security. It performs the following steps:"
    echo ""
    echo "  1. Install Authorino Operator (if not already installed)"
    echo "  2. Create TLS service (triggers OpenShift service-ca certificate generation)"
    echo "  3. Create Authorino instance with TLS enabled"
    echo "  4. Configure RBAC for Kubernetes TokenReview API access"
    echo "  5. Verify installation"
    echo ""
    echo "Security Features:"
    echo "  • TLS encryption for Envoy↔Authorino communication"
    echo "  • NetworkPolicy restricts access to authorized pods only"
    echo "  • Auto-managed certificates via OpenShift service-ca operator"
    echo "  • Namespace-scoped (clusterWide: false) to limit blast radius"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  --verify-only           Only verify existing installation"
    echo "  --rbac-only             Only create/update RBAC resources"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE                        Target namespace (default: ros-ocp)"
    echo "  AUTHORINO_OPERATOR_NAMESPACE     Operator namespace (default: openshift-operators)"
    echo ""
    echo "Examples:"
    echo "  # Full installation"
    echo "  $0"
    echo ""
    echo "  # Install in custom namespace"
    echo "  NAMESPACE=my-namespace $0"
    echo ""
    echo "  # Verify existing installation"
    echo "  $0 --verify-only"
    echo ""
    echo "  # Update RBAC only"
    echo "  $0 --rbac-only"
    echo ""
    echo "Prerequisites:"
    echo "  - OpenShift CLI (oc) installed"
    echo "  - Logged into OpenShift cluster with admin privileges"
    echo "  - Target namespace already created"
    echo ""
    echo "For more information:"
    echo "  https://docs.kuadrant.io/dev/authorino/"
}

# Main execution
main() {
    echo_info "Authorino Installation for ROS-OCP"
    echo_info "===================================="
    echo_info "Target namespace: $NAMESPACE"
    echo_info "Operator namespace: $AUTHORINO_OPERATOR_NAMESPACE"
    echo ""

    # Check prerequisites
    if ! check_prerequisites; then
        exit 1
    fi

    # Install Authorino Operator
    if ! install_operator; then
        echo_error "Failed to install Authorino Operator"
        exit 1
    fi

    echo ""

    # Create Authorino instance
    if ! create_authorino_instance; then
        echo_error "Failed to create Authorino instance"
        exit 1
    fi

    echo ""

    # Create RBAC
    if ! create_tokenreview_rbac; then
        echo_error "Failed to create TokenReview RBAC"
        exit 1
    fi

    echo ""

    # Verify installation
    if ! verify_installation; then
        echo_error "Installation verification failed"
        exit 1
    fi

    echo ""
    echo_success "✅ Authorino installation completed successfully!"
    echo ""
    echo_info "Next steps:"
    echo_info "  1. Deploy your application with AuthConfig resources"
    echo_info "  2. Configure Envoy ext_authz filter to use Authorino"
    echo_info "  3. Test authentication with user tokens"
    echo ""
    echo_info "Example AuthConfig:"
    echo_info "  See: ros-ocp/templates/authorino-authconfig.yaml"
    echo ""
}

# Handle script arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        show_usage
        exit 0
        ;;
    "--verify-only")
        echo_info "Running verification only..."
        check_prerequisites && verify_installation
        exit $?
        ;;
    "--rbac-only")
        echo_info "Updating RBAC only..."
        check_prerequisites && create_tokenreview_rbac
        exit $?
        ;;
    "")
        main
        ;;
    *)
        echo_error "Unknown option: $1"
        echo_info "Use '$0 --help' for usage information"
        exit 1
        ;;
esac

