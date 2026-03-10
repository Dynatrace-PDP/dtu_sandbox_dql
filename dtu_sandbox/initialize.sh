#!/usr/bin/env bash
set -euo pipefail

YLW='\033[1;33m'
NC='\033[0m'

FILE="/var/tmp/aether-ansible/ansible/ansible_config_vars.yml"

# Read key/value pairs like: key: "value"
# - ignores blank lines and comments starting with #
# - trims whitespace
# - removes surrounding single/double quotes from values
# - exports variables into the current script environment
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip empty lines and comments
  [[ -z "${line//[[:space:]]/}" ]] && continue
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue

  # Only process lines that look like "key: value"
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)[[:space:]]*$ ]]; then
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"

    # Trim leading/trailing whitespace from val
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    # Remove surrounding quotes if present
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi

    # Set variable safely (supports any content in val)
    printf -v "$key" '%s' "$val"
    export "$key"
  fi
done < "$FILE"

# Echo variables (add/remove as you like)
echo -e "${YLW}Please confirm all are correct: ${NC}"
echo "aether_id=${aether_id-}"
echo "dynatrace_environment_access_token=${dynatrace_environment_access_token-}"
echo "dynatrace_environment_app_url=${dynatrace_environment_app_url-}"
echo "dynatrace_environment_url=${dynatrace_environment_url-}"
echo "ingress_domain=${ingress_domain-}"
echo "instance_user=${instance_user-}"
echo "instance_password=${instance_password-}"

create_dt_token() {
  # Usage:
  #   create_dt_token "tokenName" "now+14d" "scope1" "scope2" ...
  #
  # Sets + exports:
  #   dt_token_id
  #   dt_token_value
  #   dt_token_expiration

  local token_name="${1:?token name required}"
  local expiration="${2:-now+14d}"
  shift 2

  # Remaining args are scopes
  local scopes=("$@")
  if [[ ${#scopes[@]} -eq 0 ]]; then
    echo "create_dt_token: at least one scope is required" >&2
    return 2
  fi

  # Required env vars
  : "${dynatrace_environment_url:?Missing dynatrace_environment_url}"
  : "${dynatrace_environment_access_token:?Missing dynatrace_environment_access_token}"
  command -v jq >/dev/null 2>&1 || { echo "create_dt_token: jq not found" >&2; return 127; }

  # Mask helper (avoid printing secrets)
  _mask() {
    local s="${1:-}"
    if [[ ${#s} -ge 12 ]]; then
      printf '%s…%s' "${s:0:6}" "${s: -4}"
    else
      printf '<redacted>'
    fi
  }

  local response_json http_code payload

  response_json="$(mktemp)"
  trap 'rm -f "$response_json"' RETURN

  # Build JSON payload with jq (safe escaping)
  payload="$(
    jq -n \
      --arg expirationDate "$expiration" \
      --arg name "$token_name" \
      --argjson personalAccessToken false \
      --argjson scopes "$(printf '%s\n' "${scopes[@]}" | jq -R . | jq -s .)" \
      '{
        expirationDate: $expirationDate,
        name: $name,
        personalAccessToken: $personalAccessToken,
        scopes: $scopes
      }'
  )"

  http_code="$(
    curl -sS -o "$response_json" -w '%{http_code}' \
      -X POST \
      "${dynatrace_environment_url}/api/v2/apiTokens" \
      -H 'accept: application/json; charset=utf-8' \
      -H "Authorization: Api-Token ${dynatrace_environment_access_token}" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d "$payload"
  )"

  # Fail fast on non-2xx
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "create_dt_token: API call failed (HTTP $http_code)" >&2
    echo "Response body:" >&2
    cat "$response_json" >&2
    return 1
  fi

  # Extract from your known response shape: {"id":"...","token":"...","expirationDate":"..."}
  dt_token_id="$(jq -r '.id // empty' "$response_json")"
  dt_token_value="$(jq -r '.token // empty' "$response_json")"
  dt_token_expiration="$(jq -r '.expirationDate // empty' "$response_json")"

  : "${dt_token_id:?create_dt_token: Missing .id in response}"
  : "${dt_token_value:?create_dt_token: Missing .token in response}"
  : "${dt_token_expiration:?create_dt_token: Missing .expirationDate in response}"

  export dt_token_id dt_token_value dt_token_expiration

  echo "Created token:"
  echo "  id:      ${dt_token_id}"
  echo "  token:   $(_mask "$dt_token_value")"
  echo "  expires: ${dt_token_expiration}"
}

write_token_env() {
  : "${dt_token_id:?dt_token_id missing}"
  : "${dt_token_value:?dt_token_value missing}"
  : "${dt_token_expiration:?dt_token_expiration missing}"

  local out="${1:-/var/tmp/aether-ansible/ansible/generated_token.env}"
  umask 077
  {
    echo "DT_API_TOKEN_ID=${dt_token_id}"
    echo "DT_API_TOKEN=${dt_token_value}"
    echo "DT_API_TOKEN_EXPIRATION=${dt_token_expiration}"
  } > "$out"
  echo "Wrote token env file: $out"
}

###Call Token Creation
create_dt_token "bashScript_stage" "now+14d" \
  "metrics.ingest" \
  "openTelemetryTrace.ingest" \
  "logs.ingest" \
  "settings.write" \
  "settings.read" \
  "securityProblems.write" \
  "securityProblems.read"

##Write token to file for later use if necessary
write_token_env "/home/${instance_user}/generated_token.env"

###Extract Tenant UUID
tenantUUID="${dynatrace_environment_url#https://}"
tenantUUID="${tenantUUID%%.*}"

###Sed Monaco Files
sed -i  "s,TENANTURL_TOREPLACE,$tenantUUID," /home/${instance_user}/dtu_sandbox_dql/files/kube-settings/manifest.yaml
sed -i  "s,TENANTURL_TOREPLACE,$tenantUUID," /home/${instance_user}/dtu_sandbox_dql/files/appSecSettings/manifest.yaml
sed -i  "s,TENANTURL_TOREPLACE,$tenantUUID," /home/${instance_user}/dtu_sandbox_dql/files/davisSettings/manifest.yaml

###Monaco
#dont need to move if we direct link
#mv /home/{{ ace_box_user }}/monaco /usr/local/bin/
curl -L https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/latest/download/monaco-linux-amd64 -o /home/${instance_user}/monaco-linux-amd64
mv /home/${instance_user}/monaco-linux-amd64 /home/${instance_user}/monaco
chmod +x /home/${instance_user}/monaco

###Apply Monaco Configs
export dttoken="${dt_token_value}"
/home/${instance_user}/monaco deploy /home/${instance_user}/dtu_sandbox_dql/files/kube-settings/manifest.yaml
/home/${instance_user}/monaco deploy /home/${instance_user}/dtu_sandbox_dql/files/appSecSettings/manifest.yaml
/home/${instance_user}/monaco deploy /home/${instance_user}/dtu_sandbox_dql/files/davisSettings/manifest.yaml

###Remove unnecessary apps
kubectl delete namespace easytrade otel-demo unguard --ignore-not-found

###Helm Function
add_helm_repo() {
  local name="${1:?repo name required}"
  local url="${2:?repo url required}"

  if ! helm repo list | awk '{print $1}' | grep -qx "$name"; then
    echo "Adding Helm repo: $name"
    helm repo add "$name" "$url"
  else
    echo "Helm repo already exists: $name"
  fi
}

add_helm_repo istio https://istio-release.storage.googleapis.com/charts
helm repo update

#Install CRDS, without these - some pieces fail to deploy
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
{ kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.4.0" | kubectl apply -f -; }

###Istio Helm Deploy
deploy_istio_base() {
  local release="istio-base"
  local chart="istio/base"
  local ns="istio-system"
  local revision="default"

  helm repo update

  helm upgrade --install "$release" "$chart" \
    --namespace "$ns" \
    --create-namespace \
    --set-string "defaultRevision=${revision}" \
    --wait \
    --timeout 10m
}

deploy_istio_base

#Check deployment for logs
helm -n istio-system status istio-base
helm -n istio-system ls
kubectl get ns istio-system

###Add Helm Values
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --create-namespace \
  --values "/home/${instance_user}/dtu_sandbox_dql/files/istio/values.yaml" \
  --wait \
  --timeout 10m

###Deploying Cert Manager ( for OpenTelemetry Operator)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.0/cert-manager.yaml

###Wait for Cert Manager
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m

###Sleep for 10
sleep 10

###Deploy Otel collector
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

###Sleep for 240
sleep 240

###Modify Dynakube
sed -i  "s,TENANTURL_TOREPLACE,$dynatrace_environment_url," /home/${instance_user}/dtu_sandbox_dql/files/dynatrace/dynakube.yaml

###Set clustername to just dynakube instead of $CLUSTERNAME
sed -i  's,CLUSTER_NAME_TO_REPLACE,dynakube,' /home/${instance_user}/dtu_sandbox_dql/files/dynatrace/dynakube.yaml

###Get Kube UUID
kubeuuid="$(kubectl get dynakube dynakube -n dynatrace \
  -o jsonpath='{.status.kubeSystemUUID}')"

: "${kubeuuid:?Failed to retrieve kubeSystemUUID from dynakube}"

export kubeuuid

###Set Kube UUID to clusterID
: "${kubeuuid:?kubeuuid not set}"
clusterID="${kubeuuid}"
export clusterID

###Get api token for otel secret
dtTok="$(kubectl get secret dynakube -n dynatrace \
  -o jsonpath='{.data.apiToken}' | base64 --decode)"

: "${dtTok:?Failed to retrieve Dynatrace API token from dynakube secret}"

dtToken="${dtTok}"
export dtToken

###Deploy Otel Collector
# 1) Create/update Dynatrace secret for OTel collector
: "${dynatrace_environment_url:?dynatrace_environment_url not set}"
: "${clusterID:?clusterID not set}"
: "${dttoken:?dttoken not set}"

kubectl -n default create secret generic dynatrace \
  --from-literal="dynatrace_oltp_url=${dynatrace_environment_url}" \
  --from-literal="clustername=dynakube" \
  --from-literal="clusterid=${clusterID}" \
  --from-literal="dt_api_token=${dttoken}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) Disable OneAgent injection on default namespace
kubectl label namespace default oneagent=false --overwrite

# 3) Apply OpenTelemetry RBAC
rbac_file="/home/${instance_user}/dtu_sandbox_dql/files/opentelemetry/rbac.yaml"
[[ -f "$rbac_file" ]] || { echo "Missing RBAC file: $rbac_file" >&2; exit 1; }
kubectl apply -f "$rbac_file"

: "${instance_user:?instance_user not set}"

BASE_DIR="/home/${instance_user}/dtu_sandbox_dql/files"

DYNATRACE_NS="dynatrace"
OTEL_NS="otel-demo"
UNGUARD_NS="unguard"

# --- Re-apply Dynakube ---
kubectl delete dynakube dynakube -n "${DYNATRACE_NS}" --ignore-not-found
sleep 10

dynakube_yaml="${BASE_DIR}/dynatrace/dynakube.yaml"
[[ -f "$dynakube_yaml" ]] || { echo "Missing file: $dynakube_yaml" >&2; exit 1; }
kubectl apply -f "$dynakube_yaml" -n "${DYNATRACE_NS}"

# --- OpenTelemetry namespace setup ---
kubectl get namespace "${OTEL_NS}" >/dev/null 2>&1 || kubectl create namespace "${OTEL_NS}"
kubectl label namespace "${OTEL_NS}" oneagent=false --overwrite

# --- Istio gateway + enable Istio injection for OTEL namespace ---
gateway_yaml="${BASE_DIR}/istio/gateway.yaml"
[[ -f "$gateway_yaml" ]] || { echo "Missing file: $gateway_yaml" >&2; exit 1; }
kubectl apply -f "$gateway_yaml"

kubectl label namespace "${OTEL_NS}" istio-injection=enabled --overwrite
sleep 10

# --- Deploy OTEL demo app (StatefulSet manifest w/ Istio) ---
otel_demo_yaml="${BASE_DIR}/opentelemetry/openTelemetry-manifest_statefulset_istio.yaml"
[[ -f "$otel_demo_yaml" ]] || { echo "Missing file: $otel_demo_yaml" >&2; exit 1; }
kubectl apply -f "$otel_demo_yaml"

# --- Istio routing objects ---
referencegrant_yaml="${BASE_DIR}/istio/referencegrant.yaml"
[[ -f "$referencegrant_yaml" ]] || { echo "Missing file: $referencegrant_yaml" >&2; exit 1; }
kubectl apply -f "$referencegrant_yaml"

httproute_yaml="${BASE_DIR}/istio/httproute.yaml"
[[ -f "$httproute_yaml" ]] || { echo "Missing file: $httproute_yaml" >&2; exit 1; }
kubectl apply -f "$httproute_yaml"

# --- Final OTEL deploys ---
otel_ds_yaml="${BASE_DIR}/opentelemetry/openTelemetry-manifest_ds.yaml"
[[ -f "$otel_ds_yaml" ]] || { echo "Missing file: $otel_ds_yaml" >&2; exit 1; }
kubectl apply -f "$otel_ds_yaml"

otel_deploy_yaml="${BASE_DIR}/opentelemetry/deploy_1_12.yaml"
[[ -f "$otel_deploy_yaml" ]] || { echo "Missing file: $otel_deploy_yaml" >&2; exit 1; }
kubectl apply -f "$otel_deploy_yaml" -n "${OTEL_NS}"

# --- Deploy unGuard namespace + enable OneAgent injection ---
kubectl get namespace "${UNGUARD_NS}" >/dev/null 2>&1 || kubectl create namespace "${UNGUARD_NS}"
kubectl label namespace "${UNGUARD_NS}" oneagent=true --overwrite

: "${ingress_domain:?ingress_domain not set}"

UNGUARD_NS="unguard"

# --- Add Bitnami repo (idempotent) ---
if ! helm repo list | awk '{print $1}' | grep -qx bitnami; then
  helm repo add bitnami https://charts.bitnami.com/bitnami
fi
helm repo update

# --- Install MariaDB for unGuard ---
helm upgrade --install unguard-mariadb bitnami/mariadb \
  --set primary.persistence.enabled=false \
  --namespace "${UNGUARD_NS}" \
  --create-namespace \
  --wait

# --- Install unGuard ---
helm upgrade --install unguard \
  oci://ghcr.io/dynatrace-oss/unguard/chart/unguard \
  --namespace "${UNGUARD_NS}" \
  --create-namespace \
  --version 0.12.0 \
  --wait

# --- Patch unGuard ingress for public access ---
kubectl patch ingress unguard-ingress -n "${UNGUARD_NS}" \
  --type='merge' \
  -p "{
    \"spec\": {
      \"rules\": [
        {
          \"host\": \"unguard.${ingress_domain}\",
          \"http\": {
            \"paths\": [
              {
                \"path\": \"/\",
                \"pathType\": \"Prefix\",
                \"backend\": {
                  \"service\": {
                    \"name\": \"unguard-envoy-proxy\",
                    \"port\": { \"number\": 8080 }
                  }
                }
              }
            ]
          }
        }
      ]
    }
  }"

