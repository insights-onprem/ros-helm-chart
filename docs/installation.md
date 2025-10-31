# ROS-OCP Installation Guide

Complete installation methods, prerequisites, and upgrade procedures for the ROS-OCP Helm chart.

## Table of Contents
- [Prerequisites](#prerequisites)
- [Installation Methods](#installation-methods)
- [OpenShift Prerequisites](#openshift-prerequisites)
- [Upgrade Procedures](#upgrade-procedures)
- [Verification](#verification)

## Prerequisites

### Required Tools

The installation scripts require the following tools:

```bash
# Required
curl    # For downloading releases from GitHub
jq      # For parsing JSON responses
helm    # For installing Helm charts (v3+)
kubectl # For Kubernetes cluster access
```

### Installation by Platform

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install curl jq

# RHEL/CentOS/Fedora
sudo dnf install curl jq

# macOS
brew install curl jq

# Install Helm (all platforms)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Cluster Access

Ensure you have:
- Valid kubeconfig with cluster admin or appropriate namespace permissions
- Ability to create namespaces (or existing target namespace)
- Sufficient cluster resources (see [Configuration Guide](configuration.md))

---

## Installation Methods

### Method 1: Automated Installation (Recommended)

The easiest way to install using the automation script:

**For OpenShift clusters, install Authorino first:**

```bash
# Step 1: Install Authorino (OpenShift only)
./scripts/install-authorino.sh

# Step 2: Install ROS-OCP
./scripts/install-helm-chart.sh
```

**For Kubernetes/KIND clusters:**

```bash
# Install latest release with default settings
./scripts/install-helm-chart.sh

# Custom namespace
export NAMESPACE=ros-production
./scripts/install-helm-chart.sh

# Custom release name
export HELM_RELEASE_NAME=ros-prod
./scripts/install-helm-chart.sh

# Use local chart for development
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh
```

**Features:**
- ✅ Always installs latest stable release
- ✅ Automatic upgrade detection
- ✅ Platform detection (Kubernetes/OpenShift)
- ✅ No version management required
- ✅ Perfect for CI/CD pipelines
- ✅ Automatic fallback to local chart if GitHub unavailable

**Environment Variables:**
- `HELM_RELEASE_NAME`: Helm release name (default: `ros-ocp`)
- `NAMESPACE`: Target namespace (default: `ros-ocp`)
- `VALUES_FILE`: Path to custom values file
- `USE_LOCAL_CHART`: Use local chart instead of GitHub release (default: `false`)
- `LOCAL_CHART_PATH`: Path to local chart directory (default: `../ros-ocp`)

**Note**: JWT authentication is automatically enabled on OpenShift and disabled on KIND/K8s via platform detection.

---

### Method 2: GitHub Release Installation

For CI/CD systems that prefer direct control:

```bash
# Get latest release URL dynamically
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | \
  jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')

# Download and install
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm install ros-ocp ros-ocp-latest.tgz \
  --namespace ros-ocp \
  --create-namespace

# Verify installation
helm status ros-ocp -n ros-ocp
```

**With custom values:**
```bash
helm install ros-ocp ros-ocp-latest.tgz \
  --namespace ros-ocp \
  --create-namespace \
  --values my-values.yaml
```

---

### Method 3: Helm Repository (Future)

```bash
# Add Helm repository (once published)
helm repo add ros-ocp https://insights-onprem.github.io/ros-helm-chart
helm repo update

# Install from repository
helm install ros-ocp ros-ocp/ros-ocp \
  --namespace ros-ocp \
  --create-namespace
```

---

### Method 4: Local Source Installation

For development, testing, or custom modifications:

```bash
# Clone the repository
git clone https://github.com/insights-onprem/ros-helm-chart.git
cd ros-helm-chart

# Method A: Using installation script
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh

# Method B: Direct Helm installation
helm install ros-ocp ./ros-ocp \
  --namespace ros-ocp \
  --create-namespace

# With custom values
helm install ros-ocp ./ros-ocp \
  --namespace ros-ocp \
  --create-namespace \
  --values custom-values.yaml
```

---

### Method 5: KIND Development Environment

Complete local development setup:

```bash
# Step 1: Create KIND cluster with ingress
./scripts/deploy-kind.sh

# Step 2: Deploy ROS-OCP services
./scripts/install-helm-chart.sh

# Access: All services at http://localhost:32061
```

**KIND features:**
- Container runtime support (Docker/Podman)
- Automated ingress controller setup
- Fixed resource allocation (6GB)
- Perfect for CI/CD testing

**See [Scripts Reference](../scripts/README.md) for KIND details**

---

## OpenShift Prerequisites

### 1. OpenShift Data Foundation (ODF)

ODF must be installed and operational:

```bash
# Verify ODF installation
oc get noobaa -n openshift-storage
oc get storagecluster -n openshift-storage

# Check S3 service availability
oc get route s3 -n openshift-storage
```

**ODF endpoints:**
- Internal: `s3.openshift-storage.svc.cluster.local:443`
- External: Check routes in `openshift-storage` namespace

### 2. ODF S3 Credentials Secret

Create credentials secret in deployment namespace:

```bash
# Create secret with ODF S3 credentials
kubectl create secret generic ros-ocp-odf-credentials \
  --namespace=ros-ocp \
  --from-literal=access-key=<your-access-key> \
  --from-literal=secret-key=<your-secret-key>

# Verify secret
kubectl get secret ros-ocp-odf-credentials -n ros-ocp
```

### Getting ODF Credentials

#### Method 1: OpenShift Console (Recommended)

1. Navigate to **Storage** → **Object Storage**
2. Create or select bucket (e.g., `ros-data`)
3. Go to **Access Keys** tab
4. Click **Create Access Key**
5. **Important**: Copy both keys immediately (secret key shown only once)

#### Method 2: NooBaa CLI

```bash
# Install NooBaa CLI
curl -LO https://github.com/noobaa/noobaa-operator/releases/download/v5.13.0/noobaa-linux
chmod +x noobaa-linux
sudo mv noobaa-linux /usr/local/bin/noobaa

# Create account and bucket
noobaa account create ros-account -n openshift-storage
noobaa bucket create ros-data -n openshift-storage
noobaa account attach ros-account --bucket ros-data -n openshift-storage

# Get credentials
noobaa account show ros-account -n openshift-storage
```

#### Method 3: Using Admin Credentials (Not Recommended)

```bash
# Get admin credentials from noobaa-admin secret
kubectl get secret noobaa-admin -n openshift-storage \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d

kubectl get secret noobaa-admin -n openshift-storage \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d

# ⚠️ Warning: These are admin credentials with full access
```

#### Method 4: External Secret Management

```bash
# Example with Vault
vault kv get -field=access_key secret/odf/ros-credentials
vault kv get -field=secret_key secret/odf/ros-credentials

# Example with Sealed Secrets
kubectl create secret generic ros-ocp-odf-credentials \
  --from-literal=access-key=<key> \
  --from-literal=secret-key=<secret> \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml
```

**Security Best Practices:**
- ✅ Use dedicated service accounts (not admin credentials)
- ✅ Rotate credentials regularly
- ✅ Store in external secret management (Vault, Sealed Secrets)
- ✅ Use least-privilege access (specific buckets only)
- ❌ Never commit credentials to version control

### 3. Namespace Permissions

Ensure you have permissions to:
- Create secrets in target namespace
- Deploy Helm charts
- Access ODF resources
- Create routes (OpenShift)

```bash
# Verify permissions
oc auth can-i create secrets -n ros-ocp
oc auth can-i create deployments -n ros-ocp
oc auth can-i create routes -n ros-ocp
```

### 4. Authorino Setup for OAuth2 Authentication

Authorino is required for OAuth2 TokenReview authentication on the backend API. This enables OpenShift Console UI users to access the ROS-OCP backend with their session tokens.

**Security Features:**
- **TLS Encryption**: All communication between Envoy and Authorino is encrypted using TLS
- **Certificate Management**: Certificates are automatically generated and rotated by OpenShift's service-ca operator
- **NetworkPolicy**: Access to Authorino is restricted to authorized pods only (critical for access control)
- **Namespace-Scoped**: Authorino is configured with `clusterWide: false` to limit blast radius

#### Install Authorino Using Automated Script

The easiest way to set up Authorino:

```bash
# Install Authorino Operator and create instance
./scripts/install-authorino.sh

# Custom namespace (must match your ROS-OCP deployment)
NAMESPACE=ros-production ./scripts/install-authorino.sh

# Verify installation
./scripts/install-authorino.sh --verify-only
```

#### Manual Authorino Installation

If you prefer manual installation:

**Step 1: Install Authorino Operator**

```bash
# Check if an OperatorGroup already exists (openshift-operators usually has 'global-operators')
EXISTING_OG=$(oc get operatorgroups -n openshift-operators -o name 2>/dev/null | head -1)

if [ -n "$EXISTING_OG" ]; then
  echo "OperatorGroup already exists: $EXISTING_OG"
  echo "Skipping OperatorGroup creation"
else
  # Create OperatorGroup if none exists
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: authorino-operator-group
  namespace: openshift-operators
spec: {}
EOF
fi

# Create Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: authorino-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: authorino-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for operator to be ready
oc get csv -n openshift-operators | grep authorino
```

**Step 2: Create TLS Service for Authorino**

```bash
# Create service with annotation to trigger certificate generation
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: authorino-tls
  namespace: ros-ocp
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert
spec:
  selector:
    app: authorino
  ports:
  - name: grpc
    port: 50051
    targetPort: 50051
    protocol: TCP
  type: ClusterIP
EOF

# Wait for service-ca to generate certificate
oc wait --for=jsonpath='{.data.tls\.crt}' secret/authorino-server-cert -n ros-ocp --timeout=60s
```

**Step 3: Create Authorino Instance with TLS**

```bash
# Create Authorino CR with TLS enabled
oc apply -f - <<EOF
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: ros-ocp
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

# Wait for Authorino pods to be ready
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=authorino -n ros-ocp --timeout=120s
```

**Step 4: Create RBAC for TokenReview**

```bash
# Create ClusterRole
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: authorino-tokenreview
rules:
- apiGroups:
  - authentication.k8s.io
  resources:
  - tokenreviews
  verbs:
  - create
EOF

# Create ClusterRoleBinding
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: authorino-tokenreview-ros-ocp
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: authorino-tokenreview
subjects:
- kind: ServiceAccount
  name: authorino-authorino
  namespace: ros-ocp
EOF
```

**Step 4: Verify Installation**

```bash
# Check Operator
oc get csv -n openshift-operators | grep authorino

# Check Authorino instance
oc get authorino -n ros-ocp

# Check Authorino pods
oc get pods -n ros-ocp -l app.kubernetes.io/name=authorino

# Check Authorino service
oc get svc -n ros-ocp | grep authorino

# Check RBAC
oc get clusterrole authorino-tokenreview
oc get clusterrolebinding authorino-tokenreview-ros-ocp
```

#### What Authorino Does

Authorino provides:
- **OAuth2 TokenReview**: Validates user session tokens from OpenShift Console
- **Token Validation**: Authenticates requests via Kubernetes TokenReview API
- **Header Injection**: Extracts username and UID for rh-identity header transformation
- **Audience Validation**: Ensures tokens are intended for the correct service

**Authentication Flow:**
1. User accesses ROS-OCP via OpenShift Console UI
2. Console includes user's session token in request
3. Envoy proxy forwards request to Authorino for validation
4. Authorino validates token via Kubernetes TokenReview API
5. If valid, Authorino injects headers (username, UID)
6. Envoy transforms headers into rh-identity format
7. Backend receives authenticated request

**For more details, see [OAuth2 TokenReview Authentication Guide](oauth2-tokenreview-authentication.md)**

### 5. Resource Requirements

**Single Node OpenShift (SNO):**
- SNO cluster with ODF installed
- 30GB+ block devices for ODF
- Additional 6GB RAM for ROS-OCP workloads
- Additional 2 CPU cores
- Authorino resources (minimal: ~100Mi RAM, 0.1 CPU)

**See [Configuration Guide](configuration.md) for detailed requirements**

---

## Upgrade Procedures

### Upgrade Using Scripts (Recommended)

```bash
# Upgrade to latest release automatically
./scripts/install-helm-chart.sh

# The script detects existing installations and performs upgrades
# Uses GitHub releases by default
```

### Manual Helm Upgrade

#### From GitHub Release

```bash
# Get latest release
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | \
  jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')

# Download and upgrade
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm upgrade ros-ocp ros-ocp-latest.tgz -n ros-ocp

# With custom values
helm upgrade ros-ocp ros-ocp-latest.tgz -n ros-ocp --values my-values.yaml
```

#### From Local Source

```bash
# Using script
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh

# Direct Helm command
helm upgrade ros-ocp ./ros-ocp -n ros-ocp
```

### Upgrade Considerations

**Before upgrading:**
1. Check release notes for breaking changes
2. Backup persistent data if needed
3. Verify cluster resources are sufficient
4. Test in non-production environment first

**During upgrade:**
- Helm performs rolling updates by default
- Some downtime may occur during database upgrades
- Monitor pod status: `kubectl get pods -n ros-ocp -w`

**After upgrade:**
```bash
# Verify upgrade
./scripts/install-helm-chart.sh status

# Run health checks
./scripts/install-helm-chart.sh health

# Check version
helm list -n ros-ocp
```

---

## Verification

### Deployment Status

```bash
# Check Helm release
helm status ros-ocp -n ros-ocp

# Check all pods
kubectl get pods -n ros-ocp

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=ros-ocp -n ros-ocp --timeout=300s
```

### Service Health

```bash
# Run automated health checks
./scripts/install-helm-chart.sh health

# Test ingress endpoint
curl http://localhost:32061/ready  # KIND
curl http://<route-host>/ready      # OpenShift

# Check API endpoints
curl http://localhost:32061/api/ros/status
```

### Storage Verification

```bash
# Check persistent volume claims
kubectl get pvc -n ros-ocp

# Verify all PVCs are bound
kubectl get pvc -n ros-ocp | grep -v Bound && echo "ISSUE: Unbound PVCs found" || echo "OK: All PVCs bound"

# Check storage class
kubectl get pvc -n ros-ocp -o jsonpath='{.items[*].spec.storageClassName}' | tr ' ' '\n' | sort -u
```

### Service Connectivity

```bash
# Test database connections
kubectl exec -it deployment/ros-ocp-rosocp-api -n ros-ocp -- \
  env | grep DATABASE_URL

# Test Kafka connectivity
kubectl exec -it statefulset/ros-ocp-kafka -n ros-ocp -- \
  kafka-topics.sh --list --bootstrap-server localhost:29092

# Test MinIO/ODF access (Kubernetes)
kubectl exec -it statefulset/ros-ocp-minio -n ros-ocp -- \
  mc admin info local
```

---

## Troubleshooting Installation

### Script Execution Issues

**Missing prerequisites:**
```bash
# Check required tools
which curl jq helm kubectl

# Install missing tools
sudo apt-get install curl jq  # Ubuntu/Debian
brew install curl jq           # macOS
```

**GitHub API rate limiting:**
```bash
# Check rate limit
curl -s https://api.github.com/rate_limit

# Use authentication token
export GITHUB_TOKEN="your_personal_access_token"
./scripts/install-helm-chart.sh
```

**Script permissions:**
```bash
# Make executable
chmod +x scripts/install-helm-chart.sh

# Run with explicit bash
bash scripts/install-helm-chart.sh
```

### Network Issues

```bash
# Test GitHub connectivity
curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest

# Verbose debugging
curl -v https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest

# Manual download
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | \
  jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
```

### Resource Issues

```bash
# Check node resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check available resources
kubectl top nodes  # requires metrics-server
```

**See [Troubleshooting Guide](troubleshooting.md) for comprehensive solutions**

---

## Next Steps

After successful installation:

1. **Set Up Authorino** (OpenShift only): See [Authorino Setup](#4-authorino-setup-for-oauth2-authentication)
2. **Configure Access**: See [Configuration Guide](configuration.md)
3. **Set Up JWT Auth**: See [JWT Authentication Guide](native-jwt-authentication.md)
4. **Configure TLS**: See [TLS Setup Guide](cost-management-operator-tls-setup.md)
5. **Run Tests**: See [Scripts Reference](../scripts/README.md)

---

**Related Documentation:**
- [Configuration Guide](configuration.md)
- [Platform Guide](platform-guide.md)
- [Quick Start Guide](quickstart.md)
- [Troubleshooting Guide](troubleshooting.md)

