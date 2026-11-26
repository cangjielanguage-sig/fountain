#!/usr/bin/env bash
# 远程 conformance：起 fhydra → 用同一套记忆断言对比「进程内 f_hydra」与「远程 fhydra」
set -e
source /mnt/d/docs/work/cangjie/cangjie.sh >/dev/null 2>&1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HYDRA_DIR="$ROOT/fhydra"
PORT=${PORT:-18085}
SECRET=${SECRET:-conf-secret}

export CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH"
LIBS=$(find "$HYDRA_DIR/target" -name 'lib*.so' -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')
export LD_LIBRARY_PATH="${LIBS}${LD_LIBRARY_PATH}"

export mvc_port="$PORT"
export hydra_secret="$SECRET"
export hydra_dataPath=/tmp/fhydra-conformance
rm -rf /tmp/fhydra-conformance

"$HYDRA_DIR/target/release/bin/main" >/tmp/fhydra-conformance.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT

for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:${PORT}/rpc"; then break; fi
  sleep 0.5
done

export llm_hydraUrl="http://127.0.0.1:${PORT}/rpc"
export llm_hydraSecret="$SECRET"

cd "$ROOT/f_llm"
cjpm test >/tmp/fllm-conformance.log 2>&1 || true
grep -a 'testRemoteMatchesInProcess' /tmp/fllm-conformance.log | tail -3
grep -a 'Summary: TOTAL' /tmp/fllm-conformance.log | tail -3
if grep -aq 'PASSED.*testRemoteMatchesInProcess' /tmp/fllm-conformance.log; then
  echo 'CONFORMANCE_OK'
  exit 0
fi
echo 'CONFORMANCE_FAILED (see /tmp/fllm-conformance.log)'
exit 1
