# Cost Management On-Premise Configuration Guide

Complete configuration reference for resource requirements, storage, and access configuration.

## Table of Contents
- [Resource Requirements](#resource-requirements)
- [Storage Configuration](#storage-configuration)
- [Access Points](#access-points)
- [Configuration Values](#configuration-values)
- [Platform-Specific Configuration](#platform-specific-configuration)

## Resource Requirements

### Minimum Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **Memory** | 8GB | 12GB+ |
| **CPU** | 4 cores | 6+ cores |
| **Storage** | 30GB | 50GB+ |

### Service-Level Resource Breakdown

#### CPU Requests (Total: ~2 cores)
| Service | CPU Request | CPU Limit |
|---------|-------------|-----------|
| PostgreSQL (3×) | 300m | 1500m |
| Kafka + Zookeeper | 350m | 750m |
| Kruize | 500m | 1000m |
| Application Services | 800m | 1200m |
| **Total** | **~2 cores** | **~4.5 cores** |

#### Memory Requests (Total: ~4.5GB)
| Service | Memory Request | Memory Limit |
|---------|----------------|--------------|
| PostgreSQL (3×) | 768MB | 1536MB |
| Kafka + Zookeeper | 768MB | 1536MB |
| Kruize | 1GB | 2GB |
| Application Services | 2GB | 3GB |
| **Total** | **~4.5GB** | **~8GB** |

#### Storage Requirements (Total: ~33GB)
| Component | Size | Access Mode | Notes |
|-----------|------|-------------|-------|
| PostgreSQL ROS | 10GB | RWO | Main database |
| PostgreSQL Kruize | 10GB | RWO | Kruize database |
| PostgreSQL Sources | 10GB | RWO | Sources database |
| Kafka | 10GB | RWO | Message storage |
| Zookeeper | 5GB | RWO | Coordination data |
| MinIO (K8s only) | 20GB | RWO | Object storage |
| **Total** | **~65GB** | - | Development: 30GB+ |

---

## Namespace Requirements

### Cost Management Operator Label

**REQUIRED**: The deployment namespace must be labeled for the Cost Management Metrics Operator to collect resource optimization data.

**Label:**
```yaml
cost_management_optimizations: "true"
```

**Automatic Application:**
When using `scripts/install-helm-chart.sh`, this label is automatically applied to the namespace during deployment.

**Manual Application:**
```bash
# Apply label to namespace
kubectl label namespace cost-onprem cost_management_optimizations=true

# Verify label
kubectl get namespace cost-onprem --show-labels | grep cost_management

# Remove label (if needed)
kubectl label namespace cost-onprem cost_management_optimizations-
```

**Why This Label is Required:**
The Cost Management Metrics Operator uses this label to filter which namespaces to collect resource optimization (ROS) metrics from. Without this label:
- ❌ No resource optimization data will be collected from the namespace
- ❌ No ROS files will be generated
- ❌ No data will be uploaded to the ingress service
- ❌ Kruize will not receive metrics for optimization recommendations

**Legacy Label (also supported for backward compatibility):**
```yaml
insights_cost_management_optimizations: "true"
```
> **Note**: The legacy label is supported for backward compatibility but the generic `cost_management_optimizations` label is recommended for new deployments (introduced in koku-metrics-operator v4.1.0).

---

## OpenShift Requirements

### Single Node OpenShift (SNO)

**Base Requirements:**
- SNO cluster running OpenShift 4.18+
- OpenShift Data Foundation (ODF) installed
- 30GB+ block devices for ODF

**Additional Resources for Cost Management On-Premise:**
- **Additional Memory**: 6GB+ RAM
- **Additional CPU**: 2+ cores
- **Total Node**: SNO minimum + ROS requirements

**ODF Configuration:**
- **Storage Class**: `ocs-storagecluster-ceph-rbd` (auto-detected)
- **Volume Mode**: Filesystem
- **Access Mode**: ReadWriteOnce (RWO)

---

## Storage Configuration

### Dual Storage Backend Support

The chart automatically selects the appropriate storage backend based on platform:

| Platform | Storage Backend | Deployment Method |
|----------|----------------|-------------------|
| **Kubernetes/KIND** | MinIO | StatefulSet (automatic) |
| **OpenShift** | ODF (NooBaa) | Existing installation |

### MinIO Configuration (Kubernetes/KIND)

**Automatic Deployment:**
```yaml
# Default values
minio:
  image:
    repository: quay.io/minio/minio
    tag: "RELEASE.2025-07-23T15-54-02Z"
  storage:
    size: 20Gi
  rootUser: minioaccesskey
  rootPassword: miniosecretkey
  ports:
    api: 9000
    console: 9990
```

**Access:**
- **API Endpoint**: `cost-onprem-minio:9000` (internal)
- **Console**: `http://localhost:32061/minio` (external)
- **Credentials**: `minioaccesskey` / `miniosecretkey`

**S3 Configuration:**
```yaml
ingress:
  storage:
    bucket: "ros-data"
    useSSL: false
    urlExpiration: 172800
    pathPrefix: "ros"
```

### ODF Configuration (OpenShift)

**Prerequisites:**
- ODF installed in `openshift-storage` namespace
- NooBaa S3 service running
- S3 credentials secret created (see [Installation Guide](installation.md#openshift-prerequisites))

**Configuration:**
```yaml
odf:
  endpoint: "s3.openshift-storage.svc.cluster.local"
  region: "us-east-1"
  bucket: "ros-data"
  pathStyle: true
  useSSL: true
  port: 443
  credentials:
    secretName: "cost-onprem-odf-credentials"
```

**Access:**
- **Internal**: `s3.openshift-storage.svc.cluster.local:443`
- **External**: Via OpenShift routes (check `openshift-storage` namespace)

### Storage Class Configuration

**Automatic Detection:**
```bash
# Kubernetes - uses default storage class
kubectl get storageclass

# OpenShift - uses ODF storage class
kubectl get storageclass ocs-storagecluster-ceph-rbd
```

**Custom Storage Class:**
```yaml
# values.yaml override
global:
  storageClass: "fast-ssd"
```

---

## Access Points

### Kubernetes (KIND) Deployment

All services accessible through ingress controller on **port 32061**:

| Service | URL | Description |
|---------|-----|-------------|
| **Health Check** | `http://localhost:32061/ready` | Ingress health endpoint |
| **ROS API Status** | `http://localhost:32061/status` | Main API status |
| **ROS API** | `http://localhost:32061/api/ros/*` | Recommendations API |
| **Kruize API** | `http://localhost:32061/api/kruize/*` | Optimization engine |
| **Sources API** | `http://localhost:32061/api/sources/*` | Source management |
| **Upload API** | `http://localhost:32061/api/ingress/*` | Data upload endpoint |
| **MinIO Console** | `http://localhost:32061/minio` | Storage admin UI |

**Testing Endpoints:**
```bash
# Health check
curl http://localhost:32061/ready

# ROS API status
curl http://localhost:32061/status

# List recommendations
curl http://localhost:32061/api/ros/recommendations

# Kruize optimization
curl http://localhost:32061/api/kruize/listApplications
```

### OpenShift Deployment

Services accessible through OpenShift Routes:

```bash
# List all routes
oc get routes -n cost-onprem

# Example routes
oc get route cost-onprem-main -n cost-onprem       # Main API (Cost Management On-Premise API)
oc get route cost-onprem-ingress -n cost-onprem    # Ingress API (file upload)
oc get route cost-onprem-ui -n cost-onprem         # UI (web interface)
```

**Access Pattern:**
```bash
# Get route URLs
MAIN_ROUTE=$(oc get route cost-onprem-main -n cost-onprem -o jsonpath='{.spec.host}')
INGRESS_ROUTE=$(oc get route cost-onprem-ingress -n cost-onprem -o jsonpath='{.spec.host}')
UI_ROUTE=$(oc get route cost-onprem-ui -n cost-onprem -o jsonpath='{.spec.host}')

# Test endpoints
curl https://$MAIN_ROUTE/status
curl https://$INGRESS_ROUTE/api/ingress/ready

# Access UI (requires OpenShift authentication)
echo "UI available at: https://$UI_ROUTE"
```

### Port Forwarding (Alternative Access)

For direct service access without ingress/routes:

```bash
# Cost Management On-Premise API
kubectl port-forward svc/cost-onprem-ros-api 8000:8000 -n cost-onprem
# Access: http://localhost:8000

# Kruize API
kubectl port-forward svc/cost-onprem-kruize 8080:8080 -n cost-onprem
# Access: http://localhost:8080

# MinIO Console (Kubernetes only)
kubectl port-forward svc/cost-onprem-minio 9990:9990 -n cost-onprem
# Access: http://localhost:9990

# PostgreSQL (for debugging)
kubectl port-forward svc/cost-onprem-db-ros 5432:5432 -n cost-onprem
# Connection: postgresql://postgres:postgres@localhost:5432/postgres
```

### Service Mesh / Ingress Configuration

**Kubernetes Ingress:**
```yaml
serviceIngress:
  className: nginx
  hosts:
    - host: ros.example.com
      paths:
        - path: /
          pathType: Prefix
```

**OpenShift Routes:**
```yaml
serviceRoute:
  annotations:
    haproxy.router.openshift.io/timeout: "30s"
  hosts:
    - host: ""  # Uses cluster default domain
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

---

## Configuration Values

### Basic Configuration

```yaml
# Custom namespace
namespace: ros-production

# Global settings
global:
  storageClass: "fast-ssd"
  pullPolicy: IfNotPresent
  imagePullSecrets: []
```

### Resource Customization

```yaml
# Adjust Kruize resources
resources:
  kruize:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"

# Adjust database resources
resources:
  database:
    requests:
      memory: "512Mi"
      cpu: "200m"
    limits:
      memory: "1Gi"
      cpu: "500m"
```

### Database Configuration

```yaml
database:
  ros:
    host: internal  # or external hostname
    port: 5432
    name: postgres
    user: postgres
    password: postgres
    sslMode: disable
    storage:
      size: 10Gi

  kruize:
    host: internal
    storage:
      size: 10Gi

  sources:
    host: internal
    name: sources_api_development
    storage:
      size: 10Gi
```

### Kafka Configuration

```yaml
kafka:
  broker:
    brokerId: 1
    port: 29092
    storage:
      size: 10Gi
    offsetsTopicReplicationFactor: 1
    autoCreateTopicsEnable: true

  zookeeper:
    serverId: 1
    clientPort: 32181
    storage:
      size: 5Gi
```

### Application Configuration

```yaml
# Cost Management On-Premise API
ros:
  api:
    port: 8000
    metricsPort: 9000
    pathPrefix: /api
    rbacEnable: false
    logLevel: INFO
  processor:
    metricsPort: 9000
    logLevel: INFO
  recommendationPoller:
    metricsPort: 9000
    logLevel: INFO

# Kruize
kruize:
  port: 8080
  env:
    loggingLevel: debug
    clusterType: kubernetes
    k8sType: openshift
    logAllHttpReqAndResponse: true

# Sources API
sourcesApi:
  port: 8000
  logLevel: DEBUG
  bypassRbac: true
  sourcesEnv: prod

# Ingress service
ingress:
  port: 8080
  upload:
    maxUploadSize: 104857600  # 100MB
    maxMemory: 33554432        # 32MB
  logging:
    level: "info"
    format: "json"

# UI (OpenShift only)
ui:
  replicaCount: 1
  oauthProxy:
    image:
      repository: registry.redhat.io/openshift4/ose-oauth-proxy-rhel9
      tag: "latest"
      pullPolicy: IfNotPresent
    resources:
      limits:
        cpu: "100m"
        memory: "128Mi"
      requests:
        cpu: "50m"
        memory: "64Mi"
  app:
    image:
      repository: quay.io/insights-onprem/koku-ui-mfe-on-prem
      tag: "0.0.14"
      pullPolicy: IfNotPresent
    port: 8080
    resources:
      limits:
        cpu: "100m"
        memory: "128Mi"
      requests:
        cpu: "50m"
        memory: "64Mi"
```

### Environment-Specific Values Files

```bash
# Development
helm install cost-onprem ./cost-onprem -f values-dev.yaml

# Staging
helm install cost-onprem ./cost-onprem -f values-staging.yaml

# Production
helm install cost-onprem ./cost-onprem -f values-production.yaml
```

---

## Platform-Specific Configuration

### Kubernetes-Specific

```yaml
# Use MinIO
minio:
  enabled: true
  storage:
    size: 20Gi

# Kubernetes Ingress
serviceIngress:
  className: nginx
  enabled: true

# Disable OpenShift features
serviceRoute:
  enabled: false
```

### OpenShift-Specific

```yaml
# Use ODF
odf:
  endpoint: "s3.openshift-storage.svc.cluster.local"
  bucket: "ros-data"
  credentials:
    secretName: "cost-onprem-odf-credentials"

# OpenShift Routes
serviceRoute:
  enabled: true
  tls:
    termination: edge

# Disable Kubernetes features
minio:
  enabled: false
serviceIngress:
  enabled: false

# OpenShift platform configuration
global:
  platform:
    openshift: true
    domain: "apps.cluster.example.com"
```

**See [Platform Guide](platform-guide.md) for detailed platform differences**

---

## Security Configuration

### Service Accounts

```yaml
serviceAccount:
  create: true
  name: cost-onprem-backend
```

### Network Policies

Network policies are automatically deployed on OpenShift to secure service-to-service communication and enforce authentication through Envoy sidecars.

**Purpose:**
- ✅ Enforce authentication via Envoy sidecars (port 9080)
- ✅ Restrict direct access to backend application containers
- ✅ Allow Prometheus metrics scraping from `openshift-monitoring` namespace
- ✅ Enable internal service-to-service communication within `cost-onprem` namespace

**Key Policies:**
1. **Ingress Network Policy**: Allows external file uploads from `openshift-ingress` namespace to Envoy sidecar on port 9080
2. **Kruize Network Policy**: Allows internal service communication only (processor, poller, housekeeper) on port 8080
3. **Cost Management On-Premise Metrics Policies**: Allow Prometheus metrics scraping on port 9000 for API, Processor, and Recommendation Poller
4. **Cost Management On-Premise API Access Policy**: Allows external REST API access from `openshift-ingress` namespace to Envoy sidecar on port 9080
5. **Sources API Policy**: Allows internal service communication only (housekeeper) on port 8000

**Platform-Specific:**
```yaml
# OpenShift - Automatically enabled with JWT auth
jwt_auth:
  enabled: true  # Auto-detected
networkPolicy:
  enabled: true  # Deployed automatically

# Kubernetes/KIND - Disabled (no JWT auth)
jwt_auth:
  enabled: false  # Auto-detected
networkPolicy:
  enabled: false  # Not deployed
```

**Impact on Service Communication:**
- External requests MUST go through Envoy sidecars (port 9080) with proper authentication
- Direct access to backend ports (8000, 8081) is blocked from outside the namespace
- Prometheus can access `/metrics` endpoints (port 9000) without authentication
- Internal services can communicate freely within the same namespace

**See [JWT Authentication Guide](native-jwt-authentication.md#network-policies) for detailed policy configuration**

### Pod Security

```yaml
# Pod security context
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1001
  fsGroup: 1001

securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  fsGroup: 1001
  seccompProfile:
    type: RuntimeDefault
```

---

## Advanced Configuration

### High Availability

```yaml
# Multiple replicas for stateless services
ingress:
  replicaCount: 2

ros:
  api:
    replicaCount: 2

# Pod disruption budget
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

### Health Probes

```yaml
# Customize health checks
probes:
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

# Service-specific probes
ingress:
  livenessProbe:
    enabled: true
    initialDelaySeconds: 30
  readinessProbe:
    enabled: true
    initialDelaySeconds: 10
```

### Monitoring & Metrics

```yaml
ingress:
  metrics:
    enabled: true
    path: "/metrics"
    port: 8080

kruize:
  env:
    plots: true
    logAllHttpReqAndResponse: true
```

---

## Validation

### Verify Configuration

```bash
# Test configuration rendering
helm template cost-onprem ./cost-onprem --values my-values.yaml | kubectl apply --dry-run=client -f -

# Check computed values
helm get values cost-onprem -n cost-onprem

# Validate against schema
helm lint ./cost-onprem --values my-values.yaml
```

### Post-Deployment Checks

```bash
# Check all resources
kubectl get all -n cost-onprem

# Check storage
kubectl get pvc -n cost-onprem

# Check configuration
kubectl get configmaps -n cost-onprem
kubectl get secrets -n cost-onprem
```

---

## Next Steps

- **Installation**: See [Installation Guide](installation.md)
- **Platform Specifics**: See [Platform Guide](platform-guide.md)
- **JWT Authentication**: See [JWT Auth Guide](native-jwt-authentication.md)
- **Troubleshooting**: See [Troubleshooting Guide](troubleshooting.md)

---

**Related Documentation:**
- [Installation Guide](installation.md)
- [Platform Guide](platform-guide.md)
- [Quick Start Guide](quickstart.md)

