#!/bin/bash

# Base URL for Admin API
ADMIN_URL="http://127.0.0.1:9180/apisix/admin/routes"
ADMIN_KEY="edd1c9f034335f136f87ad84b625c8f1"

# Function to create route
create_route() {
  local id=$1
  local uri=$2
  local upstream=$3
  local strip_path=$4
  
  echo "Creating route $id for $uri -> $upstream"

  plugins="{}"
  if [ "$strip_path" != "" ]; then
    plugins="{
      \"proxy-rewrite\": {
        \"regex_uri\": [\"^$strip_path(.*)\", \"/\$1\"]
      }
    }"
  fi

  curl -i -X PUT "$ADMIN_URL/$id" \
    -H "X-API-KEY: $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"uri\": \"$uri\",
      \"plugins\": $plugins,
      \"upstream\": {
        \"type\": \"roundrobin\",
        \"nodes\": {
          \"$upstream\": 1
        }
      }
    }"
    echo ""
}

# 1. Central API
# Path /api/central/* -> http://host.docker.internal:8000
# Strip /api/central/
create_route "central-api" "/api/central/*" "host.docker.internal:8000" "/api/central"

# 2. IAM API
# Path /api/iam/* -> http://host.docker.internal:8001
# Strip /api/iam/
create_route "iam-api" "/api/iam/*" "host.docker.internal:8001" "/api/iam"

# 3. CRM API
# Path /api/crm/* -> http://host.docker.internal:8010
# Strip /api/crm/
create_route "crm-api" "/api/crm/*" "host.docker.internal:8010" "/api/crm"

# 4. BPM API
# Path /api/bpm/* -> http://host.docker.internal:8020
# Strip /api/bpm/
create_route "bpm-api" "/api/bpm/*" "host.docker.internal:8020" "/api/bpm"

# 5. Frontend Shell
# Host *.arda.io.vn -> http://host.docker.internal:4200
echo "Creating route frontend-shell for *.arda.io.vn -> host.docker.internal:4200"
curl -i -X PUT "$ADMIN_URL/frontend-shell" \
  -H "X-API-KEY: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"hosts\": [\"*.arda.io.vn\"],
    \"uri\": \"/*\",
    \"upstream\": {
      \"type\": \"roundrobin\",
      \"nodes\": {
        \"host.docker.internal:4200\": 1
      }
    }
  }"
echo ""
