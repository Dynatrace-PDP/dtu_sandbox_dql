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

