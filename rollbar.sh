#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${ROLLBAR_TEMPLATES_DIR:-${SCRIPT_DIR}/templates}"
EXPLICIT_ENV_FILE=0

usage() {
  cat <<'USAGE'
Usage:
  rollbar items [query] [--status <value>] [--level <value>] [--environment <value>] [--page <n>]
  rollbar item <counter>
  rollbar item --id <item-id>
  rollbar occurrences <item-id-or-counter> [--page <n>] [--id]
  rollbar project [project-id]
  rollbar --path <api-path> [--method <verb>] [<body-json-or-file-or-template>]

Options:
  --path, -p        Rollbar API path such as /api/1/items or /item/123.
  --method, -X      HTTP method. Defaults to GET when no body is present and POST otherwise.
  --query, -q       Search query for items, matching the Rollbar UI search syntax.
  --status          Filter items by status. Repeat or pass comma-separated values.
  --level           Filter items by level. Repeat or pass comma-separated values.
  --environment     Filter items by environment. Repeat or pass comma-separated values.
  --framework       Filter items by framework. Repeat or pass comma-separated values.
  --assigned-user   Filter items assigned to a username, assigned, or unassigned.
  --assigned-team   Filter items assigned to one or more team names.
  --ids             Comma-separated list of item IDs to fetch from /items.
  --page            Page number for paginated endpoints. Defaults to 1.
  --snoozed         Only return snoozed items.
  --not-snoozed     Exclude snoozed items.
  --id              Treat the rollbar item/occurrences argument as an item ID instead of a counter.
  --env-file        Shell env file to load.
  --pretty          Pretty-print JSON output with jq. This is the default.
  --jq              Apply a jq filter to the JSON response.
  --raw             Print the raw response instead of pretty JSON.
  --verbose         Print resolved config details to stderr.
  --list-templates  List available JSON request templates.
  --dry-run         Show the resolved request without calling Rollbar.
  --help, -h        Show this help text.

Environment:
  ROLLBAR_TOKEN         Preferred Rollbar project access token with read scope
  ROLLBAR_ACCESS_TOKEN  Alternate token variable name
  ROLLBAR_PROJECT_ID    Preferred Rollbar project ID
  PROJECT_ID            Alternate project ID variable name
  ROLLBAR_BASE_URL      Optional API origin. Defaults to https://api.rollbar.com

Examples:
  rollbar items --status active --level error --environment production
  rollbar items 'is:active level:error framework:node'
  rollbar item 456
  rollbar item --id 272505123
  rollbar occurrences 456
  rollbar project
  rollbar --path /api/1/items
USAGE
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

log_verbose() {
  if [ "${VERBOSE:-0}" -eq 1 ]; then
    printf '%s\n' "$*" >&2
  fi
}

load_env_file() {
  local env_file="$1"

  if [ -z "$env_file" ]; then
    return
  fi

  if [ ! -f "$env_file" ]; then
    echo "Env file not found: $env_file" >&2
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

choose_default_env_file() {
  local candidate=""

  for candidate in \
    ".rollbar.env" \
    "${SCRIPT_DIR}/.rollbar.env" \
    "$HOME/.rollbar.env" \
    ".rollbar-cli.env" \
    "${SCRIPT_DIR}/.rollbar-cli.env" \
    "$HOME/.rollbar-cli.env"
  do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

find_template_file() {
  local input="$1"
  local candidate=""

  if [ ! -d "$TEMPLATES_DIR" ]; then
    return 1
  fi

  for candidate in \
    "${TEMPLATES_DIR}/${input}" \
    "${TEMPLATES_DIR}/${input}.json"
  do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  return 1
}

list_templates() {
  if [ ! -d "$TEMPLATES_DIR" ]; then
    exit 0
  fi

  find "$TEMPLATES_DIR" -maxdepth 1 -type f -name '*.json' -print \
    | sed "s#^${TEMPLATES_DIR}/##" \
    | sed 's/\.json$//' \
    | sort
}

json_from_input() {
  local input="$1"
  local source="$input"
  local content=""
  local template_file=""

  if [ -f "$input" ]; then
    source="$input"
    content="$(cat "$input")"
  elif template_file="$(find_template_file "$input" 2>/dev/null)"; then
    source="$template_file"
    content="$(cat "$template_file")"
  else
    content="$input"
  fi

  if ! printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
    echo "Invalid JSON from: $source" >&2
    exit 1
  fi

  printf '%s' "$content" | jq -c .
}

normalize_path() {
  local path="$1"

  if [ -z "$path" ]; then
    printf '%s' "$path"
    return 0
  fi

  if [[ "$path" != /* ]]; then
    path="/${path}"
  fi

  if [[ "$path" != /api/* ]]; then
    path="/api/1${path}"
  fi

  printf '%s' "$path"
}

append_query_param() {
  local path="$1"
  local name="$2"
  local value="$3"

  jq -rn \
    --arg path "$path" \
    --arg name "$name" \
    --arg value "$value" \
    '$path + (if ($path | contains("?")) then "&" else "?" end) + ($name | @uri) + "=" + ($value | @uri)'
}

append_multi_params() {
  local path="$1"
  local name="$2"
  shift 2
  local values=("$@")
  local value=""

  for value in "${values[@]}"; do
    [ -n "$value" ] || continue
    path="$(append_query_param "$path" "$name" "$value")"
  done

  printf '%s' "$path"
}

csv_to_values() {
  local csv="$1"
  printf '%s\n' "$csv" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d'
}

resolve_token() {
  ACCESS_TOKEN="${ROLLBAR_TOKEN:-${ROLLBAR_ACCESS_TOKEN:-}}"
  : "${ACCESS_TOKEN:?Set ROLLBAR_TOKEN or ROLLBAR_ACCESS_TOKEN to a Rollbar token with read scope}"
}

resolve_project_id() {
  PROJECT_IDENTIFIER="${ROLLBAR_PROJECT_ID:-${PROJECT_ID:-}}"
}

require_project_id() {
  resolve_project_id
  : "${PROJECT_IDENTIFIER:?Set ROLLBAR_PROJECT_ID or PROJECT_ID to your Rollbar project ID}"
}

require_positive_integer() {
  local label="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "${label} must be a positive integer" >&2
    exit 1
  fi
}

resolve_item_path_from_counter() {
  local counter="$1"
  local response_file
  local http_code
  local item_path

  response_file="$(mktemp)"

  http_code="$(
    curl \
      -sS \
      -o "$response_file" \
      -w '%{http_code}' \
      --header "X-Rollbar-Access-Token: ${ACCESS_TOKEN}" \
      --header 'Accept: application/json' \
      "${BASE_URL}/api/1/item_by_counter/${counter}"
  )"

  if [ "${http_code:0:1}" != "2" ] && [ "$http_code" != "301" ]; then
    echo "Rollbar request failed with HTTP ${http_code}" >&2
    jq -r '.message?, .err? // empty' "$response_file" 2>/dev/null >&2 || cat "$response_file" >&2
    rm -f "$response_file"
    exit 1
  fi

  item_path="$(jq -r '.result.path // .result.uri // empty' "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  if [ -z "$item_path" ]; then
    echo "Could not resolve item counter ${counter} to an item path." >&2
    exit 1
  fi

  printf '%s' "$item_path"
}

require_command curl
require_command jq

ENV_FILE=""
VERBOSE=0
LIST_TEMPLATES=0
DRY_RUN=0
OUTPUT_MODE="pretty"
JQ_FILTER=""
METHOD=""
API_PATH=""
QUERY=""
PAGE=1
USE_ITEM_ID=0
SNOOZED_MODE=""
COMMAND=""
POSITIONAL=()
ITEM_STATUSES=()
ITEM_LEVELS=()
ITEM_ENVIRONMENTS=()
ITEM_FRAMEWORKS=()
ITEM_ASSIGNED_TEAMS=()
ITEM_ASSIGNED_USER=""
ITEM_IDS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --path|-p)
      API_PATH="${2:-}"
      shift 2
      ;;
    --method|-X)
      METHOD="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"
      shift 2
      ;;
    --query|-q)
      QUERY="${2:-}"
      shift 2
      ;;
    --status)
      while IFS= read -r value; do
        ITEM_STATUSES+=("$value")
      done < <(csv_to_values "${2:-}")
      shift 2
      ;;
    --level)
      while IFS= read -r value; do
        ITEM_LEVELS+=("$value")
      done < <(csv_to_values "${2:-}")
      shift 2
      ;;
    --environment)
      while IFS= read -r value; do
        ITEM_ENVIRONMENTS+=("$value")
      done < <(csv_to_values "${2:-}")
      shift 2
      ;;
    --framework)
      while IFS= read -r value; do
        ITEM_FRAMEWORKS+=("$value")
      done < <(csv_to_values "${2:-}")
      shift 2
      ;;
    --assigned-user)
      ITEM_ASSIGNED_USER="${2:-}"
      shift 2
      ;;
    --assigned-team)
      while IFS= read -r value; do
        ITEM_ASSIGNED_TEAMS+=("$value")
      done < <(csv_to_values "${2:-}")
      shift 2
      ;;
    --ids)
      ITEM_IDS="${2:-}"
      shift 2
      ;;
    --page)
      PAGE="${2:-}"
      shift 2
      ;;
    --snoozed)
      SNOOZED_MODE="true"
      shift 1
      ;;
    --not-snoozed)
      SNOOZED_MODE="false"
      shift 1
      ;;
    --id)
      USE_ITEM_ID=1
      shift 1
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      EXPLICIT_ENV_FILE=1
      shift 2
      ;;
    --pretty)
      OUTPUT_MODE="pretty"
      shift 1
      ;;
    --jq)
      OUTPUT_MODE="jq"
      JQ_FILTER="${2:-}"
      shift 2
      ;;
    --raw)
      OUTPUT_MODE="raw"
      shift 1
      ;;
    --verbose)
      VERBOSE=1
      shift 1
      ;;
    --list-templates)
      LIST_TEMPLATES=1
      shift 1
      ;;
    --dry-run)
      DRY_RUN=1
      shift 1
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    items|item|occurrences|project)
      if [ -n "$COMMAND" ]; then
        echo "Only one subcommand is allowed." >&2
        exit 1
      fi
      COMMAND="$1"
      shift 1
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift 1
      ;;
  esac
done

if [ "$LIST_TEMPLATES" -eq 1 ]; then
  list_templates
  exit 0
fi

if [ -z "$ENV_FILE" ] && choose_default_env_file >/dev/null 2>&1; then
  ENV_FILE="$(choose_default_env_file)"
fi

if [ -n "$ENV_FILE" ] || [ "$EXPLICIT_ENV_FILE" -eq 1 ]; then
  load_env_file "$ENV_FILE"
fi

resolve_token
resolve_project_id

BASE_URL="${ROLLBAR_BASE_URL:-https://api.rollbar.com}"
BASE_URL="${BASE_URL%/}"

require_positive_integer "--page" "$PAGE"

REQUEST_BODY=""
DRY_RUN_NOTE=""

if [ "$COMMAND" = "items" ]; then
  if [ -z "$QUERY" ] && [ "${#POSITIONAL[@]}" -gt 0 ]; then
    QUERY="${POSITIONAL[0]}"
    POSITIONAL=("${POSITIONAL[@]:1}")
  fi

  if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    echo "Too many positional arguments for items." >&2
    exit 1
  fi

  API_PATH="/api/1/items"
  API_PATH="$(append_query_param "$API_PATH" "page" "$PAGE")"
  [ -n "$QUERY" ] && API_PATH="$(append_query_param "$API_PATH" "query" "$QUERY")"
  [ -n "$ITEM_ASSIGNED_USER" ] && API_PATH="$(append_query_param "$API_PATH" "assigned_user" "$ITEM_ASSIGNED_USER")"
  [ -n "$ITEM_IDS" ] && API_PATH="$(append_query_param "$API_PATH" "ids" "$ITEM_IDS")"
  [ -n "$SNOOZED_MODE" ] && API_PATH="$(append_query_param "$API_PATH" "is_snoozed" "$SNOOZED_MODE")"
  if [ "${#ITEM_STATUSES[@]}" -gt 0 ]; then
    API_PATH="$(append_multi_params "$API_PATH" "status" "${ITEM_STATUSES[@]}")"
  fi
  if [ "${#ITEM_LEVELS[@]}" -gt 0 ]; then
    API_PATH="$(append_multi_params "$API_PATH" "level" "${ITEM_LEVELS[@]}")"
  fi
  if [ "${#ITEM_ENVIRONMENTS[@]}" -gt 0 ]; then
    API_PATH="$(append_multi_params "$API_PATH" "environment" "${ITEM_ENVIRONMENTS[@]}")"
  fi
  if [ "${#ITEM_FRAMEWORKS[@]}" -gt 0 ]; then
    API_PATH="$(append_multi_params "$API_PATH" "framework" "${ITEM_FRAMEWORKS[@]}")"
  fi
  if [ "${#ITEM_ASSIGNED_TEAMS[@]}" -gt 0 ]; then
    API_PATH="$(append_multi_params "$API_PATH" "assigned_team" "${ITEM_ASSIGNED_TEAMS[@]}")"
  fi
  METHOD="${METHOD:-GET}"
fi

if [ "$COMMAND" = "item" ]; then
  if [ "${#POSITIONAL[@]}" -lt 1 ]; then
    echo "item requires a counter or an item ID." >&2
    exit 1
  fi

  ITEM_REFERENCE="${POSITIONAL[0]}"
  POSITIONAL=("${POSITIONAL[@]:1}")

  if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    echo "Too many positional arguments for item." >&2
    exit 1
  fi

  if [ "$USE_ITEM_ID" -eq 1 ]; then
    API_PATH="/api/1/item/${ITEM_REFERENCE}"
  else
    API_PATH="/api/1/item_by_counter/${ITEM_REFERENCE}"
  fi
  METHOD="${METHOD:-GET}"
fi

if [ "$COMMAND" = "occurrences" ]; then
  if [ "${#POSITIONAL[@]}" -lt 1 ]; then
    echo "occurrences requires an item counter or item ID." >&2
    exit 1
  fi

  ITEM_REFERENCE="${POSITIONAL[0]}"
  POSITIONAL=("${POSITIONAL[@]:1}")

  if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    echo "Too many positional arguments for occurrences." >&2
    exit 1
  fi

  if [ "$USE_ITEM_ID" -eq 1 ]; then
    ITEM_API_PATH="/api/1/item/${ITEM_REFERENCE}"
  elif [ "$DRY_RUN" -eq 1 ]; then
    API_PATH="/api/1/item_by_counter/${ITEM_REFERENCE}"
    DRY_RUN_NOTE="Counter-based occurrences resolve item_by_counter before calling /api/1/item/{id}/instances."
  else
    ITEM_API_PATH="$(resolve_item_path_from_counter "$ITEM_REFERENCE")"
  fi

  if [ -z "$API_PATH" ]; then
    ITEM_ID="$(printf '%s' "$ITEM_API_PATH" | sed -E 's#^/api/1/item/([0-9]+)$#\1#')"
    if ! [[ "$ITEM_ID" =~ ^[0-9]+$ ]]; then
      echo "Could not determine item ID from: ${ITEM_API_PATH}" >&2
      exit 1
    fi

    API_PATH="/api/1/item/${ITEM_ID}/instances"
    API_PATH="$(append_query_param "$API_PATH" "page" "$PAGE")"
  fi
  METHOD="${METHOD:-GET}"
fi

if [ "$COMMAND" = "project" ]; then
  if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    PROJECT_IDENTIFIER="${POSITIONAL[0]}"
    POSITIONAL=("${POSITIONAL[@]:1}")
  fi

  if [ "${#POSITIONAL[@]}" -gt 0 ]; then
    echo "Too many positional arguments for project." >&2
    exit 1
  fi

  : "${PROJECT_IDENTIFIER:?Set ROLLBAR_PROJECT_ID or PROJECT_ID, or pass a project ID explicitly}"
  API_PATH="/api/1/project/${PROJECT_IDENTIFIER}"
  METHOD="${METHOD:-GET}"
fi

if [ -z "$API_PATH" ] && [ "${#POSITIONAL[@]}" -gt 0 ]; then
  if [ "${#POSITIONAL[@]}" -gt 1 ]; then
    echo "Too many positional arguments." >&2
    exit 1
  fi

  REQUEST_BODY="$(json_from_input "${POSITIONAL[0]}")"
  POSITIONAL=()
fi

if [ -n "$API_PATH" ]; then
  API_PATH="$(normalize_path "$API_PATH")"
fi

if [ -z "$API_PATH" ]; then
  echo "Provide a subcommand or --path when calling Rollbar." >&2
  usage >&2
  exit 1
fi

METHOD="${METHOD:-GET}"
if [ -n "$REQUEST_BODY" ] && [ -z "${METHOD:-}" ]; then
  METHOD="POST"
fi
if [ -n "$REQUEST_BODY" ] && [ "$METHOD" = "GET" ]; then
  METHOD="POST"
fi

FULL_PATH="${BASE_URL}${API_PATH}"

log_verbose "rollbar-cli: env file=${ENV_FILE:-<none>}"
log_verbose "rollbar-cli: base url=${BASE_URL}"
log_verbose "rollbar-cli: method=${METHOD}"
log_verbose "rollbar-cli: path=${API_PATH}"
if [ -n "$PROJECT_IDENTIFIER" ]; then
  log_verbose "rollbar-cli: project id=${PROJECT_IDENTIFIER}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  jq -n \
    --arg envFile "${ENV_FILE:-}" \
    --arg baseUrl "$BASE_URL" \
    --arg path "$API_PATH" \
    --arg url "$FULL_PATH" \
    --arg method "$METHOD" \
    --arg body "${REQUEST_BODY:-}" \
    --arg note "${DRY_RUN_NOTE:-}" \
    '{
      envFile: (if $envFile == "" then null else $envFile end),
      baseUrl: $baseUrl,
      path: $path,
      url: $url,
      method: $method,
      body: (if $body == "" then null else ($body | fromjson) end),
      note: (if $note == "" then null else $note end)
    }'
  exit 0
fi

body_file="$(mktemp)"
cleanup() {
  rm -f "$body_file"
}
trap cleanup EXIT

CURL_ARGS=(
  -sS
  --location
  -o "$body_file"
  -w '%{http_code}'
  --header "X-Rollbar-Access-Token: ${ACCESS_TOKEN}"
  --header 'Accept: application/json'
  --request "$METHOD"
)

if [ -n "$REQUEST_BODY" ]; then
  CURL_ARGS+=(--header 'Content-Type: application/json' --data "$REQUEST_BODY")
fi

HTTP_CODE="$(curl "${CURL_ARGS[@]}" "$FULL_PATH")"

if [ "${HTTP_CODE:0:1}" != "2" ]; then
  echo "Rollbar request failed with HTTP ${HTTP_CODE}" >&2
  jq -r '.message?, .err? // empty' "$body_file" 2>/dev/null >&2 || cat "$body_file" >&2
  exit 1
fi

case "$OUTPUT_MODE" in
  raw)
    cat "$body_file"
    ;;
  jq)
    jq -r "$JQ_FILTER" "$body_file"
    ;;
  pretty)
    jq . "$body_file"
    ;;
  *)
    echo "Unsupported output mode: $OUTPUT_MODE" >&2
    exit 1
    ;;
esac
