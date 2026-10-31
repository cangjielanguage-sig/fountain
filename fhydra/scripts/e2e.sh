#!/usr/bin/env bash
source /mnt/d/docs/work/cangjie/cangjie.sh >/dev/null 2>&1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export CANGJIE_STDX_PATH="$CANGJIE_STDX_DYNAMIC_PATH"
export LD_LIBRARY_PATH="$(find "$ROOT/target" -name 'lib*.so' -printf '%h\n' 2>/dev/null | sort -u | tr '\n' ':')${LD_LIBRARY_PATH}"
export mvc_port=18081
export hydra_secret=test-secret
export hydra_dataPath=/tmp/fhydra-e2e
rm -rf /tmp/fhydra-e2e

"$ROOT/target/release/bin/main" >/tmp/fhydra-run.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT

for i in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:${mvc_port}/rpc"; then break; fi
  sleep 0.5
done

echo "--- no key ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"hydra.health","params":{}}' \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- with key ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'X-Hydra-Key: test-secret' \
  -d '{"jsonrpc":"2.0","id":2,"method":"hydra.health","params":{}}' \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- protected method without key ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":20,"method":"hydra.count","params":{"param":{"collection":"c"}}}' \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
B64=$(python3 -c "import base64,struct;print(base64.b64encode(struct.pack('<2f',1.0,0.0)).decode())")
echo "--- upsert (denseB64=$B64) ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'X-Hydra-Key: test-secret' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"hydra.upsert\",\"params\":{\"param\":{\"collection\":\"c\",\"id\":\"r1\",\"payload\":\"p1\",\"denseB64\":\"$B64\",\"kind\":\"note\",\"titleDense\":[1,0],\"contentDense\":[0,1],\"saveTime\":123}}}" \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- searchDense ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'X-Hydra-Key: test-secret' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"hydra.searchDense\",\"params\":{\"param\":{\"collection\":\"c\",\"denseB64\":\"$B64\",\"limit\":5,\"kind\":\"note\"}}}" \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- count ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'X-Hydra-Key: test-secret' \
  -d '{"jsonrpc":"2.0","id":5,"method":"hydra.count","params":{"param":{"collection":"c"}}}' \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- get ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'X-Hydra-Key: test-secret' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"hydra.get\",\"params\":{\"param\":{\"collection\":\"c\",\"id\":\"r1\"}}}" \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- ids ---"
curl -s -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -H 'X-Hydra-Key: test-secret' \
  -d '{"jsonrpc":"2.0","id":7,"method":"hydra.ids","params":{"param":{"collection":"c","offset":0,"limit":10}}}' \
  "http://127.0.0.1:${mvc_port}/rpc"
echo
echo "--- server log tail ---"
tail -5 /tmp/fhydra-run.log
