#!/usr/bin/env bash
# Cluster X-Ray — serve the live visualizer through kubectl proxy.
#
#   bash tools/xray/serve.sh            # then open the URL it prints
#   PORT=8002 bash tools/xray/serve.sh  # if 8001 is busy
#
# The proxy does two jobs at once: it serves this directory's static page AND forwards /api/... to
# your cluster with your own kubeconfig credentials. Same origin, so the page needs no token, no
# CORS and no backend.
#
# It binds 127.0.0.1 only. kubectl proxy's default address is the loopback interface and this
# script passes no --address, deliberately: the proxy forwards with YOUR credentials, so anything
# that can reach the port can act as you on the cluster. Do not widen it.
#
# bash-3.2 compatible (macOS default shell).
set -euo pipefail

XRAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- pinned-binary resolution -------------------------------------------------
# Same story as every other lab script: prepend the documented install prefix, then ASSERT the
# kubectl that resolves, through the one helper that owns the pins. The helper sits one directory
# up in both trees — labs/tools/pinned-bin.sh here, tools/pinned-bin.sh in the published labs repo.
LAB_BIN_PREFIX="${LAB_BIN_PREFIX:-${HOME}/.local/bin}"
PATH="${LAB_BIN_PREFIX}:${PATH}"
export PATH
. "$(cd "${XRAY_DIR}/.." && pwd)/pinned-bin.sh"
assert_kubectl_version

PORT="${PORT:-8001}"
CONTEXT="kind-grid-core"
KUBECONFIG="${KUBECONFIG:-/tmp/grid-core.kubeconfig}"
export KUBECONFIG

# A missing kubeconfig is the common case after a reboot (/tmp is cleared). Say what fixes it
# rather than letting kubectl print a context error.
case "${KUBECONFIG}" in
  *:*) ;;   # a list of files; kubectl merges them, so there is no single file to check
  *)
    if [ ! -f "${KUBECONFIG}" ]; then
      echo "FAIL: no kubeconfig at ${KUBECONFIG}." >&2
      echo "      Create (or reuse) the base cluster first, from the clone root:" >&2
      echo "        bash clusters/grid-core/create.sh" >&2
      echo "      It writes ${KUBECONFIG}. Then run this script again." >&2
      exit 1
    fi
    ;;
esac
if ! kubectl config get-contexts "${CONTEXT}" >/dev/null 2>&1; then
  echo "FAIL: kubeconfig ${KUBECONFIG} has no context ${CONTEXT}." >&2
  echo "      Point KUBECONFIG at the grid-core kubeconfig, or recreate it with:" >&2
  echo "        bash clusters/grid-core/create.sh" >&2
  exit 1
fi

echo "┌─────────────────────────────────────────────────────────────"
echo "│  Cluster X-Ray · Baseline lens (M1)"
echo "│"
echo "│  context    : ${CONTEXT}"
echo "│  kubeconfig : ${KUBECONFIG}"
echo "│"
echo "│  open       : http://127.0.0.1:${PORT}/xray/"
echo "│"
echo "│  Ctrl-C stops the proxy. Port busy? PORT=8002 bash tools/xray/serve.sh"
echo "└─────────────────────────────────────────────────────────────"

exec kubectl proxy --context "${CONTEXT}" --www="${XRAY_DIR}" --www-prefix=/xray/ --port="${PORT}"
