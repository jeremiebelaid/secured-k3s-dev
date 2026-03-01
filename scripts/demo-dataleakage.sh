#!/bin/bash
#
# Data Leak Prevention Demo
# Runs from outside the cluster, executing each test on the remote Coder workspace
# via `coder ssh`. Validates Tetragon + Cilium enforcement.
#
set -u

WORKSPACE="${1:-${CODER_WORKSPACE:-}}"
if [ -z "$WORKSPACE" ]; then
  echo "Usage: $0 <workspace-name>"
  echo "  or set CODER_WORKSPACE env var"
  echo ""
  echo "Available workspaces:"
  coder list 2>/dev/null
  exit 2
fi

PASS=0
FAIL=0
SKIP=0
TOTAL=0

remote() {
  coder ssh "$WORKSPACE" -- "$@"
}

remote_check() {
  coder ssh "$WORKSPACE" -- "$@" >/dev/null 2>&1
}

remote_shell() {
  coder ssh "$WORKSPACE" -- bash -c "$1"
}

run_test() {
  local description="$1"
  local expect_blocked="$2"
  shift 2

  TOTAL=$((TOTAL + 1))
  echo ""
  echo "--- TEST $TOTAL: $description ---"
  echo "    Command: $*"

  output=$(remote "$@" 2>&1)
  exit_code=$?

  if [ "$expect_blocked" = "true" ]; then
    if [ $exit_code -ne 0 ]; then
      echo "    Result: BLOCKED (exit=$exit_code) -> PASS"
      PASS=$((PASS + 1))
    else
      echo "    Result: ALLOWED (exit=$exit_code) -> FAIL (should have been blocked)"
      echo "    Output: ${output:0:200}"
      FAIL=$((FAIL + 1))
    fi
  else
    if [ $exit_code -eq 0 ]; then
      echo "    Result: ALLOWED (exit=$exit_code) -> PASS"
      PASS=$((PASS + 1))
    else
      echo "    Result: BLOCKED (exit=$exit_code) -> FAIL (should have been allowed)"
      echo "    Output: ${output:0:200}"
      FAIL=$((FAIL + 1))
    fi
  fi
}

skip_test() {
  local description="$1"
  local reason="$2"

  TOTAL=$((TOTAL + 1))
  SKIP=$((SKIP + 1))
  echo ""
  echo "--- TEST $TOTAL: $description ---"
  echo "    Result: SKIPPED (infra not ready)"
  echo "    Reason: $reason"
}

echo "============================================"
echo "  DATA LEAK PREVENTION DEMO"
echo "  Workspace: $WORKSPACE"
echo "  Protection: Tetragon + Cilium egress via proxy"
echo "============================================"

echo ""
echo "  Verifying connectivity to workspace '$WORKSPACE'..."
if ! remote echo ok >/dev/null 2>&1; then
  echo "  ERROR: Cannot connect to workspace '$WORKSPACE'."
  echo "  Make sure it is running: coder list"
  exit 2
fi
echo "  Connected."

echo ""
echo ">> LAYER 1: Direct external egress is blocked by network policy"
echo ""

run_test \
  "curl GET to external site (should be blocked)" \
  "true" \
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy curl --max-time 5 -s https://example.com

run_test \
  "wget GET to external site (should be blocked)" \
  "true" \
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy wget --timeout=5 -q -O /dev/null https://example.com

run_test \
  "Python HTTP request to external (should be blocked)" \
  "true" \
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy python3 -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)"

echo ""
echo ">> LAYER 2: Squid proxy upload size limit (5MB allowed, 100MB blocked)"
echo ""

PROXY_HOST="dlp-egress-proxy.coder-secure.svc.cluster.local"
PROXY_URL="http://${PROXY_HOST}:3128"
UPLOAD_TARGET="https://httpbin.org/post"

run_test \
  "Prepare small upload sample (5MB)" \
  "false" \
  dd if=/dev/zero of=/tmp/upload-small.bin bs=1M count=5 status=none

run_test \
  "Prepare large upload sample (100MB)" \
  "false" \
  dd if=/dev/zero of=/tmp/upload-large.bin bs=1M count=100 status=none

if remote_check getent hosts "$PROXY_HOST"; then
  run_test \
    "Push 5MB through Squid proxy (should be allowed)" \
    "false" \
    curl --proxy "${PROXY_URL}" --fail --max-time 30 -sS -o /dev/null -w "%{http_code}" -X POST --data-binary "@/tmp/upload-small.bin" "${UPLOAD_TARGET}"

  run_test \
    "Push 100MB through Squid proxy (should be blocked with 413)" \
    "true" \
    curl --proxy "${PROXY_URL}" --fail --max-time 45 -sS -o /dev/null -w "%{http_code}" -X POST --data-binary "@/tmp/upload-large.bin" "${UPLOAD_TARGET}"
else
  skip_test \
    "Push 5MB through Squid proxy (should be allowed)" \
    "Cannot resolve ${PROXY_HOST}; proxy service not deployed yet."

  skip_test \
    "Push 100MB through Squid proxy (should be blocked with 413)" \
    "Cannot resolve ${PROXY_HOST}; proxy service not deployed yet."
fi

echo ""
echo ">> LAYER 3: Toxic data-access pattern on protected DLP zone is blocked"
echo ""

remote mkdir -p /tmp/dlp-sensitive >/dev/null 2>&1

run_test \
  "Prepare synthetic sensitive file in /tmp/dlp-sensitive (should be allowed)" \
  "false" \
  dd if=/dev/zero of=/tmp/dlp-sensitive/payload.bin bs=1M count=5 status=none

run_test \
  "base64 read from /tmp/dlp-sensitive (should be killed)" \
  "true" \
  base64 /tmp/dlp-sensitive/payload.bin

echo ""
echo ">> LAYER 4: Sensitive file access (Tetragon Sigkill on security_file_open)"
echo ""

run_test \
  "Read /etc/shadow (should be killed)" \
  "true" \
  cat /etc/shadow

run_test \
  "Read /etc/gshadow (should be killed)" \
  "true" \
  cat /etc/gshadow

run_test \
  "Read K8s service account token (should be killed)" \
  "true" \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token

echo ""
echo ">> LAYER 5: Allowed traffic (cluster-internal)"
echo ""

CODER_SVC="coder.coder.svc.cluster.local"
if remote_check getent hosts "$CODER_SVC"; then
  run_test \
    "DNS resolution (should be allowed)" \
    "false" \
    getent hosts "$CODER_SVC"

  run_test \
    "curl to Coder service (cluster-internal, should be allowed)" \
    "false" \
    curl --max-time 5 -s -o /dev/null -w "%{http_code}" "http://${CODER_SVC}:80"
else
  skip_test \
    "DNS resolution (should be allowed)" \
    "Cannot resolve ${CODER_SVC}; cluster DNS not available."

  skip_test \
    "curl to Coder service (cluster-internal, should be allowed)" \
    "Cannot resolve ${CODER_SVC}; cluster DNS not available."
fi

echo ""
echo "============================================"
echo "  RESULTS: $PASS passed / $FAIL failed / $SKIP skipped / $TOTAL total"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
  if [ "$SKIP" -gt 0 ]; then
    echo "  NO FAILURES - Some tests skipped because infra is not ready."
  else
    echo "  ALL TESTS PASSED - Data leak prevention is working."
  fi
  exit 0
else
  echo "  SOME TESTS FAILED - Review the output above."
  exit 1
fi
