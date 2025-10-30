#!/bin/bash

# Red Hat Build of Keycloak (RHBK) Deployment Script for OpenShift
# This script automates the deployment of RHBK with all necessary configurations
# for JWT authentication with the Cost Management Metrics Operator
#
# RHBK uses the new Keycloak Operator API: k8s.keycloak.org/v2alpha1
# Replaces the legacy RHSSO operator (keycloak.org/v1alpha1)

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${RHBK_NAMESPACE:-keycloak}
STORAGE_CLASS=${STORAGE_CLASS:-}  # Auto-detect if empty
ADMIN_USER=${KEYCLOAK_ADMIN_USER:-admin}
ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:-admin}
REALM_NAME=${REALM_NAME:-kubernetes}
COST_MGMT_CLIENT_ID=${COST_MGMT_CLIENT_ID:-cost-management-operator}
KEYCLOAK_INSTANCES=${KEYCLOAK_INSTANCES:-1}

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

    # Auto-detect default storage class if not provided
    if [ -z "$STORAGE_CLASS" ]; then
        STORAGE_CLASS=$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
        if [ -n "$STORAGE_CLASS" ]; then
            echo_success "✓ Auto-detected default storage class: $STORAGE_CLASS"
        else
            echo_error "No default storage class found. Available storage classes:"
            oc get storageclass --no-headers -o custom-columns=NAME:.metadata.name | sed 's/^/  - /' || true
            echo_error "Please set STORAGE_CLASS environment variable to specify a storage class."
            exit 1
        fi
    else
        # Check if user-provided storage class exists
        if oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1; then
            echo_success "✓ Storage class '$STORAGE_CLASS' is available"
        else
            echo_error "Storage class '$STORAGE_CLASS' not found. Available storage classes:"
            oc get storageclass --no-headers -o custom-columns=NAME:.metadata.name | sed 's/^/  - /' || true
            echo_error "Please specify a valid storage class with STORAGE_CLASS environment variable."
            exit 1
        fi
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

# Function to install RHBK operator
install_rhbk_operator() {
    echo_header "INSTALLING RED HAT BUILD OF KEYCLOAK OPERATOR"

    # Create OperatorGroup if it doesn't exist
    if ! oc get operatorgroup rhbk-operator-group -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_info "Creating OperatorGroup..."
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhbk-operator-group
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
    if oc get subscription rhbk-operator -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "RHBK Operator subscription already exists"
    else
        echo_info "Creating RHBK Operator subscription..."

        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: $NAMESPACE
spec:
  channel: stable-v22
  installPlanApproval: Automatic
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
        echo_success "✓ RHBK Operator subscription created"
    fi

    # Wait for operator to be ready
    echo_info "Waiting for RHBK operator to be ready..."
    local timeout=300
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        # RHBK operator deployment name is different
        if oc get deployment rhbk-operator -n "$NAMESPACE" >/dev/null 2>&1; then
            if oc get deployment rhbk-operator -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' | grep -q "1"; then
                echo_success "✓ RHBK Operator is ready"
                return 0
            fi
        fi

        if [ $((elapsed % 30)) -eq 0 ]; then
            echo_info "Still waiting for RHBK operator... (${elapsed}s elapsed)"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo_error "Timeout waiting for RHBK operator to be ready"
    exit 1
}

# Function to create admin credentials secret
create_admin_secret() {
    echo_header "CREATING ADMIN CREDENTIALS SECRET"

    # Check if secret already exists
    if oc get secret keycloak-initial-admin -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Admin credentials secret already exists"
    else
        echo_info "Creating Keycloak admin credentials secret..."

        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-initial-admin
  namespace: $NAMESPACE
type: Opaque
stringData:
  username: $ADMIN_USER
  password: $ADMIN_PASSWORD
EOF
        echo_success "✓ Admin credentials secret created"
    fi
}

# Function to deploy PostgreSQL database for Keycloak
deploy_postgresql() {
    echo_header "DEPLOYING POSTGRESQL DATABASE"

    # Create database secret
    if ! oc get secret keycloak-db-secret -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_info "Creating database credentials secret..."
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-db-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
  username: keycloak
  password: keycloak
EOF
        echo_success "✓ Database credentials secret created"
    fi

    # Check if PostgreSQL Service already exists
    if ! oc get service postgres -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_info "Creating PostgreSQL Service..."
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $NAMESPACE
  labels:
    app: keycloak-db
    component: database
spec:
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
      protocol: TCP
  selector:
    app: keycloak-db
    component: database
  clusterIP: None
EOF
        echo_success "✓ PostgreSQL Service created"
    fi

    # Check if PostgreSQL StatefulSet already exists
    if oc get statefulset keycloak-db -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "PostgreSQL StatefulSet already exists"
    else
        echo_info "Creating PostgreSQL StatefulSet..."
        cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak-db
  namespace: $NAMESPACE
  labels:
    app: keycloak-db
    component: database
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-db
      component: database
  template:
    metadata:
      labels:
        app: keycloak-db
        component: database
    spec:
      containers:
        - name: postgres
          image: registry.redhat.io/rhel9/postgresql-15:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: postgres
              containerPort: 5432
              protocol: TCP
          env:
            - name: POSTGRESQL_DATABASE
              value: keycloak
            - name: POSTGRESQL_USER
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: username
            - name: POSTGRESQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: password
            - name: PGDATA
              value: "/var/lib/pgsql/data/pgdata"
          volumeMounts:
            - name: postgres-storage
              mountPath: /var/lib/pgsql/data
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U \$POSTGRESQL_USER -d \$POSTGRESQL_DATABASE
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U \$POSTGRESQL_USER -d \$POSTGRESQL_DATABASE
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
  volumeClaimTemplates:
    - metadata:
        name: postgres-storage
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: $STORAGE_CLASS
        resources:
          requests:
            storage: 10Gi
EOF
        echo_success "✓ PostgreSQL StatefulSet created"
    fi

    # Wait for PostgreSQL to be ready
    echo_info "Waiting for PostgreSQL to be ready..."
    oc wait --for=condition=ready pod -l app=keycloak-db -n "$NAMESPACE" --timeout=300s || {
        echo_warning "PostgreSQL pod not ready yet, continuing anyway..."
    }

    echo_success "✓ PostgreSQL deployment complete"
}

# Function to deploy Keycloak instance
deploy_keycloak() {
    echo_header "DEPLOYING KEYCLOAK INSTANCE (RHBK v22+)"

    # Check if Keycloak instance already exists
    if oc get keycloak rhsso-keycloak -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "Keycloak instance 'rhsso-keycloak' already exists"
    else
        echo_info "Creating Keycloak instance with v2alpha1 API..."

        cat <<EOF | oc apply -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: rhsso-keycloak
  namespace: $NAMESPACE
  labels:
    app: sso
spec:
  instances: $KEYCLOAK_INSTANCES
  db:
    vendor: postgres
    host: postgres
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
  http:
    httpEnabled: true
  hostname:
    strict: false
    strictBackchannel: false
  ingress:
    enabled: true
  unsupported:
    podTemplate:
      spec:
        containers:
          - name: keycloak
            resources:
              requests:
                cpu: 500m
                memory: 1Gi
              limits:
                cpu: 1000m
                memory: 2Gi
            volumeMounts:
              - name: keycloak-data
                mountPath: /opt/keycloak/data
        volumes:
          - name: keycloak-data
            persistentVolumeClaim:
              claimName: keycloak-data-pvc
EOF
        echo_success "✓ Keycloak instance created"
    fi

    # Create PVC for Keycloak data
    if ! oc get pvc keycloak-data-pvc -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_info "Creating Keycloak data PVC..."
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keycloak-data-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: $STORAGE_CLASS
EOF
        echo_success "✓ Keycloak data PVC created"
    fi

    # Create OpenShift Route for Keycloak
    if ! oc get route keycloak -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_info "Creating OpenShift Route for Keycloak..."
        cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: $NAMESPACE
  labels:
    app: keycloak
spec:
  to:
    kind: Service
    name: rhsso-keycloak-service
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
        echo_success "✓ Keycloak Route created"
    fi

    # Wait for Keycloak to be ready
    echo_info "Waiting for Keycloak to be ready (this may take several minutes)..."
    local timeout=600
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local status=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$status" = "True" ]; then
            echo_success "✓ Keycloak instance is ready"

            # Display connection information
            local hostname=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.hostname}' 2>/dev/null || echo "")

            if [ -n "$hostname" ]; then
                echo_info "Keycloak Hostname: https://$hostname"
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

# Function to create Kubernetes realm using KeycloakRealmImport
create_kubernetes_realm() {
    echo_header "CREATING KUBERNETES REALM (KeycloakRealmImport)"

    # Check if realm import already exists
    if oc get keycloakrealmimport kubernetes-realm -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_warning "KeycloakRealmImport 'kubernetes-realm' already exists"
    else
        echo_info "Creating Kubernetes realm via KeycloakRealmImport..."

        cat <<EOF | oc apply -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: KeycloakRealmImport
metadata:
  name: kubernetes-realm
  namespace: $NAMESPACE
  labels:
    app: sso
spec:
  keycloakCRName: rhsso-keycloak
  realm:
    id: $REALM_NAME
    realm: $REALM_NAME
    enabled: true
    displayName: "Kubernetes Realm"
    accessTokenLifespan: 300
    bruteForceProtected: true
    failureFactor: 30
    maxDeltaTimeSeconds: 43200
    maxFailureWaitSeconds: 900
    registrationAllowed: false
    rememberMe: true
    resetPasswordAllowed: true
    verifyEmail: false
    clientScopes:
      - name: api.console
        description: "API Console access scope for cost management"
        protocol: openid-connect
        attributes:
          include.in.token.scope: "true"
          display.on.consent.screen: "false"
    defaultDefaultClientScopes:
      - api.console
    clients:
      - clientId: $COST_MGMT_CLIENT_ID
        name: "Cost Management Operator Service Account"
        description: "Service account client for Cost Management Metrics Operator"
        enabled: true
        clientAuthenticatorType: client-secret
        serviceAccountsEnabled: true
        standardFlowEnabled: false
        directAccessGrantsEnabled: false
        implicitFlowEnabled: false
        publicClient: false
        protocol: openid-connect
        defaultClientScopes:
          - openid
          - profile
          - email
          - api.console
        protocolMappers:
          - name: audience-mapper
            protocol: openid-connect
            protocolMapper: oidc-audience-mapper
            config:
              access.token.claim: "true"
              id.token.claim: "false"
              included.client.audience: $COST_MGMT_CLIENT_ID
          - name: client-id-mapper
            protocol: openid-connect
            protocolMapper: oidc-usersessionmodel-note-mapper
            config:
              access.token.claim: "true"
              claim.name: clientId
              id.token.claim: "true"
              user.session.note: clientId
          - name: api-console-mock
            protocol: openid-connect
            protocolMapper: oidc-hardcoded-claim-mapper
            config:
              access.token.claim: "true"
              claim.name: scope
              claim.value: api.console
              id.token.claim: "false"
          - name: org-id-mapper
            protocol: openid-connect
            protocolMapper: oidc-hardcoded-claim-mapper
            config:
              access.token.claim: "true"
              claim.name: org_id
              claim.value: "12345"
              id.token.claim: "false"
              jsonType.label: String
              userinfo.token.claim: "false"
          - name: account-number-mapper
            protocol: openid-connect
            protocolMapper: oidc-hardcoded-claim-mapper
            config:
              access.token.claim: "true"
              claim.name: account_number
              claim.value: "7890123"
              id.token.claim: "false"
              jsonType.label: String
              userinfo.token.claim: "false"
EOF
        echo_success "✓ Kubernetes realm import created"
    fi

    # Wait for realm import to complete
    echo_info "Waiting for realm import to complete..."
    local timeout=120
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        local status=$(oc get keycloakrealmimport kubernetes-realm -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "False")
        if [ "$status" = "True" ]; then
            echo_success "✓ Kubernetes realm import completed"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo_error "Timeout waiting for realm import to complete"
    exit 1
}

# Function to extract client secret
extract_client_secret() {
    echo_header "EXTRACTING CLIENT SECRET"

    echo_info "Waiting for Keycloak to generate client secret..."
    local timeout=60
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        # In RHBK v22+, client secrets are stored in the Keycloak database
        # We need to use the Keycloak Admin API or check if operator creates a secret
        if oc get secret keycloak-client-secret-$COST_MGMT_CLIENT_ID -n "$NAMESPACE" >/dev/null 2>&1; then
            echo_success "✓ Client secret is available"
            local secret=$(oc get secret keycloak-client-secret-$COST_MGMT_CLIENT_ID -n "$NAMESPACE" -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)
            echo_info "Client Secret: $secret"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo_warning "⚠ Client secret not automatically created by operator"
    echo_info "You will need to retrieve it manually from the Keycloak Admin Console"
    echo_info "Or use the Keycloak Admin API to generate/retrieve the secret"
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
    if oc get deployment rhbk-operator -n "$NAMESPACE" >/dev/null 2>&1; then
        local ready_replicas=$(oc get deployment rhbk-operator -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$ready_replicas" = "1" ]; then
            echo_success "✓ RHBK Operator is running"
        else
            echo_error "✗ RHBK Operator is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ RHBK Operator not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check Keycloak instance
    if oc get keycloak rhsso-keycloak -n "$NAMESPACE" >/dev/null 2>&1; then
        local status=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        if [ "$status" = "True" ]; then
            echo_success "✓ Keycloak instance is ready"
        else
            echo_error "✗ Keycloak instance is not ready"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Keycloak instance not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check realm import
    if oc get keycloakrealmimport kubernetes-realm -n "$NAMESPACE" >/dev/null 2>&1; then
        local status=$(oc get keycloakrealmimport kubernetes-realm -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || echo "False")
        if [ "$status" = "True" ]; then
            echo_success "✓ Kubernetes realm import completed"
        else
            echo_error "✗ Kubernetes realm import not completed"
            validation_errors=$((validation_errors + 1))
        fi
    else
        echo_error "✗ Kubernetes realm import not found"
        validation_errors=$((validation_errors + 1))
    fi

    # Check routes/ingress
    if oc get route keycloak-ingress -n "$NAMESPACE" >/dev/null 2>&1; then
        echo_success "✓ Keycloak route exists"
    else
        echo_warning "⚠ Keycloak route not found (may be normal depending on ingress configuration)"
    fi

    if [ $validation_errors -eq 0 ]; then
        echo_success "All validation checks passed!"
        return 0
    else
        echo_error "$validation_errors validation error(s) found"
        return 1
    fi
}

# Function to extract and store client secret
extract_client_secret() {
    echo_header "EXTRACTING CLIENT SECRET"

    # Get Keycloak URL from Route
    local KEYCLOAK_URL=$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$KEYCLOAK_URL" ]; then
        echo_warning "Could not determine Keycloak URL, skipping client secret extraction"
        return 1
    fi

    KEYCLOAK_URL="https://$KEYCLOAK_URL"
    echo_info "Keycloak URL: $KEYCLOAK_URL"

    # Wait a bit for Keycloak to be fully ready
    echo_info "Waiting for Keycloak admin API to be ready..."
    sleep 15

    # Get the actual admin password from the secret created by RHBK operator
    # The operator auto-generates a password and stores it in rhsso-keycloak-initial-admin
    local ACTUAL_ADMIN_PASSWORD=$(oc get secret rhsso-keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    if [ -z "$ACTUAL_ADMIN_PASSWORD" ]; then
        echo_warning "Could not retrieve auto-generated admin password from rhsso-keycloak-initial-admin secret"
        echo_info "Trying user-provided admin password..."
        ACTUAL_ADMIN_PASSWORD="$KEYCLOAK_ADMIN_PASSWORD"
    else
        echo_info "Using auto-generated admin password from RHBK operator"
    fi

    # Get admin token
    echo_info "Obtaining admin access token..."
    local TOKEN_RESPONSE=$(curl -sk -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=$KEYCLOAK_ADMIN_USER" \
        -d "password=$ACTUAL_ADMIN_PASSWORD" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>/dev/null)

    local ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

    if [ -z "$ACCESS_TOKEN" ]; then
        echo_warning "Could not obtain admin token, skipping client secret extraction"
        echo_info "You may need to manually retrieve the client secret from Keycloak admin console"
        echo_info "Token response: $TOKEN_RESPONSE"
        return 1
    fi

    echo_success "Admin token obtained"

    # Get client UUID
    echo_info "Looking up client UUID for '$COST_MGMT_CLIENT_ID'..."
    local CLIENT_DATA=$(curl -sk -X GET "$KEYCLOAK_URL/admin/realms/$REALM_NAME/clients" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)

    local CLIENT_UUID=$(echo "$CLIENT_DATA" | grep -o "\"id\":\"[^\"]*\"[^}]*\"clientId\":\"$COST_MGMT_CLIENT_ID\"" | grep -o "\"id\":\"[^\"]*\"" | cut -d'"' -f4 | head -1)

    if [ -z "$CLIENT_UUID" ]; then
        echo_warning "Could not find client '$COST_MGMT_CLIENT_ID' in realm '$REALM_NAME'"
        return 1
    fi

    echo_success "Found client UUID: $CLIENT_UUID"

    # Get client secret
    echo_info "Retrieving client secret..."
    local CLIENT_SECRET_RESPONSE=$(curl -sk -X GET "$KEYCLOAK_URL/admin/realms/$REALM_NAME/clients/$CLIENT_UUID/client-secret" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)

    local CLIENT_SECRET=$(echo "$CLIENT_SECRET_RESPONSE" | grep -o '"value":"[^"]*' | cut -d'"' -f4)

    if [ -z "$CLIENT_SECRET" ]; then
        echo_warning "Could not retrieve client secret"
        return 1
    fi

    echo_success "Client secret retrieved successfully"

    # Create Kubernetes secret
    echo_info "Creating Kubernetes secret for client credentials..."
    local SECRET_NAME="keycloak-client-secret-cost-management-operator"

    oc create secret generic "$SECRET_NAME" \
        -n "$NAMESPACE" \
        --from-literal=CLIENT_ID="$COST_MGMT_CLIENT_ID" \
        --from-literal=CLIENT_SECRET="$CLIENT_SECRET" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo_success "Created secret: $SECRET_NAME"
        echo_info "  CLIENT_ID: $COST_MGMT_CLIENT_ID"
        echo_info "  CLIENT_SECRET: [hidden - length ${#CLIENT_SECRET} chars]"
    else
        echo_warning "Failed to create secret"
        return 1
    fi

    echo ""
}

# Function to display deployment summary
display_summary() {
    echo_header "DEPLOYMENT SUMMARY"

    # Get connection information
    local hostname=$(oc get keycloak rhsso-keycloak -n "$NAMESPACE" -o jsonpath='{.status.hostname}' 2>/dev/null || echo "")
    local route_url=$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    # Use route URL if hostname is not available
    if [ -z "$hostname" ] && [ -n "$route_url" ]; then
        hostname="$route_url"
    fi

    if [ -z "$hostname" ]; then
        hostname="Not available"
    fi

    echo_info "Keycloak Deployment Information:"
    echo_info "  Operator: Red Hat Build of Keycloak (RHBK) v22+"
    echo_info "  API Version: k8s.keycloak.org/v2alpha1"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  Keycloak URL: https://$hostname"
    echo_info "  Realm: $REALM_NAME"
    echo_info "  Admin User: $ADMIN_USER"
    echo ""

    echo_info "Cost Management Client Information:"
    echo_info "  Client ID: $COST_MGMT_CLIENT_ID"
    echo_info "  Client Type: Service Account (client_credentials flow)"
    echo_info "  Default Scopes: openid, profile, email, api.console"
    echo_info "  Note: api.console scope is defined at realm level"
    echo_info "  Secret stored in: keycloak-client-secret-cost-management-operator"
    echo ""

    # Display admin credential retrieval
    echo_info "To retrieve Keycloak admin credentials:"
    echo_info "  oc get secret keycloak-initial-admin -n $NAMESPACE -o jsonpath='{.data.username}' | base64 -d"
    echo_info "  oc get secret keycloak-initial-admin -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
    echo ""

    echo_info "Next Steps:"
    echo_info "  1. Access Keycloak admin console at: https://$hostname"
    echo_info "  2. Test JWT token generation with: ./test-ocp-dataflow-jwt.sh"
    echo_info "  3. Configure your applications to use the JWT authentication"
    echo ""

    echo_success "RHBK/Keycloak deployment completed successfully!"
}

# Function to clean up (for troubleshooting)
cleanup_deployment() {
    echo_header "CLEANING UP DEPLOYMENT"
    echo_warning "This will remove all RHBK resources. Are you sure? (y/N)"
    read -r confirmation

    if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
        echo_info "Cleanup cancelled"
        return 0
    fi

    echo_info "Removing RHBK resources..."

    # Remove realm imports
    oc delete keycloakrealmimport --all -n "$NAMESPACE" 2>/dev/null || true

    # Remove Keycloak instance
    oc delete keycloak --all -n "$NAMESPACE" 2>/dev/null || true

    # Remove secrets
    oc delete secret keycloak-initial-admin -n "$NAMESPACE" 2>/dev/null || true
    oc delete secret keycloak-db-secret -n "$NAMESPACE" 2>/dev/null || true

    # Remove PVCs
    oc delete pvc keycloak-data-pvc -n "$NAMESPACE" 2>/dev/null || true

    # Remove subscription
    oc delete subscription rhbk-operator -n "$NAMESPACE" 2>/dev/null || true

    # Remove operator group
    oc delete operatorgroup rhbk-operator-group -n "$NAMESPACE" 2>/dev/null || true

    # Remove namespace
    oc delete namespace "$NAMESPACE" 2>/dev/null || true

    echo_success "Cleanup completed"
}

# Main execution function
main() {
    echo_header "RED HAT BUILD OF KEYCLOAK (RHBK) DEPLOYMENT SCRIPT"
    echo_info "This script will deploy RHBK v22+ with Cost Management integration"
    echo_info "Using API version: k8s.keycloak.org/v2alpha1"
    echo_info ""
    echo_info "Configuration:"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  Storage Class: $STORAGE_CLASS"
    echo_info "  Realm: $REALM_NAME"
    echo_info "  Cost Management Client ID: $COST_MGMT_CLIENT_ID"
    echo_info "  Keycloak Instances: $KEYCLOAK_INSTANCES"
    echo ""

    # Execute deployment steps
    check_prerequisites
    create_namespace
    install_rhbk_operator
    create_admin_secret
    deploy_postgresql
    deploy_keycloak
    create_kubernetes_realm
    extract_client_secret

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
        echo "  (no command)    Deploy RHBK with all components"
        echo "  validate        Validate existing deployment"
        echo "  cleanup         Remove all RHBK resources"
        echo "  help            Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  RHBK_NAMESPACE            Target namespace (default: rhsso)"
        echo "  STORAGE_CLASS             Storage class name (default: ocs-storagecluster-ceph-rbd)"
        echo "  KEYCLOAK_ADMIN_USER       Admin username (default: admin)"
        echo "  KEYCLOAK_ADMIN_PASSWORD   Admin password (default: admin)"
        echo "  REALM_NAME                Realm name (default: kubernetes)"
        echo "  COST_MGMT_CLIENT_ID       Client ID (default: cost-management-operator)"
        echo "  KEYCLOAK_INSTANCES        Number of instances (default: 1)"
        echo ""
        echo "Examples:"
        echo "  # Deploy with default settings"
        echo "  $0"
        echo ""
        echo "  # Deploy with custom storage class"
        echo "  STORAGE_CLASS=gp2 $0"
        echo ""
        echo "  # Deploy with HA configuration"
        echo "  KEYCLOAK_INSTANCES=2 $0"
        echo ""
        echo "  # Validate existing deployment"
        echo "  $0 validate"
        echo ""
        echo "  # Clean up deployment"
        echo "  $0 cleanup"
        echo ""
        echo "Migration from RHSSO:"
        echo "  This script uses the new RHBK operator (k8s.keycloak.org/v2alpha1)"
        echo "  which replaces the legacy RHSSO operator (keycloak.org/v1alpha1)"
        echo ""
        echo "  Key differences:"
        echo "  - Uses KeycloakRealmImport instead of KeycloakRealm"
        echo "  - Clients are defined within the realm import"
        echo "  - Different CR structure for Keycloak instances"
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

