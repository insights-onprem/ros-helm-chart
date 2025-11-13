# UI OAuth Authentication for ROS OCP

## Overview

The UI for ROS OCP uses OpenShift's native OAuth proxy as a sidecar container to provide authentication. This allows users to authenticate using their OpenShift credentials without requiring additional identity providers.

### Quick Reference

| Component | Purpose | Location | Port |
|-----------|---------|----------|------|
| **OAuth Proxy** | Authentication proxy with OpenShift OAuth | Sidecar in ui pod | 8443 (HTTPS) |
| **Nginx** | Web server and API proxy | Inside UI app container | 8080 (HTTP) |
| **UI App** | Frontend application | Main container in pod | 8080 (HTTP) |
| **ROS API** | Backend API service | Separate service | 8000 (HTTP) |
| **OpenShift OAuth Server** | Token validation and user authentication | Cluster control plane | 443 (HTTPS) |
| **OpenShift Route** | External access with TLS reencrypt | Route resource | 443 (HTTPS) |
| **Service CA Operator** | Auto-generates TLS certificates | Cluster-wide operator | N/A |

### Authentication Chain

```
User → OpenShift Route → OAuth Proxy → OpenShift OAuth → Validate
                              ↓                              ↓
                         localhost:8080 ← Session Cookie ← Success
                              ↓
                           Nginx
                              ↓
                    ┌─────────┴─────────┐
                    ↓                   ↓
                 UI App            ROS API
              (Static files)    (API requests with Bearer token)
```

## Architecture

### Deployment Architecture

```mermaid
%%{init: {'flowchart': {'curve': 'stepAfter'}}}%%
flowchart LR
    subgraph User["User"]
        U["<b>Browser</b><br/>Session Cookie"]
    end

    subgraph Route["OpenShift Route"]
        R["<b>Route: ui</b><br/>TLS: reencrypt<br/>Port: 443"]
    end

    subgraph Pod["Pod: ui"]
        subgraph Proxy["OAuth Proxy Container"]
            P["<b>OAuth Proxy</b><br/>Port: 8443"]
        end

        subgraph App["UI App Container"]
            N["<b>Nginx</b><br/>Port: 8080<br/>• Serves static files<br/>• Proxies /api to ROS API<br/>• Adds Bearer token"]
        end

        P -->|7. localhost:8080<br/>X-Forwarded-Access-Token: <token>| N
        N -->|8. /api requests<br/>Authorization: Bearer <token>| ROSAPI
    end

    subgraph ROSAPI["ROS API Service"]
        API["<b>ROS API</b><br/>Port: 8000<br/>Backend API"]
    end

    subgraph OAuth["OpenShift OAuth"]
        O["<b>OAuth Server</b><br/>authentication.k8s.io"]
    end

    U -->|1. HTTPS Request| R
    R -->|2. Forward| P
    P -.->|3. No cookie:<br/>Redirect| U
    U -->|4. Login| O
    O -.->|5. Callback| P
    P -.->|6. Set cookie| U
    N -->|7. Response| P
    P -->|8. Response| U
    ROSAPI -->|9. API Response| N

    style P fill:#90caf9,stroke:#333,stroke-width:2px,color:#000
    style N fill:#81c784,stroke:#333,stroke-width:2px,color:#000
    style ROSAPI fill:#ffb74d,stroke:#333,stroke-width:2px,color:#000
    style O fill:#f48fb1,stroke:#333,stroke-width:2px,color:#000
    style U fill:#e1bee7,stroke:#333,stroke-width:2px,color:#000
    style R fill:#ffcc80,stroke:#333,stroke-width:2px,color:#000
```

### Authentication Flow Sequence

```mermaid
%%{init: {'theme':'base', 'themeVariables': {'primaryTextColor':'#000', 'secondaryTextColor':'#000', 'tertiaryTextColor':'#000', 'noteTextColor':'#000', 'activationBorderColor':'#000', 'activationBkgColor':'#fff'}}}%%
sequenceDiagram
    autonumber
    participant User as User Browser
    participant Route as OpenShift Route
    participant Proxy as OAuth Proxy<br/>(Sidecar)
    participant OAuth as OpenShift OAuth
    participant Nginx as Nginx<br/>(in UI App)
    participant ROSAPI as ROS API

    Note over User,ROSAPI: First Request (No Session)

    User->>Route: HTTPS GET /<br/>(no cookie)

    Route->>Proxy: Forward to port 8443

    Proxy->>Proxy: Check for session cookie<br/>Cookie not found

    Proxy-->>User: 302 Redirect<br/>Location: /oauth/authorize?...

    User->>OAuth: GET /oauth/authorize

    OAuth->>User: Present login page

    User->>OAuth: POST credentials

    OAuth->>OAuth: Validate credentials

    OAuth-->>User: 302 Redirect<br/>Location: /oauth/callback?code=...

    User->>Route: GET /oauth/callback?code=...

    Route->>Proxy: Forward callback

    Proxy->>OAuth: Exchange code for token<br/>POST /oauth/token

    OAuth-->>Proxy: Access token + user info

    Proxy->>Proxy: Validate token<br/>Create session

    Proxy-->>User: 302 Redirect to /<br/>Set-Cookie: _oauth_proxy=...

    User->>Route: GET /<br/>Cookie: _oauth_proxy=...

    Route->>Proxy: Forward with cookie

    Proxy->>Proxy: Validate session cookie<br/>Session valid

    Proxy->>Nginx: GET / (localhost:8080)

    Nginx->>Nginx: Serve static files<br/>(from filesystem)

    Nginx-->>Proxy: HTML response

    Proxy-->>User: 200 OK<br/>HTML content

    Note over User,ROSAPI: API Request (With Session)

    User->>Route: GET /api/recommendations<br/>Cookie: _oauth_proxy=...

    Route->>Proxy: Forward with cookie

    Proxy->>Proxy: Validate session cookie<br/>Session valid<br/>Extract access token

    Proxy->>Nginx: GET /api/recommendations<br/>X-Forwarded-Access-Token: <token>

    Nginx->>Nginx: Match /api location<br/>Extract token from header

    Nginx->>ROSAPI: GET /api/recommendations<br/>Authorization: Bearer <token>

    ROSAPI->>ROSAPI: Validate Bearer token

    ROSAPI-->>Nginx: 200 OK<br/>JSON response

    Nginx-->>Proxy: JSON response

    Proxy-->>User: 200 OK<br/>JSON content

    Note over User,ROSAPI: Session Expired

    User->>Route: GET /<br/>Cookie: _oauth_proxy=... (expired)

    Route->>Proxy: Forward with expired cookie

    Proxy->>Proxy: Validate session cookie<br/>Session expired

    Proxy-->>User: 302 Redirect<br/>Location: /oauth/authorize?...<br/>(repeat login flow)
```

### Components

- **OAuth Proxy**: Sidecar container (`registry.redhat.io/openshift4/ose-oauth-proxy-rhel9`) handling authentication
- **Nginx**: Web server running inside the UI app container that serves static files and proxies API requests to ROS API
- **UI App**: Frontend application container serving the web interface with embedded Nginx
- **ROS API**: Backend API service that receives authenticated requests with Bearer tokens
- **OpenShift OAuth Server**: Cluster's built-in OAuth provider for user authentication
- **OpenShift Route**: Exposes the service with TLS reencrypt termination
- **Service CA Operator**: Automatically generates and rotates TLS certificates
- **ServiceAccount**: Configured with OAuth redirect annotation for callback URL

## Configuration

### Helm Values

```yaml
# UI (OpenShift only - OAuth protected frontend)
ui:
  replicaCount: 1
  oauthProxy:
    image:
      repository: registry.redhat.io/openshift4/ose-oauth-proxy-rhel9
      pullPolicy: IfNotPresent
      tag: "latest"
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

### OAuth Proxy Arguments

The OAuth proxy is configured with the following arguments:

```yaml
args:
- --https-address=:8443                    # Listen on HTTPS port 8443
- --provider=openshift                     # Use OpenShift OAuth
- --openshift-service-account=<name>-ui    # ServiceAccount name for OAuth callbacks
- --cookie-secret-file=/etc/proxy/secrets/session-secret  # Session encryption key
- --tls-cert=/etc/tls/private/tls.crt     # TLS certificate (auto-generated)
- --tls-key=/etc/tls/private/tls.key      # TLS private key (auto-generated)
- --upstream=http://localhost:8080         # Forward to UI app on localhost
- --pass-host-header=false                 # Don't forward original Host header
- --skip-provider-button                   # Skip "Log in with OpenShift" button
- --skip-auth-preflight                    # Skip OAuth consent screen
```

### ServiceAccount Annotation

The ServiceAccount requires a special annotation to enable OAuth redirects:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: <fullname>-ui
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: |
      {
        "kind": "OAuthRedirectReference",
        "apiVersion": "v1",
        "reference": {
          "kind": "Route",
          "name": "<fullname>-ui"
        }
      }
```

This annotation:
- Tells OpenShift OAuth where to redirect after authentication
- References the Route resource by name
- Enables the OAuth callback URL pattern: `https://<route-host>/oauth/callback`

### TLS Certificate Auto-Generation

The Service CA Operator automatically generates TLS certificates via annotation:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <fullname>-ui
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: <fullname>-ui-tls
spec:
  ports:
    - port: 8443
      targetPort: https
      name: https
```

The operator:
- Watches for the `serving-cert-secret-name` annotation
- Generates a TLS certificate signed by the cluster CA
- Creates a Secret with `tls.crt` and `tls.key`
- Automatically rotates certificates before expiry

### Session Secret Persistence

The cookie secret is persisted across Helm upgrades using the `lookup` function:

```yaml
{{- $secret := (lookup "v1" "Secret" .Release.Namespace (printf "%s-ui-cookie-secret" (include "ros-ocp.fullname" .))) -}}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "ros-ocp.fullname" . }}-ui-cookie-secret
type: Opaque
data:
  session-secret: {{ if $secret }}{{ index $secret.data "session-secret" }}{{ else }}{{ randAlphaNum 32 | b64enc }}{{ end }}
```

This ensures:
- ✅ Users remain logged in across Helm upgrades
- ✅ Existing sessions are not invalidated
- ✅ New secret is only generated on initial install or manual deletion

### Nginx Configuration

Nginx runs inside the UI app container and serves two primary functions:
1. **Static File Serving**: Serves the React application's static files (HTML, CSS, JavaScript)
2. **API Proxy**: Proxies API requests to the ROS API backend with Bearer token authentication

#### Nginx Configuration

The Nginx configuration is embedded in the UI application container. Key configuration:

```nginx
# API proxy location - forwards to ROS API
location /api {
    proxy_pass ${API_PROXY_URL};
    
    # Extract access token from OAuth proxy header and add as Bearer token
    proxy_set_header Authorization "Bearer $http_x_forwarded_access_token";
    
    # Standard proxy headers
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    
    # HTTP/1.1 connection settings
    proxy_http_version 1.1;
    proxy_set_header Connection "";
}

# Static file serving - React application
location / {
    try_files $uri $uri/ /index.html;
}
```

#### Key Configuration Points

1. **API Proxy URL**: 
   - Set via `API_PROXY_URL` environment variable
   - Points to ROS API service: `http://<fullname>-ros-api:8000`
   - Configured in Helm values: `ui.app.env.API_PROXY_URL`

2. **Token Passing**:
   - OAuth proxy sets `X-Forwarded-Access-Token` header with the user's access token
   - Nginx extracts this header: `$http_x_forwarded_access_token`
   - Nginx adds it as `Authorization: Bearer <token>` header to ROS API requests
   - ROS API validates the Bearer token for authentication

3. **Static File Serving**:
   - All non-API requests (`/`) are served as static files
   - `try_files` directive enables client-side routing (React Router)
   - Falls back to `index.html` for all routes (SPA behavior)

#### Request Flow

**Static File Request:**
```
User → Route → OAuth Proxy → Nginx → Serve /index.html → Response
```

**API Request:**
```
User → Route → OAuth Proxy (adds X-Forwarded-Access-Token) 
  → Nginx (extracts token, adds Authorization header) 
  → ROS API (validates Bearer token) 
  → Response
```

#### Environment Variable

The `API_PROXY_URL` environment variable is set in the UI app container:

```yaml
env:
  - name: API_PROXY_URL
    value: "http://{{ include "cost-onprem.fullname" . }}-ros-api:{{ .Values.ros.api.port }}"
```

This ensures Nginx knows where to proxy API requests.

## Testing

### Prerequisites

1. Deployed on OpenShift cluster (UI is OpenShift-only)
2. OpenShift OAuth server is accessible
3. User has valid OpenShift credentials

### Access the UI

```bash
# Get the UI route URL
UI_ROUTE=$(oc get route -n ros-ocp -l app.kubernetes.io/component=ui -o jsonpath='{.items[0].spec.host}')

# Access in browser
echo "https://$UI_ROUTE"

# Or test with curl (will get redirect)
curl -v "https://$UI_ROUTE"

# Expected: 302 redirect to /oauth/authorize
```

### Verify Route Configuration

```bash
# Check route exists
oc get route -n ros-ocp -l app.kubernetes.io/component=ui

# Verify TLS reencrypt termination
oc get route -n ros-ocp -l app.kubernetes.io/component=ui -o jsonpath='{.items[0].spec.tls.termination}'
# Expected: reencrypt

# Check route target
oc describe route -n ros-ocp -l app.kubernetes.io/component=ui
```

### Verify TLS Certificate

```bash
# Check if TLS secret exists
oc get secret -n ros-ocp -l app.kubernetes.io/component=ui | grep tls

# View certificate details
oc get secret <fullname>-ui-tls -n ros-ocp -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Verify certificate is valid
oc get secret <fullname>-ui-tls -n ros-ocp -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

### Verify OAuth Proxy Health

```bash
# Check OAuth proxy health endpoint
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c oauth-proxy -- \
  curl -k https://localhost:8443/oauth/healthz

# Expected: "OK"

# Check OAuth proxy logs
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c oauth-proxy --tail=50

# Look for:
# - "Listening on :8443"
# - "HTTP: serving on :8443"
```

### Verify UI App Health

```bash
# Check UI app health
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  curl http://localhost:8080/

# Expected: HTML response

# Check UI app logs
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c app --tail=50
```

### Verify Nginx Configuration

```bash
# Check API_PROXY_URL environment variable
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  env | grep API_PROXY_URL

# Expected: API_PROXY_URL=http://<fullname>-ros-api:8000

# Test Nginx API proxy (requires authenticated session)
# First, get a valid session cookie, then:
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  curl -H "X-Forwarded-Access-Token: <test-token>" \
       http://localhost:8080/api/status

# Check Nginx logs (if available in container)
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c app --tail=50 | grep nginx

# Verify ROS API is accessible from UI pod
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  curl http://<fullname>-ros-api:8000/status
```

### Test Authentication Flow

```bash
# 1. Open browser in private/incognito mode
# 2. Navigate to https://<ui-route>
# 3. Should redirect to OpenShift login
# 4. Enter OpenShift credentials
# 5. Should redirect back to UI
# 6. UI should load successfully

# Test session persistence
# 7. Refresh page - should not require login
# 8. Close browser and reopen
# 9. Navigate to https://<ui-route>
# 10. Should still be logged in (if session not expired)
```

## Troubleshooting

### OAuth Redirect Loop

**Symptom**: Continuously redirected between UI and OpenShift OAuth

**Diagnosis**:
```bash
# Check ServiceAccount annotation
oc get serviceaccount -n ros-ocp -l app.kubernetes.io/component=ui -o yaml | grep oauth-redirectreference

# Verify route name matches annotation
oc get route -n ros-ocp -l app.kubernetes.io/component=ui -o jsonpath='{.items[0].metadata.name}'
```

**Solution**:
```bash
# Reinstall to fix annotation mismatch
helm upgrade ros-ocp ./ros-ocp -n ros-ocp --force
```

### TLS Certificate Not Generated

**Symptom**: Pod fails to start with "tls.crt: no such file"

**Diagnosis**:
```bash
# Check if Service CA Operator is running
oc get pods -n openshift-service-ca -l app=service-ca

# Check service annotation
oc get service -n ros-ocp -l app.kubernetes.io/component=ui -o yaml | grep serving-cert-secret-name

# Check if secret was created
oc get secret -n ros-ocp | grep ui-tls
```

**Solution**:
```bash
# Wait for certificate generation (usually < 30 seconds)
oc wait --for=condition=ready secret/<fullname>-ui-tls -n ros-ocp --timeout=60s

# If timeout, check Service CA logs
oc logs -n openshift-service-ca -l app=service-ca

# Restart pod to pick up certificate
oc rollout restart deployment -n ros-ocp -l app.kubernetes.io/component=ui
```

### Session Expired Too Quickly

**Symptom**: Users logged out frequently

**Diagnosis**:
```bash
# Check cookie secret age
oc get secret -n ros-ocp <fullname>-ui-cookie-secret -o jsonpath='{.metadata.creationTimestamp}'

# Check if secret changed recently
oc describe secret -n ros-ocp <fullname>-ui-cookie-secret
```

**Solution**:
```bash
# Cookie secret should persist across Helm upgrades
# If manually deleted, users will need to re-login

# Verify lookup function is working
helm get manifest ros-ocp -n ros-ocp | grep -A 5 "lookup.*Secret"
```

### 503 Service Unavailable

**Symptom**: Route returns 503 error

**Diagnosis**:
```bash
# Check pod status
oc get pods -n ros-ocp -l app.kubernetes.io/component=ui

# Check service endpoints
oc get endpoints -n ros-ocp -l app.kubernetes.io/component=ui

# Check route backend
oc describe route -n ros-ocp -l app.kubernetes.io/component=ui
```

**Solution**:
```bash
# Ensure pod is ready
oc wait --for=condition=ready pod -n ros-ocp -l app.kubernetes.io/component=ui --timeout=60s

# Check readiness probe
oc describe pod -n ros-ocp -l app.kubernetes.io/component=ui | grep -A 5 Readiness

# View probe logs
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c oauth-proxy | grep healthz
```

### OAuth Proxy Crashes

**Symptom**: OAuth proxy container constantly restarting

**Diagnosis**:
```bash
# Check pod events
oc describe pod -n ros-ocp -l app.kubernetes.io/component=ui

# Check oauth-proxy logs
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c oauth-proxy --previous

# Check resource limits
oc get pod -n ros-ocp -l app.kubernetes.io/component=ui -o jsonpath='{.spec.containers[?(@.name=="oauth-proxy")].resources}'
```

**Solution**:
```bash
# Increase memory if OOMKilled
helm upgrade ros-ocp ./ros-ocp -n ros-ocp \
  --set ui.oauth-proxy.resources.limits.memory=256Mi \
  --set ui.oauth-proxy.resources.requests.memory=128Mi
```

### App Container Not Responding

**Symptom**: OAuth works but app returns errors

**Diagnosis**:
```bash
# Check app logs
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c app

# Test app directly
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  curl http://localhost:8080/

# Check app port configuration
oc get deployment -n ros-ocp -l app.kubernetes.io/component=ui -o jsonpath='{.spec.template.spec.containers[?(@.name=="app")].ports[0].containerPort}'
```

**Solution**:
```bash
# Verify app port matches configuration
helm upgrade ros-ocp ./ros-ocp -n ros-ocp --set ui.app.port=8080

# Increase app resources if needed
helm upgrade ros-ocp ./ros-ocp -n ros-ocp \
  --set ui.app.resources.limits.memory=512Mi
```

### API Requests Failing (401/403)

**Symptom**: UI loads but API requests return authentication errors

**Diagnosis**:
```bash
# Check if API_PROXY_URL is set correctly
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  env | grep API_PROXY_URL

# Verify ROS API service is accessible
oc get svc -n ros-ocp -l app.kubernetes.io/component=ros-api

# Test ROS API directly
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  curl http://<fullname>-ros-api:8000/status

# Check if OAuth proxy is setting X-Forwarded-Access-Token header
oc logs -n ros-ocp -l app.kubernetes.io/component=ui -c oauth-proxy | grep -i "forwarded-access-token"
```

**Solution**:
```bash
# Verify API_PROXY_URL environment variable
# Should be: http://<fullname>-ros-api:8000
oc get deployment -n ros-ocp -l app.kubernetes.io/component=ui -o yaml | \
  grep -A 2 API_PROXY_URL

# Ensure OAuth proxy is configured with --pass-access-token flag
# This flag enables X-Forwarded-Access-Token header
oc get deployment -n ros-ocp -l app.kubernetes.io/component=ui -o yaml | \
  grep -i "pass-access-token"

# If missing, update Helm values to include:
# ui.oauthProxy.args: ["--pass-access-token"]
helm upgrade ros-ocp ./ros-ocp -n ros-ocp \
  --set ui.oauthProxy.passAccessToken=true
```

### Nginx Proxy Errors

**Symptom**: API requests fail with proxy errors or connection refused

**Diagnosis**:
```bash
# Check Nginx configuration (if accessible)
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  cat /etc/nginx/nginx.conf 2>/dev/null || echo "Nginx config not accessible"

# Test ROS API connectivity from UI pod
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  curl -v http://<fullname>-ros-api:8000/status

# Check DNS resolution
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  nslookup <fullname>-ros-api || getent hosts <fullname>-ros-api
```

**Solution**:
```bash
# Verify ROS API service name matches API_PROXY_URL
# Service name format: <fullname>-ros-api
# API_PROXY_URL should be: http://<fullname>-ros-api:8000

# Check service exists and is accessible
oc get svc -n ros-ocp <fullname>-ros-api

# Verify ROS API pod is running
oc get pods -n ros-ocp -l app.kubernetes.io/component=ros-api

# Test network connectivity
oc exec -n ros-ocp -l app.kubernetes.io/component=ui -c app -- \
  nc -zv <fullname>-ros-api 8000
```

## Security Considerations

1. **TLS Encryption**
   - Route uses TLS reencrypt termination
   - Traffic is encrypted from user browser to route (TLS)
   - Traffic is re-encrypted from route to OAuth proxy (TLS)
   - Traffic from OAuth proxy to app is unencrypted (localhost only)

2. **Session Management**
   - Sessions stored in encrypted cookies (`_oauth_proxy`)
   - Cookie secret is 32 random alphanumeric characters
   - Secret persists across Helm upgrades to maintain sessions
   - Sessions have TTL and expire after inactivity

3. **Authentication**
   - Uses OpenShift's native OAuth server
   - No external identity provider required
   - User credentials never touch the OAuth proxy
   - OAuth proxy only receives validated tokens from OAuth server

4. **Network Isolation**
   - UI app only accessible via OAuth proxy (no direct external access)
   - OAuth proxy and Nginx communicate over pod-local `localhost`
   - Nginx proxies API requests to ROS API within the cluster
   - Only OpenShift Route can access OAuth proxy externally
   - API requests are authenticated with Bearer tokens passed from OAuth proxy

5. **ServiceAccount Permissions**
   - ServiceAccount has no special RBAC permissions
   - OAuth redirect enabled via annotation only
   - No cluster-wide permissions needed

6. **Automatic Certificate Rotation**
   - TLS certificates auto-renewed by Service CA Operator
   - No manual certificate management required
   - Certificates signed by cluster CA

7. **Health Check Bypass**
   - `/oauth/healthz` endpoint does not require authentication
   - Required for Kubernetes liveness/readiness probes
   - Only accessible from within the cluster

## Platform Requirements

**OpenShift Only**: This UI authentication method is exclusively for OpenShift clusters because it depends on:

- ✅ OpenShift OAuth Server (`authentication.k8s.io`)
- ✅ OpenShift Routes with TLS reencrypt
- ✅ Service CA Operator for automatic certificate generation
- ✅ ServiceAccount OAuth redirect annotations

**Automatic Detection**: The UI is only deployed when the chart detects an OpenShift cluster:

```yaml
{{- if eq (include "ros-ocp.isOpenShift" .) "true" }}
# UI resources deployed here
{{- end }}
```

**Kubernetes/KIND**: For non-OpenShift platforms, alternative authentication methods would be required (e.g., OAuth2 Proxy with external provider).

## References

- [OpenShift OAuth Proxy](https://github.com/openshift/oauth-proxy)
- [OpenShift OAuth Server](https://docs.openshift.com/container-platform/latest/authentication/understanding-authentication.html)
- [Service CA Operator](https://docs.openshift.com/container-platform/latest/security/certificates/service-serving-certificate.html)
- [OpenShift Routes](https://docs.openshift.com/container-platform/latest/networking/routes/route-configuration.html)
- [OAuth Redirect Reference](https://docs.openshift.com/container-platform/latest/authentication/using-service-accounts-as-oauth-client.html)

## Related Documentation

- [Configuration Guide](configuration.md) - Complete UI configuration reference with authentication flow diagrams
- [Troubleshooting Guide](troubleshooting.md) - UI-specific troubleshooting procedures
- [Platform Guide](platform-guide.md) - Platform-specific requirements and differences

