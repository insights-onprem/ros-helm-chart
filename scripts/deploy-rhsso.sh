#!/bin/bash

# RHSSO/Keycloak Deployment Script for OpenShift
# This script automates the deployment of RHSSO with all necessary configurations
# for JWT authentication with the Cost Management Metrics Operator

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${RHSSO_NAMESPACE:-rhsso}
STORAGE_CLASS=${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}
ADMIN_USER=${KEYCLOAK_ADMIN_USER:-admin}
ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:-admin}
REALM_NAME=${REALM_NAME:-kubernetes}
COST_MGMT_CLIENT_ID=${COST_MGMT_CLIENT_ID:-cost-management-operator}

# OpenShift cluster-specific configuration (auto-detected)
CLUSTER_DOMAIN=""
OAUTH_CALLBACK=""
CONSOLE_URL=""

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

# Function to check prerequisites
check_prerequisites() {
    echo_header "CHECKING PREREQUISITES"

    # Check if oc command is available
    if ! command -v oc >/dev/null 2>&1; then
        echo_error "oc command not found. Please install OpenShift CLI."
        exit 1
    fi
    echo_success "✓ OpenShift CLI (oc) is available"

    # Check if logged into OpenShift
    if ! oc whoami >/dev/null 2>&1; then
        echo_error "Not logged into OpenShift cluster. Please run 'oc login' first."
        exit 1
    fi
    echo_success "✓ Logged into OpenShift cluster as: $(oc whoami)"

    # Check if cluster has admin permissions
    if ! oc auth can-i create subscriptions.operators.coreos.com -A >/dev/null 2>&1; then
        echo_error "Insufficient permissions to install operators. Cluster admin access required."
        exit 1
    fi
    echo_success "✓ Cluster admin permissions verified"

    # Auto-detect cluster domain
    CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
    if [ -n "$CLUSTER_DOMAIN" ]; then
        OAUTH_CALLBACK="https://oauth-openshift.apps.$CLUSTER_DOMAIN"
        CONSOLE_URL="https://console-openshift-console.apps.$CLUSTER_DOMAIN"
        echo_success "✓ Cluster domain detected: $CLUSTER_DOMAIN"
    else
        echo_warning "Could not auto-detect cluster domain. OpenShift integration may need manual configuration."
    fi

    # Check available storage classes
    if oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
        echo_success "✓ Storage class '$STORAGE_CLASS' is available"
    else
        echo_warning "Storage class '$STORAGE_CLASS' not found. Available storage classes:"
        oc get storageclass --no-headers -o custom-columns=NAME:.metadata.name | sed 's/^/  - /' || true
        echo_info "You may need to adjust STORAGE_CLASS environment variable"
    fi

    echo_success "Prerequisites check completed successfully"
}

# Function to create namespace
create_namespace() {
    echo_header "CREATING NAMESPACE"

    if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Namespace '$NAMESPACE' already exists"
    else
        echo_info "Creating namespace: $NAMESPACE"
        oc create namespace "$NAMESPACE"
        echo_success "✓ Namespace '$NAMESPACE' created"
    fi

    # Label namespace for monitoring and management
    oc label namespace "$NAMESPACE" app=sso --overwrite=true
    echo_success "✓ Namespace labeled with app=sso"
}

# Function to install RHSSO operator
install_rhsso_operator() {
    echo_header "INSTALLING RHSSO OPERATOR"

    # Create OperatorGroup if it doesn't exist
    if ! oc get operatorgroup rhsso-operator-group -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_info "Creating OperatorGroup..."
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhsso-operator-group
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
EOF
        echo_success "✓ OperatorGroup created"
    else
        echo_success "✓ OperatorGroup already exists"
    fi

    # Check if operator is already installed
    if oc get subscription rhsso-operator -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "RHSSO Operator subscription already exists"
    else
        echo_info "Creating RHSSO Operator subscription..."

        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhsso-operator
  namespace: $NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhsso-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
        echo_success "✓ RHSSO Operator subscription created"
    fi

    # Wait for operator to be ready
    echo_info "Waiting for RHSSO operator to be ready..."
    local timeout=300
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if oc get deployment rhsso-operator -n "$NAMESPACE" >/dev/null 2>&1; then
            if oc get deployment rhsso-operator -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' | grep -q "1"; then
                echo_success "✓ RHSSO Operator is ready"
                return 0
            fi
        fi

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo_info "Still waiting for RHSSO operator... (${elapsed}s elapsed)"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo_error "Timeout waiting for RHSSO operator to be ready"
    exit 1
}

# Function to deploy Keycloak instance
deploy_keycloak() {
    echo_header "DEPLOYING KEYCLOAK INSTANCE"

    # Check if Keycloak instance already exists
    if oc get keycloak rhsso-keycloak -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Keycloak instance 'rhsso-keycloak' already exists"
    else
        echo_info "Creating Keycloak instance..."

        cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  labels:
    app: sso
  name: rhsso-keycloak
  namespace: $NAMESPACE
spec:
  externalAccess:
    enabled: true
  instances: 1
  keycloakDeploymentSpec:
    imagePullPolicy: Always
    resources:
      limits:
        cpu: 1000m
        memory: 2Gi
      requests:
        cpu: 500m
        memory: 1Gi
  podDisruptionBudget:
    enabled: true
  storageClassName: $STORAGE_CLASS
EOF
        echo_success "✓ Keycloak instance created"
    fi

    # Wait for Keycloak to be ready
    echo_info "Waiting for Keycloak to be ready (this may take several minutes)..."
    local timeout=600
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local status=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo_success "✓ Keycloak instance is ready"

            # Display connection information
            local external_url=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
            local internal_url=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.internalURL}' 2>/dev/null || echo "")

            if [ -n "$external_url" ]; then
                echo_info "External URL: $external_url"
            fi
            if [ -n "$internal_url" ]; then
                echo_info "Internal URL: $internal_url"
            fi

            return 0
        fi

        if [ $((elapsed % 60)) -eq 0 ]; then
            echo_info "Still waiting for Keycloak... (${elapsed}s elapsed)"
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    echo_error "Timeout waiting for Keycloak to be ready"
    exit 1
}

# Function to create Kubernetes realm
create_kubernetes_realm() {
    echo_header "CREATING KUBERNETES REALM"

    # Check if realm already exists
    if oc get keycloakrealm kubernetes-realm -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "KeycloakRealm 'kubernetes-realm' already exists"
    else
        echo_info "Creating Kubernetes realm..."

        cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  labels:
    app: sso
  name: kubernetes-realm
  namespace: $NAMESPACE
spec:
  instanceSelector:
    matchLabels:
      app: sso
  realm:
    accessTokenLifespan: 300
    bruteForceProtected: true
    displayName: Kubernetes Realm
    enabled: true
    failureFactor: 30
    id: $REALM_NAME
    maxDeltaTimeSeconds: 43200
    maxFailureWaitSeconds: 900
    realm: $REALM_NAME
    registrationAllowed: false
    rememberMe: true
    resetPasswordAllowed: true
    verifyEmail: false
    clientScopes:
    - name: api.console
      description: API Console access scope for cost management
      protocol: openid-connect
      attributes:
        include.in.token.scope: "true"
        display.on.consent.screen: "false"
    defaultDefaultClientScopes:
    - api.console
EOF
        echo_success "✓ Kubernetes realm created"
    fi

    # Wait for realm to be ready
    echo_info "Waiting for realm to be ready..."
    local timeout=120
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local status=$(oc get keycloakrealm kubernetes-realm -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo_success "✓ Kubernetes realm is ready"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo_error "Timeout waiting for Kubernetes realm to be ready"
    exit 1
}

# Function to create Cost Management client
create_cost_management_client() {
    echo_header "CREATING COST MANAGEMENT CLIENT"

    # Check if client already exists
    if oc get keycloakclient cost-management-service-account -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "KeycloakClient 'cost-management-service-account' already exists"
    else
        echo_info "Creating Cost Management service account client..."

        cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  labels:
    app: sso
  name: cost-management-service-account
  namespace: $NAMESPACE
spec:
  client:
    clientAuthenticatorType: client-secret
    clientId: $COST_MGMT_CLIENT_ID
    defaultClientScopes:
    - openid
    - profile
    - email
    - api.console
    description: Service account client for Cost Management Metrics Operator
    directAccessGrantsEnabled: false
    enabled: true
    implicitFlowEnabled: false
    name: Cost Management Operator Service Account
    protocol: openid-connect
    protocolMappers:
    - config:
        access.token.claim: "true"
        id.token.claim: "false"
        included.client.audience: $COST_MGMT_CLIENT_ID
      name: audience-mapper
      protocol: openid-connect
      protocolMapper: oidc-audience-mapper
    - config:
        access.token.claim: "true"
        claim.name: clientId
        id.token.claim: "true"
        user.session.note: clientId
      name: client-id-mapper
      protocol: openid-connect
      protocolMapper: oidc-usersessionmodel-note-mapper
    - config:
        access.token.claim: "true"
        claim.name: scope
        claim.value: api.console
        id.token.claim: "false"
      name: api-console-mock
      protocol: openid-connect
      protocolMapper: oidc-hardcoded-claim-mapper
    publicClient: false
    serviceAccountsEnabled: true
    standardFlowEnabled: false
  realmSelector:
    matchLabels:
      app: sso
EOF
        echo_success "✓ Cost Management client created"
    fi

    # Wait for client to be ready
    echo_info "Waiting for Cost Management client to be ready..."
    local timeout=120
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local status=$(oc get keycloakclient cost-management-service-account -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo_success "✓ Cost Management client is ready"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo_error "Timeout waiting for Cost Management client to be ready"
    exit 1
}

# Function to create OpenShift OIDC clients (optional)
create_openshift_clients() {
    echo_header "CREATING OPENSHIFT OIDC CLIENTS (OPTIONAL)"

    if [ -z "$CLUSTER_DOMAIN" ]; then
        echo_warning "Cluster domain not detected. Skipping OpenShift OIDC client creation."
        echo_info "You can create these manually later if needed for OpenShift integration."
        return 0
    fi

    echo_info "Creating OpenShift OIDC clients for cluster domain: $CLUSTER_DOMAIN"

    # Create basic OpenShift client
    if oc get keycloakclient openshift-client -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "KeycloakClient 'openshift-client' already exists"
    else
        echo_info "Creating OpenShift client..."

        cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  labels:
    app: sso
  name: openshift-client
  namespace: $NAMESPACE
spec:
  client:
    clientAuthenticatorType: client-secret
    clientId: openshift
    description: OIDC client for OpenShift authentication
    directAccessGrantsEnabled: true
    enabled: true
    implicitFlowEnabled: false
    name: OpenShift OIDC Client
    protocol: openid-connect
    protocolMappers:
    - config:
        access.token.claim: "true"
        claim.name: preferred_username
        id.token.claim: "true"
        user.attribute: username
        userinfo.token.claim: "true"
      name: username
      protocol: openid-connect
      protocolMapper: oidc-usermodel-property-mapper
    - config:
        access.token.claim: "true"
        claim.name: email
        id.token.claim: "true"
        user.attribute: email
        userinfo.token.claim: "true"
      name: email
      protocol: openid-connect
      protocolMapper: oidc-usermodel-property-mapper
    - config:
        access.token.claim: "true"
        claim.name: groups
        full.path: "false"
        id.token.claim: "true"
        userinfo.token.claim: "true"
      name: groups
      protocol: openid-connect
      protocolMapper: oidc-group-membership-mapper
    publicClient: false
    redirectUris:
    - ${OAUTH_CALLBACK}/oauth/callback/keycloak
    - ${CONSOLE_URL}/*
    serviceAccountsEnabled: true
    standardFlowEnabled: true
    webOrigins:
    - $OAUTH_CALLBACK
    - $CONSOLE_URL
  realmSelector:
    matchLabels:
      app: sso
EOF
        echo_success "✓ OpenShift client created"
    fi

    # Create dedicated OIDC client for API server
    if oc get keycloakclient openshift-oidc-client -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "KeycloakClient 'openshift-oidc-client' already exists"
    else
        echo_info "Creating OpenShift OIDC integration client..."

        cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  labels:
    app: sso
  name: openshift-oidc-client
  namespace: $NAMESPACE
spec:
  client:
    attributes:
      access.token.lifespan: "3600"
      acr.loa.map: '{}'
      backchannel.logout.revoke.offline.tokens: "false"
      backchannel.logout.session.required: "true"
      client.secret.creation.time: "1696694400"
      exclude.session.state.from.auth.response: "false"
      id.token.as.detached.signature: "false"
      oauth2.device.authorization.grant.enabled: "false"
      oidc.ciba.grant.enabled: "false"
      require.pushed.authorization.requests: "false"
      use.refresh.tokens: "true"
    clientAuthenticatorType: client-secret
    clientId: openshift-oidc
    defaultClientScopes:
    - web-origins
    - role_list
    - roles
    - profile
    - email
    - openid
    description: Dedicated client for OpenShift API Server OIDC authentication
    directAccessGrantsEnabled: true
    enabled: true
    implicitFlowEnabled: false
    name: OpenShift OIDC Integration Client
    optionalClientScopes:
    - address
    - phone
    - offline_access
    - microprofile-jwt
    protocol: openid-connect
    protocolMappers:
    - config:
        access.token.claim: "true"
        claim.name: preferred_username
        id.token.claim: "true"
        jsonType.label: String
        user.attribute: username
        userinfo.token.claim: "true"
      name: username
      protocol: openid-connect
      protocolMapper: oidc-usermodel-property-mapper
    - config:
        access.token.claim: "true"
        claim.name: email
        id.token.claim: "true"
        jsonType.label: String
        user.attribute: email
        userinfo.token.claim: "true"
      name: email
      protocol: openid-connect
      protocolMapper: oidc-usermodel-property-mapper
    - config:
        access.token.claim: "true"
        claim.name: groups
        full.path: "false"
        id.token.claim: "true"
        userinfo.token.claim: "true"
      name: groups
      protocol: openid-connect
      protocolMapper: oidc-group-membership-mapper
    - config:
        access.token.claim: "true"
        id.token.claim: "true"
        included.client.audience: openshift-oidc
      name: audience-mapper-oidc
      protocol: openid-connect
      protocolMapper: oidc-audience-mapper
    publicClient: false
    redirectUris:
    - ${OAUTH_CALLBACK}/*
    - ${CONSOLE_URL}/*
    serviceAccountsEnabled: true
    standardFlowEnabled: true
    webOrigins:
    - $OAUTH_CALLBACK
    - $CONSOLE_URL
  realmSelector:
    matchLabels:
      app: sso
EOF
        echo_success "✓ OpenShift OIDC client created"
    fi

    echo_success "OpenShift OIDC clients created successfully"
}

# Function to validate deployment
validate_deployment() {
    echo_header "VALIDATING DEPLOYMENT"

    local validation_errors=0

    # Check namespace
    if oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo_success "✓ Namespace '$NAMESPACE' exists"
    else
        echo_error "✗ Namespace '$NAMESPACE' not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check operator
    if oc get deployment rhsso-operator -n "$NAMESPACE" >/dev/null 2>&1; then
        local ready_replicas=$(oc get deployment rhsso-operator -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready_replicas" = "1" ]; then
            echo_success "✓ RHSSO Operator is running"
        else
            echo_error "✗ RHSSO Operator is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ RHSSO Operator not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check Keycloak instance
    if oc get keycloak rhsso-keycloak -n "$NAMESPACE" >/dev/null 2>&1; then
        local status=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo_success "✓ Keycloak instance is ready"
        else
            echo_error "✗ Keycloak instance is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Keycloak instance not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check realm
    if oc get keycloakrealm kubernetes-realm -n "$NAMESPACE" >/dev/null 2>&1; then
        local status=$(oc get keycloakrealm kubernetes-realm -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo_success "✓ Kubernetes realm is ready"
        else
            echo_error "✗ Kubernetes realm is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Kubernetes realm not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check Cost Management client
    if oc get keycloakclient cost-management-service-account -n "$NAMESPACE" >/dev/null 2>&1; then
        local status=$(oc get keycloakclient cost-management-service-account -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        if [ "$status" = "true" ]; then
            echo_success "✓ Cost Management client is ready"
        else
            echo_error "✗ Cost Management client is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Cost Management client not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check client secret
    if oc get secret keycloak-client-secret-cost-management-service-account -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_success "✓ Cost Management client secret exists"
    else
        echo_error "✗ Cost Management client secret not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check routes
    if oc get route keycloak -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_success "✓ Keycloak route exists"
    else
        echo_warning "⚠ Keycloak route not found (may be normal for some deployments)"
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

    # Get connection information
    local external_url=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "Not available")
    local internal_url=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.internalURL}' 2>/dev/null || echo "Not available")

    echo_info "Keycloak Deployment Information:"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  External URL: $external_url"
    echo_info "  Internal URL: $internal_url"
    echo_info "  Realm: $REALM_NAME"
    echo_info "  Admin User: $ADMIN_USER"
    echo ""

    echo_info "Cost Management Client Information:"
    echo_info "  Client ID: $COST_MGMT_CLIENT_ID"
    echo_info "  Client Type: Service Account (client_credentials flow)"
    echo_info "  Default Scopes: openid, profile, email, api.console"
    echo_info "  Note: api.console scope is defined at realm level in clientScopes"
    echo ""

    # Display client secret retrieval command
    echo_info "To retrieve the Cost Management client secret:"
    echo_info "  oc get secret keycloak-client-secret-cost-management-service-account -n $NAMESPACE -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d"
    echo ""

    # Display admin credential retrieval
    echo_info "To retrieve Keycloak admin credentials:"
    echo_info "  oc get secret credential-rhsso-keycloak -n $NAMESPACE -o jsonpath='{.data.ADMIN_USERNAME}' | base64 -d"
    echo_info "  oc get secret credential-rhsso-keycloak -n $NAMESPACE -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d"
    echo ""

    echo_info "Next Steps:"
    echo_info "  1. Access Keycloak admin console at: $external_url"
    echo_info "  2. Test JWT token generation with: ./test-ocp-dataflow-jwt.sh"
    echo_info "  3. Configure your applications to use the JWT authentication"
    echo ""

    echo_success "RHSSO/Keycloak deployment completed successfully!"
}

# Function to clean up (for troubleshooting)
cleanup_deployment() {
    echo_header "CLEANING UP DEPLOYMENT"
    echo_warning "This will remove all RHSSO resources. Are you sure? (y/N)"
    read -r confirmation

    if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
        echo_info "Cleanup cancelled"
        return 0
    fi

    echo_info "Removing RHSSO resources..."

    # Remove clients
    oc delete keycloakclient --all -n "$NAMESPACE" 2>/dev/null || true

    # Remove realm
    oc delete keycloakrealm --all -n "$NAMESPACE" 2>/dev/null || true

    # Remove Keycloak instance
    oc delete keycloak --all -n "$NAMESPACE" 2>/dev/null || true

    # Remove subscription
    oc delete subscription rhsso-operator -n "$NAMESPACE" 2>/dev/null || true

    # Remove namespace
    oc delete namespace "$NAMESPACE" 2>/dev/null || true

    echo_success "Cleanup completed"
}

# Main execution function
main() {
    echo_header "RHSSO/KEYCLOAK DEPLOYMENT SCRIPT"
    echo_info "This script will deploy RHSSO with Cost Management integration"
    echo_info "Configuration:"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  Storage Class: $STORAGE_CLASS"
    echo_info "  Realm: $REALM_NAME"
    echo_info "  Cost Management Client ID: $COST_MGMT_CLIENT_ID"
    echo ""

    # Execute deployment steps
    check_prerequisites
    create_namespace
    install_rhsso_operator
    deploy_keycloak
    create_kubernetes_realm
    create_cost_management_client
    create_openshift_clients

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
        cleanup_deployment
        exit 0
        ;;
    "validate"|"check")
        validate_deployment
        exit $?
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (no command)    Deploy RHSSO with all components"
        echo "  validate        Validate existing deployment"
        echo "  cleanup         Remove all RHSSO resources"
        echo "  help            Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  RHSSO_NAMESPACE           Target namespace (default: rhsso)"
        echo "  STORAGE_CLASS             Storage class name (default: ocs-storagecluster-ceph-rbd)"
        echo "  KEYCLOAK_ADMIN_USER       Admin username (default: admin)"
        echo "  KEYCLOAK_ADMIN_PASSWORD   Admin password (default: admin)"
        echo "  REALM_NAME                Realm name (default: kubernetes)"
        echo "  COST_MGMT_CLIENT_ID       Client ID (default: cost-management-operator)"
        echo ""
        echo "Examples:"
        echo "  # Deploy with default settings"
        echo "  $0"
        echo ""
        echo "  # Deploy with custom storage class"
        echo "  STORAGE_CLASS=gp2 $0"
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
