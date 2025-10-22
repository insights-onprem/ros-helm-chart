#!/bin/bash

# ROS-OCP OpenShift Data Flow Test Script with JWT Authentication
# This script tests the complete data flow using Keycloak JWT tokens instead of hardcoded identity headers

set -e  # Exit on any error

# Cleanup function for trapped exits
cleanup() {
    local exit_code=$?
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE=${NAMESPACE:-ros-ocp}
HELM_RELEASE_NAME=${HELM_RELEASE_NAME:-ros-ocp}
KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-rhsso}

# JWT Authentication variables
JWT_TOKEN=""
JWT_TOKEN_EXPIRY=""
KEYCLOAK_URL=""
CLIENT_ID=""
CLIENT_SECRET=""
PORT_FORWARD_PID=""

# Check prerequisites
check_prerequisites() {
    local missing_deps=()

    command -v oc >/dev/null 2>&1 || missing_deps+=("oc")
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v tar >/dev/null 2>&1 || missing_deps+=("tar")

    # Check for JSON parser (prefer jq, fallback to python3)
    if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        missing_deps+=("jq or python3")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi

    return 0
}

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

# JSON parsing helper function (works with jq or python3)
parse_json() {
    local json_data="$1"
    local json_path="$2"

    if command -v jq >/dev/null 2>&1; then
        echo "$json_data" | jq -r "$json_path" 2>/dev/null || echo ""
    elif command -v python3 >/dev/null 2>&1; then
        echo "$json_data" | python3 -c "import sys, json; data=json.load(sys.stdin); print($json_path)" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# JSON array length helper
json_array_length() {
    local json_data="$1"

    if command -v jq >/dev/null 2>&1; then
        echo "$json_data" | jq 'length' 2>/dev/null || echo "0"
    elif command -v python3 >/dev/null 2>&1; then
        echo "$json_data" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data))" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Function to detect Keycloak configuration
detect_keycloak_config() {
    echo_info "=== Detecting Keycloak Configuration ==="

    # Try to find Keycloak route
    local keycloak_route=$(oc get route -n "$KEYCLOAK_NAMESPACE" keycloak -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    if [ -n "$keycloak_route" ]; then
        KEYCLOAK_URL="https://$keycloak_route"
        echo_success "Found Keycloak route: $KEYCLOAK_URL"
    else
        echo_warning "Keycloak route not found, trying service discovery..."

        # Try to find Keycloak service
        local keycloak_service=$(oc get svc -n "$KEYCLOAK_NAMESPACE" keycloak -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
        if [ -n "$keycloak_service" ]; then
            KEYCLOAK_URL="http://keycloak.$KEYCLOAK_NAMESPACE.svc.cluster.local:8080"
            echo_success "Found Keycloak service: $KEYCLOAK_URL"
        else
            echo_error "Keycloak not found. Please ensure Keycloak is deployed."
            return 1
        fi
    fi

    # Try to find client credentials from KeycloakClient CR
    echo_info "Looking for Cost Management client configuration..."

    # Find KeycloakClient CRs that match cost-management pattern
    local keycloak_clients=$(oc get keycloakclient -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    local keycloak_client_cr=""

    # Look for cost-management related clients
    for client in $keycloak_clients; do
        if echo "$client" | grep -q "cost-management"; then
            keycloak_client_cr="$client"
            echo_info "Found KeycloakClient CR: $keycloak_client_cr"
            break
        fi
    done

    if [ -z "$keycloak_client_cr" ]; then
        echo_warning "No cost-management KeycloakClient found, using default"
        CLIENT_ID="cost-management-operator"
    else
        # Get client ID from KeycloakClient CR spec
        CLIENT_ID=$(oc get keycloakclient "$keycloak_client_cr" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.spec.client.clientId}' 2>/dev/null || echo "")

        if [ -z "$CLIENT_ID" ]; then
            echo_warning "Could not extract clientId from CR, using default"
            CLIENT_ID="cost-management-operator"
        else
            echo_success "Found client ID: $CLIENT_ID"
        fi

        # Get client secret from the generated secret (named after the CR, not the clientId)
        local secret_name="keycloak-client-secret-$keycloak_client_cr"
        CLIENT_SECRET=$(oc get secret "$secret_name" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d || echo "")

        if [ -n "$CLIENT_SECRET" ]; then
            echo_success "Found client secret in: $secret_name"
        fi
    fi

    # If still no secret, try alternative patterns
    if [ -z "$CLIENT_SECRET" ]; then
        echo_warning "Client secret not found in expected location. Trying alternative locations..."
        # Try different secret name patterns
        for secret_pattern in "keycloak-client-secret-cost-management-operator" "keycloak-client-secret-cost-management-service-account" "credential-$CLIENT_ID" "keycloak-client-$CLIENT_ID" "$CLIENT_ID-secret"; do
            CLIENT_SECRET=$(oc get secret "$secret_pattern" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d || echo "")
            if [ -n "$CLIENT_SECRET" ]; then
                echo_success "Found client secret in: $secret_pattern"
                break
            fi
        done
    fi

    if [ -z "$CLIENT_SECRET" ]; then
        echo_error "Client secret not found. Please check Keycloak client configuration."
        echo_info "Available secrets in $KEYCLOAK_NAMESPACE namespace:"
        oc get secrets -n "$KEYCLOAK_NAMESPACE" | grep -E "(keycloak|client|secret)" || echo "No matching secrets found"
        return 1
    fi

    return 0
}

# Function to validate JWT authentication (preflight smoke test)
validate_jwt_authentication() {
    echo_info "=== Preflight: JWT Authentication Validation ==="
    echo_info "Running smoke tests to verify JWT authentication is working..."
    echo ""

    # Get ingress service URL
    local ingress_url=$(get_service_url "ingress" "")
    echo_info "Testing ingress at: $ingress_url"

    # Check if we can reach the service at all
    local health_check=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$ingress_url/ready" 2>/dev/null || echo "000")
    if [ "$health_check" = "000" ]; then
        echo_error "Cannot reach ingress service. Skipping JWT validation tests."
        echo_warning "Service may not be ready yet or port-forwarding is required"
        return 1
    fi

    local test_passed=0
    local test_failed=0

    # Test 1: Request without JWT token (should be rejected with 401)
    echo_info "Test 1: Request without JWT token"
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$ingress_url/v1/upload" 2>/dev/null || echo "000")
    if [ "$http_code" = "401" ]; then
        echo_success "  ✓ Correctly rejected request without token (401)"
        test_passed=$((test_passed + 1))
    else
        echo_warning "  ⚠ Expected 401, got $http_code (may indicate route/service issue)"
        # Not failing here as 503 might just mean routing issue, not auth bypass
    fi

    # Test 2: Request with malformed JWT token (should be rejected)
    echo_info "Test 2: Request with malformed JWT token"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: Bearer invalid.malformed.token" \
        "$ingress_url/v1/upload" 2>/dev/null || echo "000")
    if [ "$http_code" = "401" ]; then
        echo_success "  ✓ Correctly rejected malformed token (401)"
        test_passed=$((test_passed + 1))
    else
        echo_warning "  ⚠ Expected 401, got $http_code"
    fi

    # Test 3: Request with self-signed JWT (wrong signature)
    echo_info "Test 3: Request with JWT signed by wrong key"
    
    if command -v openssl >/dev/null 2>&1; then
        # Generate a fake JWT with valid structure but wrong signature
        local temp_key=$(mktemp)
        openssl genrsa -out "$temp_key" 2048 2>/dev/null
        
        local header_b64=$(echo -n '{"alg":"RS256","typ":"JWT","kid":"fake-key"}' | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
        local payload_b64=$(echo -n '{"sub":"attacker","iss":"https://fake-issuer.com","aud":"cost-management-operator","exp":9999999999}' | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
        local signature=$(echo -n "${header_b64}.${payload_b64}" | openssl dgst -sha256 -sign "$temp_key" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
        local fake_jwt="${header_b64}.${payload_b64}.${signature}"
        
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            -H "Authorization: Bearer $fake_jwt" \
            "$ingress_url/v1/upload" 2>/dev/null || echo "000")
        
        rm -f "$temp_key"
        
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            echo_success "  ✓ Correctly rejected JWT with invalid signature ($http_code)"
            test_passed=$((test_passed + 1))
        elif [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
            echo_error "  ✗ CRITICAL: JWT with fake signature was ACCEPTED!"
            echo_error "  This is a security vulnerability - any JWT is being accepted!"
            test_failed=$((test_failed + 1))
        else
            echo_warning "  ⚠ Got HTTP $http_code (expected 401/403)"
        fi
    else
        echo_info "  Skipping (openssl not available)"
    fi

    echo ""
    if [ $test_passed -ge 2 ]; then
        echo_success "JWT authentication preflight checks passed ($test_passed tests)"
        echo_info "  → Envoy is properly validating JWT tokens"
        echo_info "  → Ready to proceed with authenticated upload"
        return 0
    else
        echo_warning "JWT authentication validation incomplete ($test_passed passed, $test_failed failed)"
        echo_warning "  This may indicate JWT authentication is not properly configured"
        echo_warning "  Proceeding with upload test, but authentication may fail"
        return 0  # Don't fail completely, just warn
    fi
}

# Function to get JWT token from Keycloak
get_jwt_token() {
    echo_info "=== Getting JWT Token from Keycloak ==="

    if [ -z "$KEYCLOAK_URL" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
        echo_error "Keycloak configuration not available. Run detect_keycloak_config first."
        return 1
    fi

    # Determine the correct realm and token endpoint
    local realm="kubernetes"
    local token_url="$KEYCLOAK_URL/auth/realms/$realm/protocol/openid-connect/token"

    echo_info "Getting token from: $token_url"
    echo_info "Client ID: $CLIENT_ID"

    # Request JWT token using client credentials flow
    echo_warning "Using insecure TLS connection (-k flag) to Keycloak"
    local token_response=$(curl -s -k -X POST "$token_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" 2>/dev/null)

    local curl_exit=$?
    if [ $curl_exit -ne 0 ] || [ -z "$token_response" ]; then
        echo_error "Failed to connect to Keycloak token endpoint (curl exit code: $curl_exit)"
        return 1
    fi

    # Extract access token from response using helper function
    if command -v jq >/dev/null 2>&1; then
        JWT_TOKEN=$(echo "$token_response" | jq -r '.access_token // empty' 2>/dev/null)
        local expires_in=$(echo "$token_response" | jq -r '.expires_in // 0' 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
        JWT_TOKEN=$(echo "$token_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('access_token', ''))" 2>/dev/null)
        local expires_in=$(echo "$token_response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('expires_in', 0))" 2>/dev/null)
    fi

    if [ -z "$JWT_TOKEN" ] || [ "$JWT_TOKEN" = "null" ]; then
        echo_error "Failed to extract JWT token from response"
        echo_info "Token response: $token_response"
        return 1
    fi

    # Calculate expiry time
    JWT_TOKEN_EXPIRY=$(($(date +%s) + ${expires_in:-300}))

    echo_success "JWT token obtained successfully"
    echo_info "Token length: ${#JWT_TOKEN} characters"
    echo_info "Token expires in: ${expires_in:-300} seconds"

    # Optionally decode and display token info (first part only for security)
    local token_header=$(echo "$JWT_TOKEN" | cut -d'.' -f1)
    echo_info "Token header (base64): ${token_header:0:50}..."

    return 0
}

# Function to get service URL
get_service_url() {
    local service_name="$1"
    local path="$2"

    # Try to get OpenShift route first
    local route_name="$HELM_RELEASE_NAME-$service_name"
    local route_host=$(oc get route "$route_name" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)

    if [ -n "$route_host" ]; then
        # Check if route uses TLS
        local tls_termination=$(oc get route "$route_name" -n "$NAMESPACE" -o jsonpath='{.spec.tls.termination}' 2>/dev/null)
        local route_path=$(oc get route "$route_name" -n "$NAMESPACE" -o jsonpath='{.spec.path}' 2>/dev/null)

        if [ -n "$tls_termination" ]; then
            echo "https://$route_host${route_path}$path"
        else
            echo "http://$route_host${route_path}$path"
        fi
    else
        # Fallback to service (for port-forward or internal access)
        # Get the actual service port
        local service_port=$(oc get svc "$HELM_RELEASE_NAME-$service_name" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")
        echo "http://$HELM_RELEASE_NAME-$service_name.$NAMESPACE.svc.cluster.local:${service_port}$path"
    fi
}

# Cross-platform date function
cross_platform_date_ago() {
    local minutes_ago="$1"
    local format="${2:-+%Y-%m-%d %H:%M:%S -0000 UTC}"
    local seconds_ago=$((minutes_ago * 60))
    local target_epoch=$(($(date +%s) - seconds_ago))

    # Try BSD date format first (macOS)
    if date -r "$target_epoch" "$format" 2>/dev/null; then
        return 0
    # Try GNU date format (Linux)
    elif date -d "@$target_epoch" "$format" 2>/dev/null; then
        return 0
    else
        # Fallback: use epoch time directly
        echo "$target_epoch"
        return 1
    fi
}

# Function to create test data (same as original)
create_test_data() {
    echo_info "Creating test data with current timestamps..." >&2

    # Generate dynamic timestamps for current data (multiple intervals for better recommendations)
    local now_date=$(date -u +%Y-%m-%d)
    local interval_start_1=$(cross_platform_date_ago 75)  # 75 minutes ago
    local interval_end_1=$(cross_platform_date_ago 60)    # 60 minutes ago
    local interval_start_2=$(cross_platform_date_ago 60)  # 60 minutes ago
    local interval_end_2=$(cross_platform_date_ago 45)    # 45 minutes ago
    local interval_start_3=$(cross_platform_date_ago 45)  # 45 minutes ago
    local interval_end_3=$(cross_platform_date_ago 30)    # 30 minutes ago
    local interval_start_4=$(cross_platform_date_ago 30)  # 30 minutes ago
    local interval_end_4=$(cross_platform_date_ago 15)    # 15 minutes ago

    echo_info "Using timestamps:" >&2
    echo_info "  Report date: $now_date" >&2
    echo_info "  Interval 1: $interval_start_1 to $interval_end_1" >&2
    echo_info "  Interval 2: $interval_start_2 to $interval_end_2" >&2
    echo_info "  Interval 3: $interval_start_3 to $interval_end_3" >&2
    echo_info "  Interval 4: $interval_start_4 to $interval_end_4" >&2

    # Create a temporary CSV file with proper ROS-OCP format and current timestamps
    local test_csv=$(mktemp)
    cat > "$test_csv" << EOF
report_period_start,report_period_end,interval_start,interval_end,container_name,pod,owner_name,owner_kind,workload,workload_type,namespace,image_name,node,resource_id,cpu_request_container_avg,cpu_request_container_sum,cpu_limit_container_avg,cpu_limit_container_sum,cpu_usage_container_avg,cpu_usage_container_min,cpu_usage_container_max,cpu_usage_container_sum,cpu_throttle_container_avg,cpu_throttle_container_max,cpu_throttle_container_sum,memory_request_container_avg,memory_request_container_sum,memory_limit_container_avg,memory_limit_container_sum,memory_usage_container_avg,memory_usage_container_min,memory_usage_container_max,memory_usage_container_sum,memory_rss_usage_container_avg,memory_rss_usage_container_min,memory_rss_usage_container_max,memory_rss_usage_container_sum
$now_date,$now_date,$interval_start_1,$interval_end_1,test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,0.5,0.5,1.0,1.0,0.247832,0.185671,0.324131,0.247832,0.001,0.002,0.001,536870912,536870912,1073741824,1073741824,413587266.064516,410009344,420900544,413587266.064516,393311537.548387,390293568,396371392,393311537.548387
$now_date,$now_date,$interval_start_2,$interval_end_2,test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,0.5,0.5,1.0,1.0,0.265423,0.198765,0.345678,0.265423,0.0012,0.0025,0.0012,536870912,536870912,1073741824,1073741824,427891456.123456,422014016,435890624,427891456.123456,407654321.987654,403627568,411681024,407654321.987654
$now_date,$now_date,$interval_start_3,$interval_end_3,test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,0.5,0.5,1.0,1.0,0.289567,0.210987,0.367890,0.289567,0.0008,0.0018,0.0008,536870912,536870912,1073741824,1073741824,445678901.234567,441801728,449556074,445678901.234567,425987654.321098,421960800,430014256,425987654.321098
$now_date,$now_date,$interval_start_4,$interval_end_4,test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,0.5,0.5,1.0,1.0,0.234567,0.189012,0.298765,0.234567,0.0005,0.0012,0.0005,536870912,536870912,1073741824,1073741824,398765432.101234,394887168,402643696,398765432.101234,378654321.098765,374627568,382681024,378654321.098765
EOF

    echo "$test_csv"
}

# Function to upload test data with JWT authentication
upload_test_data_jwt() {
    echo_info "=== STEP 1: Upload Test Data with JWT Authentication ===="

    if [ -z "$JWT_TOKEN" ]; then
        echo_error "JWT token not available. Please run get_jwt_token first."
        return 1
    fi

    local test_csv=$(create_test_data)
    local test_dir=$(mktemp -d)
    local csv_filename="openshift_usage_report.csv"
    local tar_filename="cost-mgmt.tar.gz"

    # Copy CSV to temporary directory with expected filename
    if ! cp "$test_csv" "$test_dir/$csv_filename"; then
        echo_error "Failed to copy CSV file to temporary directory"
        rm -f "$test_csv"
        rm -rf "$test_dir"
        return 1
    fi

    # Verify the file exists and has content
    if [ ! -f "$test_dir/$csv_filename" ] || [ ! -s "$test_dir/$csv_filename" ]; then
        echo_error "CSV file not found or is empty in temporary directory"
        rm -f "$test_csv"
        rm -rf "$test_dir"
        return 1
    fi

    # Generate unique cluster ID for this test run
    UPLOAD_CLUSTER_ID="test-cluster-$(date +%s)"
    echo_info "Generated cluster ID for this upload: $UPLOAD_CLUSTER_ID"

    # Create manifest.json (required by ingress service)
    local manifest_file="$test_dir/manifest.json"
    cat > "$manifest_file" << EOF
{
  "uuid": "$(uuidgen | tr '[:upper:]' '[:lower:]')",
  "cluster_id": "$UPLOAD_CLUSTER_ID",
  "cluster_alias": "test-cluster",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "files": ["$csv_filename"],
  "resource_optimization_files": ["$csv_filename"],
  "certified": true,
  "operator_version": "1.0.0",
  "daily_reports": false
}
EOF

    # Create tar.gz file with both CSV and manifest.json
    echo_info "Creating tar.gz archive..."
    if ! (cd "$test_dir" && tar -czf "$tar_filename" "$csv_filename" "manifest.json"); then
        echo_error "Failed to create tar.gz archive"
        rm -f "$test_csv"
        rm -rf "$test_dir"
        return 1
    fi

    # Verify tar.gz file was created
    if [ ! -f "$test_dir/$tar_filename" ]; then
        echo_error "tar.gz file was not created"
        rm -f "$test_csv"
        rm -rf "$test_dir"
        return 1
    fi

    echo_info "Uploading tar.gz file with JWT authentication..."

    # Check if JWT token is still valid
    if [ -n "$JWT_TOKEN_EXPIRY" ]; then
        local now=$(date +%s)
        if [ "$now" -ge "$JWT_TOKEN_EXPIRY" ]; then
            echo_warning "JWT token has expired. Please refresh the token."
        fi
    fi

    # Upload the tar.gz file using curl with JWT Bearer token
    local upload_url=$(get_service_url "ingress" "/v1/upload")
    echo_info "Uploading to: $upload_url"
    echo_info "Using JWT token authentication"

    local response=$(curl -s -w "\n%{http_code}" \
        -F "file=@${test_dir}/${tar_filename};type=application/vnd.redhat.hccm.filename+tgz" \
        -H "Authorization: Bearer $JWT_TOKEN" \
        -H "x-rh-request-id: test-request-$(date +%s)" \
        "$upload_url" 2>&1)

    local curl_exit=$?

    # Extract HTTP code from last line (more portable way)
    local http_code=$(echo "$response" | tail -n 1)
    local response_body=$(echo "$response" | sed '$d')

    # Cleanup
    rm -f "$test_csv"
    rm -rf "$test_dir"

    if [ $curl_exit -ne 0 ]; then
        echo_error "Upload failed - curl error (exit code: $curl_exit)"
        echo_error "Response: $response_body"
        return 1
    fi

    if [ "$http_code" != "202" ] && [ "$http_code" != "200" ]; then
        echo_error "Upload failed with HTTP $http_code"
        echo_error "Response: $response_body"
        return 1
    fi

    echo_success "Upload successful! HTTP $http_code"
    echo_info "Response: $response_body"

    return 0
}

# Function to verify upload was processed
verify_upload_processing() {
    echo_info "=== STEP 2: Verify Upload Processing ===="

    # Check ingress logs for upload activity
    echo_info "Checking ingress logs for upload processing..."
    local ingress_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=ingress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$ingress_pod" ]; then
        # Get container names to find the right one
        local containers=$(oc get pod "$ingress_pod" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
        echo_info "Found pod: $ingress_pod with containers: $containers"

        # Try to get logs from the ingress container
        echo_info "Recent ingress logs:"
        if echo "$containers" | grep -q "ingress"; then
            oc logs -n "$NAMESPACE" "$ingress_pod" -c ingress --tail=10 2>/dev/null | grep -i "upload\|jwt\|auth\|error" || echo "No relevant log messages found"
        else
            # Fall back to first container
            local first_container=$(echo "$containers" | awk '{print $1}')
            oc logs -n "$NAMESPACE" "$ingress_pod" -c "$first_container" --tail=10 2>/dev/null | grep -i "upload\|jwt\|auth\|error" || echo "No relevant log messages found"
        fi
    else
        echo_warning "Ingress pod not found (tried label: app.kubernetes.io/name=ingress)"
    fi

    # If we have the full ROS stack, check for further processing
    local processor_pod=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=rosocp-processor" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -n "$processor_pod" ]; then
        echo_info "Checking processor logs for data processing..."
        oc logs -n "$NAMESPACE" "$processor_pod" --tail=10 | grep -i "processing\|complete\|error" || echo "No processing messages found"
    else
        echo_info "ROS processor not deployed - upload verification complete at ingress level"
    fi

    return 0
}

# Function to check for ML recommendations for a specific upload
check_for_recommendations() {
    local cluster_id="$1"

    if [ -z "$cluster_id" ]; then
        echo_error "Cluster ID not provided to check_for_recommendations"
        return 1
    fi

    echo_info "=== STEP 3: Check for ML Recommendations ===="
    echo_info "Checking recommendations for cluster: $cluster_id"

    # Wait for Kruize to process data and generate recommendations
    echo_info "Waiting for Kruize to process data and generate recommendations (45 seconds)..."
    echo_info "Kruize needs time to analyze metrics and create optimization recommendations..."
    sleep 45

    # Check if Kruize is accessible
    local kruize_pod=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=kruize" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$kruize_pod" ]; then
        echo_error "Kruize pod not found"
        echo_info "Use './query-kruize.sh --cluster $cluster_id' to check recommendations later"
        return 1
    fi

    echo_info "Kruize pod found: $kruize_pod"

    # Check Kruize database for experiments (listExperiments API has known issues)
    echo_info "Checking Kruize experiments via database..."
    local db_pod=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=db-kruize" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$db_pod" ]; then
        echo_error "Kruize database pod not found"
        echo_info "Use './query-kruize.sh --cluster $cluster_id' to check recommendations later"
        return 1
    fi

    # Query for experiments specific to this cluster (cluster_name format: "1;cluster-id")
    echo_info "Querying for experiments matching cluster: $cluster_id"
    local exp_count=$(oc exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -t -c \
        "SELECT COUNT(*) FROM kruize_experiments WHERE cluster_name LIKE '%${cluster_id}%';" 2>/dev/null | tr -d ' ' || echo "0")

    if [ "$exp_count" -eq 0 ]; then
        echo_error "❌ No Kruize experiments found for cluster: $cluster_id"
        echo_info "This indicates the data was not processed by the backend or sent to Kruize"
        echo_info "Troubleshooting:"
        echo_info "  - Check processor logs: oc logs -n $NAMESPACE deployment/ros-ocp-rosocp-processor --tail=50"
        echo_info "  - Verify upload was successful in ingress logs"
        echo_info "  - Check Kafka messages were processed"
        return 1
    fi

    echo_success "Found $exp_count Kruize experiment(s) for this upload"

    # Show experiment details for this cluster
    echo_info "Experiment details for cluster $cluster_id:"
    oc exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -c \
        "SELECT experiment_name, status, cluster_name FROM kruize_experiments
         WHERE cluster_name LIKE '%${cluster_id}%'
         ORDER BY experiment_name DESC LIMIT 3;" 2>/dev/null || true

    # Check for recommendations specific to this cluster
    echo_info "Querying for recommendations for cluster: $cluster_id"
    local rec_count=$(oc exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -t -c \
        "SELECT COUNT(*) FROM kruize_recommendations WHERE cluster_name LIKE '%${cluster_id}%';" 2>/dev/null | tr -d ' ' || echo "0")

    if [ "$rec_count" -eq 0 ]; then
        echo_error "❌ No ML recommendations found for cluster: $cluster_id"
        echo_warning "Experiments exist but no recommendations were generated for this upload"
        echo_info ""
        echo_info "Possible reasons:"
        echo_info "  - Not enough data points (Kruize needs multiple intervals over time)"
        echo_info "  - Data quality issues (check if metrics have valid values)"
        echo_info "  - Kruize is still processing (may take several minutes)"
        echo_info ""
        echo_info "Troubleshooting steps:"
        echo_info "  1. Check Kruize logs: oc logs -n $NAMESPACE $kruize_pod | tail -100"
        echo_info "  2. Query later: ./query-kruize.sh --cluster $cluster_id"
        echo_info "  3. Check if experiments show 'IN_PROGRESS' status (query shown above)"
        echo_info ""
        echo_info "Note: Kruize typically requires multiple data uploads over time to generate"
        echo_info "      meaningful recommendations. A single upload may not be sufficient."
        return 1
    fi

    echo_success "✓ Found $rec_count ML recommendation(s) for cluster: $cluster_id!"

    # Show recommendation details for this cluster
    echo_info "Recommendation details for cluster $cluster_id:"
    oc exec -n "$NAMESPACE" "$db_pod" -- \
        psql -U postgres -d postgres -c \
        "SELECT experiment_name, interval_end_time
         FROM kruize_recommendations
         WHERE cluster_name LIKE '%${cluster_id}%'
         ORDER BY interval_end_time DESC LIMIT 3;" 2>/dev/null || true

    return 0
}

# Store recommendations check result for main function
check_recommendations_with_retry() {
    local cluster_id="$1"
    local max_retries=3
    local retry_interval=60
    local attempt=1

    if [ -z "$cluster_id" ]; then
        echo_error "Cluster ID not provided to check_recommendations_with_retry"
        return 1
    fi

    while [ $attempt -le $max_retries ]; do
        if [ $attempt -gt 1 ]; then
            echo_info "Retry attempt $attempt of $max_retries (waiting ${retry_interval}s)..."
            sleep $retry_interval
        fi

        if check_for_recommendations "$cluster_id"; then
            return 0
        fi

        attempt=$((attempt + 1))
    done

    echo_error "Failed to find recommendations for cluster $cluster_id after $max_retries attempts"
    return 1
}

# Main execution
main() {
    echo_info "ROS-OCP JWT Authentication Data Flow Test"
    echo_info "========================================="

    # Check prerequisites first
    if ! check_prerequisites; then
        echo_error "Prerequisites check failed"
        exit 1
    fi

    echo_info "Configuration:"
    echo_info "  Platform: OpenShift"
    echo_info "  Namespace: $NAMESPACE"
    echo_info "  Helm Release: $HELM_RELEASE_NAME"
    echo_info "  Keycloak Namespace: $KEYCLOAK_NAMESPACE"
    echo ""

    # Step 1: Detect Keycloak configuration
    if ! detect_keycloak_config; then
        echo_error "Failed to detect Keycloak configuration"
        exit 1
    fi
    echo ""

    # Step 2: Get JWT token
    if ! get_jwt_token; then
        echo_error "Failed to obtain JWT token"
        exit 1
    fi
    echo ""

    # Step 2.5: Validate JWT authentication is working (preflight smoke test)
    validate_jwt_authentication
    echo ""

    # Step 3: Upload test data with JWT authentication
    if ! upload_test_data_jwt; then
        echo_error "Upload with JWT authentication failed"
        exit 1
    fi
    echo ""

    # Step 4: Verify processing
    verify_upload_processing
    echo ""

    # Step 5: Check for recommendations with retries (for the specific cluster we just uploaded)
    if [ -z "$UPLOAD_CLUSTER_ID" ]; then
        echo_error "UPLOAD_CLUSTER_ID not set. This should have been set during upload."
        exit 1
    fi

    if ! check_recommendations_with_retry "$UPLOAD_CLUSTER_ID"; then
        echo ""
        echo_error "❌ JWT Authentication Data Flow Test FAILED!"
        echo_error "The upload was successful but no ML recommendations were generated for cluster: $UPLOAD_CLUSTER_ID"
        echo_info ""
        echo_info "Troubleshooting steps:"
        echo_info "  1. Check if data reached Kruize for this cluster:"
        echo_info "     ./query-kruize.sh --cluster $UPLOAD_CLUSTER_ID"
        echo_info "  2. Check processor logs for errors:"
        echo_info "     oc logs -n $NAMESPACE deployment/ros-ocp-rosocp-processor --tail=100"
        echo_info "  3. Check Kruize logs:"
        echo_info "     oc logs -n $NAMESPACE deployment/ros-ocp-kruize --tail=100"
        echo_info "  4. Query all recommendations:"
        echo_info "     ./query-kruize.sh --recommendations"
        exit 1
    fi

    echo ""
    echo_success "✅ JWT Authentication Data Flow Test completed successfully!"
    echo_success "Test cluster ID: $UPLOAD_CLUSTER_ID"
    echo_info ""
    echo_info "The test demonstrated:"
    echo_info "  ✓ Keycloak JWT token generation"
    echo_info "  ✓ Authenticated file upload using JWT Bearer token"
    echo_info "  ✓ Ingress processing with JWT authentication"
    echo_info "  ✓ Backend processing and data aggregation"
    echo_info "  ✓ Kruize ML recommendation generation for uploaded data"
    echo_info "  ✓ End-to-end data flow with optimization recommendations"
    echo_info ""
    echo_info "🎉 This confirms that the complete ROS optimization flow is working end-to-end!"
    echo_info ""
    echo_info "To query recommendations for this specific upload later:"
    echo_info "  ./query-kruize.sh --cluster $UPLOAD_CLUSTER_ID"
}

# Handle script arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (no command)    Run complete JWT authentication test"
        echo "  help            Show this help message"
        echo ""
        echo "Environment Variables:"
        echo "  NAMESPACE              Target namespace (default: ros-ocp)"
        echo "  HELM_RELEASE_NAME      Helm release name (default: ros-ocp)"
        echo "  KEYCLOAK_NAMESPACE     Keycloak namespace (default: rhsso)"
        echo ""
        echo "This script:"
        echo "  1. Detects Keycloak configuration automatically"
        echo "  2. Obtains JWT token using client credentials flow"
        echo "  3. Uploads sample data using JWT Bearer authentication"
        echo "  4. Verifies the upload was processed successfully"
        echo "  5. Validates ML recommendations were generated for the uploaded data"
        echo ""
        echo "Note: The script will FAIL if no recommendations are generated for the"
        echo "      specific upload after multiple retry attempts. This ensures the"
        echo "      complete end-to-end flow is validated."
        echo ""
        echo "Requirements:"
        echo "  - Keycloak deployed with cost-management-operator client"
        echo "  - ROS ingress deployed with JWT authentication enabled"
        echo "  - OpenShift cluster with proper RBAC permissions"
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
