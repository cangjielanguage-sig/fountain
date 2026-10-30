#!/usr/bin/env bash
# fmq 三节点端到端验证：发布/订阅、组内不重复、autoAck、单节点停机、超时重投与死信、
# 延迟投递、1MB 大记录、备份目录/位点落盘、stats 查询、删除主题/组、SIGTERM 优雅退出。
# 成功输出 E2E_OK；失败逐项列出。

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/fmq_e2e.XXXXXX)
P1=23610
P2=23611
P3=23612
NODES="127.0.0.1:${P1},127.0.0.1:${P2},127.0.0.1:${P3}"
# 【必填】本机在集群内的唯一主机号：MessageID 拒绝 hostId=0。
# 三个节点都在同一台机器上跑，沿用同一个值不会影响隔离（各自的节点下标由端口决定）。
export protocol_hostId="${protocol_hostId:-1}"

FAILS=()
PIDS=()

fail() { FAILS+=("$1"); }
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "  [PASS] ${name}"
  else
    echo "  [FAIL] ${name}"
    fail "$name"
  fi
}

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

lib_path() {
  # 各模块的动态库都放在 target/release/<name>@<org>/ 下
  find "$1" -maxdepth 3 -type d -name '*@*' 2>/dev/null | tr '\n' ':'
}

# 死信件数：段文件在 Linux 下会预分配到 maxFileSize，不能按文件大小判断；
# 读第一条记录的长度头（4 字节大端），非 0 表示段内确有死信条目。
dead_entry_count() {
  local count=0
  local f head
  while IFS= read -r f; do
    head=$(od -An -tx1 -N4 "${f}" 2>/dev/null | tr -d ' \n')
    if [ -n "${head}" ] && [ "${head}" != "00000000" ]; then
      count=$((count + 1))
    fi
  done < <(find "${TMP}" -path '*/dead/log_*.log' -type f 2>/dev/null)
  echo "${count}"
}

echo "==> 构建 f_mq / fmq / e2e client"
(cd "${ROOT}/f_mq" && cjpm build >"${TMP}/build_f_mq.log" 2>&1) || { echo "f_mq build failed"; tail -20 "${TMP}/build_f_mq.log"; exit 1; }
(cd "${ROOT}/fmq" && cjpm build >"${TMP}/build_fmq.log" 2>&1) || { echo "fmq build failed"; tail -20 "${TMP}/build_fmq.log"; exit 1; }
(cd "${ROOT}/scripts/mq_e2e_client" && cjpm build >"${TMP}/build_client.log" 2>&1) || { echo "client build failed"; tail -20 "${TMP}/build_client.log"; exit 1; }

# 打包边界（R5-3/C1）：测试替身不得进入生产产物
check "f_mq 动态库不含 MQStubServer 符号" \
  bash -c "! nm -D '${ROOT}/f_mq/target/release/f_mq@fountain/libf_mq@fountain.so' | grep -q MQStubServer"
check "fmq 主程序不链接 TestDirs" \
  bash -c "! nm '${ROOT}/fmq/target/release/bin/main' | grep -q TestDirs"
check "fmq 主程序不含 TestDirs 字样" \
  bash -c "! strings '${ROOT}/fmq/target/release/bin/main' | grep -q TestDirs"

FMQ_DIR="${ROOT}/fmq/target/release"
CLIENT_DIR="${ROOT}/scripts/mq_e2e_client/target/release"
export LD_LIBRARY_PATH="$(lib_path "${FMQ_DIR}")$(lib_path "${CLIENT_DIR}")${LD_LIBRARY_PATH:-}"
FMQ_BIN_ORIG="${FMQ_DIR}/bin/main"
CLIENT_BIN="${CLIENT_DIR}/bin/main"
[ -x "${FMQ_BIN_ORIG}" ] || { echo "fmq binary not found at ${FMQ_BIN_ORIG}"; exit 1; }
[ -x "${CLIENT_BIN}" ] || { echo "client binary not found at ${CLIENT_BIN}"; exit 1; }

start_node() {
  local index="$1"
  local port="$2"
  local dir="${TMP}/n${index}"
  mkdir -p "${dir}"
  # 复制可执行文件：metas 目录由「可执行文件所在目录」推导，必须每节点独立
  cp "${FMQ_BIN_ORIG}" "${dir}/fmq"
  local backup=1
  env \
    mqClient_hosts="${NODES}" \
    mqServer_port="${port}" \
    mqServer_ackTimeout=2s \
    mqServer_deadMsgThreshold=2 \
    mqServer_deadMsgTTL=1h \
    mqServer_segmentedLogDir="${dir}/logs" \
    mqServer_deadMsgDir="${dir}/dead" \
    mqServer_segmentedLogMaxSize=8M \
    mqServer_segmentedLogTTL=1h \
    mqServer_backup="${backup}" \
    "${dir}/fmq" server >"${dir}/server.log" 2>&1 &
  local pid=$!
  PIDS+=("${pid}")
  echo "${pid}" > "${dir}/pid"
}

manager() {
  env mqClient_hosts="${NODES}" mqServer_port="${P1}" "${FMQ_BIN_ORIG}" manager --server="127.0.0.1:${P1}" "$@"
}

client() {
  env mqClient_hosts="${NODES}" "${CLIENT_BIN}" "$@"
}

wait_one() {
  local port="$1"
  local tries=0
  while [ "${tries}" -lt 300 ]; do
    if env mqClient_hosts="${NODES}" mqServer_port="${port}" "${FMQ_BIN_ORIG}" manager \
      --server="127.0.0.1:${port}" listTopics >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

wait_ready() {
  wait_one "${P1}" && wait_one "${P2}" && wait_one "${P3}"
}

echo "==> 启动 3 个节点（备份副本 = 1）"
start_node 1 "${P1}"
start_node 2 "${P2}"
start_node 3 "${P3}"
check "服务端就绪" wait_ready

echo "==> 注册主题与订阅组"
check "注册 /e2e 4 队列" manager registerTopic /e2e 4
check "注册 grp1" manager registerSubscriber /e2e grp1
check "注册 grp2" manager registerSubscriber /e2e grp2

echo "==> 发布 100 条"
START_NS=$(date +%s%N)
PUB_OUT=$(client publish "${NODES}" /e2e 100 2>&1)
PUB_RC=$?
PUB_END=$(date +%s%N)
PUBLISH_COUNT=$(echo "${PUB_OUT}" | grep -c '^PUBLISHED' || true)
check "发布 100 条" [ "${PUB_RC}" -eq 0 ] && check "发布条数 = 100" [ "${PUBLISH_COUNT}" -eq 100 ]

echo "==> grp1 消费并 ack 100 条"
CON_OUT=$(client consume "${NODES}" /e2e grp1 100 2>&1)
CON_RC=$?
if [ "${CON_RC}" -ne 0 ]; then echo "--- grp1 output ---"; echo "${CON_OUT}" | head -20; fi
CON_END=$(date +%s%N)
CON_COUNT=$(echo "${CON_OUT}" | grep -c '^CONSUMED' || true)
UNIQ_COUNT=$(echo "${CON_OUT}" | grep '^CONSUMED' | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
# 位置只在单个队列内唯一（每个队列的 SegmentedLog 都从 1:0 开始），
# 必须带上 queueIndex 才能全局唯一；同时断言确实出现了跨队列同位置，证明 ACK 串台风险被覆盖。
UNIQ_POS=$(echo "${CON_OUT}" | grep '^CONSUMED' | awk '{print $3}' | sort -u | wc -l | tr -d ' ')
DUP_POS=$(echo "${CON_OUT}" | grep '^CONSUMED' | awk '{print $3}' | cut -d: -f2- | sort | uniq -d | wc -l | tr -d ' ')
check "grp1 消费 100 条" [ "${CON_RC}" -eq 0 ] && check "grp1 条数 = 100" [ "${CON_COUNT}" -eq 100 ]
check "100 条不重（消息 id 唯一）" [ "${UNIQ_COUNT}" -eq 100 ]
check "100 条位置（队列+段+偏移）唯一" [ "${UNIQ_POS}" -eq 100 ]
check "存在跨队列同位置场景" [ "${DUP_POS}" -ge 1 ]

echo "==> grp1 全部 ACK 后不应重复投递"
# ackTimeout=2s：等待超过重投窗口，确认没有 ACK 落错队列导致的重复投递
sleep 3
REPLAY_OUT=$(timeout 3 env mqClient_hosts="${NODES}" "${CLIENT_BIN}" consume "${NODES}" /e2e grp1 1 2>&1 || true)
REPLAY_COUNT=$(echo "${REPLAY_OUT}" | grep -c '^CONSUMED' || true)
check "ACK 后无重复投递" [ "${REPLAY_COUNT}" -eq 0 ]

echo "==> grp2 以 autoAck 消费 100 条"
AUTO_OUT=$(client consume "${NODES}" /e2e grp2 100 auto 2>&1)
AUTO_RC=$?
if [ "${AUTO_RC}" -ne 0 ]; then echo "--- grp2 output ---"; echo "${AUTO_OUT}" | head -20; fi
AUTO_COUNT=$(echo "${AUTO_OUT}" | grep -c '^CONSUMED' || true)
AUTO_UNIQ=$(echo "${AUTO_OUT}" | grep '^CONSUMED' | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
check "autoAck 组消费 100 条" [ "${AUTO_RC}" -eq 0 ] && check "autoAck 条数 = 100" [ "${AUTO_COUNT}" -eq 100 ]
check "autoAck 组无重复" [ "${AUTO_UNIQ}" -eq 100 ]

echo "==> 停掉一个节点后继续发布/消费"
kill "$(cat "${TMP}/n3/pid")" 2>/dev/null || true
sleep 1
PUB2_OUT=$(client publish "${NODES}" /e2e 10 2>&1)
PUB2_RC=$?
PUB2_COUNT=$(echo "${PUB2_OUT}" | grep -c '^PUBLISHED' || true)
CON2_OUT=$(client consume "${NODES}" /e2e grp1 10 2>&1)
CON2_RC=$?
if [ "${CON2_RC}" -ne 0 ]; then echo "--- grp1 after stop output ---"; echo "${CON2_OUT}" | head -20; fi
CON2_COUNT=$(echo "${CON2_OUT}" | grep -c '^CONSUMED' || true)
check "停机后仍可发布" [ "${PUB2_RC}" -eq 0 ] && check "停机后发布 10 条" [ "${PUB2_COUNT}" -eq 10 ]
check "停机后仍可消费" [ "${CON2_RC}" -eq 0 ] && check "停机后消费 10 条" [ "${CON2_COUNT}" -eq 10 ]

echo "==> 超时重投与死信"
manager registerSubscriber /e2e grp3 >/dev/null 2>&1
client publish "${NODES}" /e2e 1 >/dev/null 2>&1
# deadMsgThreshold=2 表示「重试 2 次」：共 3 次投递，第 4 次扫描才进死信。
# 每次 consume 之间 sleep 2.5s（ackTimeout=2s）；第 4 次消费会写死信后继续轮询，
# 由 timeout 收尾（留足 30s，避免杀掉仍在推进的客户端导致 buffered 输出丢失）。
REDELIVER_OUT=$(timeout 40 env mqClient_hosts="${NODES}" "${CLIENT_BIN}" redeliver "${NODES}" /e2e grp3 4 2>&1)
REDELIVER_COUNT=$(echo "${REDELIVER_OUT}" | grep -c '^CONSUMED' || true)
check "重投次数 >= 2" [ "${REDELIVER_COUNT}" -ge 2 ]
DEAD_COUNT=$(dead_entry_count)
check "死信条目 >= 1" [ "${DEAD_COUNT}" -ge 1 ]

echo "==> 延迟投递（delaying=3s）"
manager registerTopic /delay 1 delaying=3s >/dev/null 2>&1
manager registerSubscriber /delay dgroup >/dev/null 2>&1
client publish "${NODES}" /delay 1 >/dev/null 2>&1
DELAY_START=$(date +%s%N)
DELAY_OUT=$(timeout 30 env mqClient_hosts="${NODES}" "${CLIENT_BIN}" consume-one "${NODES}" /delay dgroup 2>&1)
DELAY_RC=$?
DELAY_END=$(date +%s%N)
DELAY_MS=$(( (DELAY_END - DELAY_START) / 1000000 ))
DELAY_COUNT=$(echo "${DELAY_OUT}" | grep -c '^CONSUMED' || true)
check "延迟消息可投递" [ "${DELAY_RC}" -eq 0 ] && check "延迟消息条数 = 1" [ "${DELAY_COUNT}" -eq 1 ]
check "延迟至少 2.5s" [ "${DELAY_MS}" -ge 2500 ]

PUB_SECONDS=$(( (PUB_END - START_NS) / 1000000 ))
CON_SECONDS=$(( (CON_END - START_NS) / 1000000 ))
echo "==> 指标：发布 100 条 ${PUB_SECONDS}ms；消费 100 条 ${CON_SECONDS}ms；重投 ${REDELIVER_COUNT} 次；死信段 ${DEAD_COUNT}"

echo "==> 大消息（1MB，跨越对象载荷的 4KB 阈值）"
# 4 队列：此时节点 3 已停机，必须保证存活节点持有队列
manager registerTopic /big 4 >/dev/null 2>&1
manager registerSubscriber /big bgroup >/dev/null 2>&1
BIG_OUT=$(timeout 60 env mqClient_hosts="${NODES}" "${CLIENT_BIN}" big "${NODES}" /big bgroup 1048576 2>&1)
BIG_RC=$?
BIG_LEN=$(echo "${BIG_OUT}" | grep '^BIG' | awk '{print $2}' | head -1)
if [ "${BIG_RC}" -ne 0 ]; then echo "--- big output ---"; echo "${BIG_OUT}" | head -10; fi
check "1MB 消息往返" [ "${BIG_RC}" -eq 0 ]
check "1MB 长度 = 1048576" [ "${BIG_LEN:-0}" = "1048576" ]

echo "==> 备份目录与真实位点落盘"
# 段回收本身由 BackupStore_test.cleanerReclaimsBackupSegmentsByCursor（按位点 + TTL）覆盖；
# 这里验证端到端确实按 <owner>/<topic>/<queue>/cursors 布局落盘，否则清理器没有边界可用。
BACKUP_FILES=$(find "${TMP}" -path '*/logs/backup/*' -name 'log_*.log' -type f 2>/dev/null | wc -l | tr -d ' ')
check "备份段已落盘" [ "${BACKUP_FILES}" -ge 1 ]
# 位点是 A26 的关键：没有 cursors 目录说明接收端仍只存记录、恢复会重放
CURSOR_FILES=$(find "${TMP}" -path '*/logs/backup/*/cursors/*.cursor' -type f 2>/dev/null | wc -l | tr -d ' ')
check "备份位点已落盘" [ "${CURSOR_FILES}" -ge 1 ]

echo "==> stats 查询"
STATS_OUT=$(manager stats /e2e 2>&1)
STATS_RC=$?
check "stats 可查询" [ "${STATS_RC}" -eq 0 ]
echo "${STATS_OUT}" | grep -q 'backlog' && HAS_BACKLOG=0 || HAS_BACKLOG=1
check "stats 含 backlog 列" [ "${HAS_BACKLOG}" -eq 0 ]
echo "${STATS_OUT}" | grep -q 'deadLettered' && HAS_DEAD=0 || HAS_DEAD=1
check "stats 含 deadLettered 列" [ "${HAS_DEAD}" -eq 0 ]

echo "==> 删除订阅组与主题"
check "删除 grp2" manager deleteSubscribeGroup /e2e grp2
check "删除 /delay" manager deleteTopic /delay
# 删除后订阅必须失败（不能静默成功）
if timeout 5 env mqClient_hosts="${NODES}" "${CLIENT_BIN}" consume-one "${NODES}" /delay dgroup >/dev/null 2>&1; then
  DELETED_GUARD=1
else
  DELETED_GUARD=0
fi
check "删除后订阅失败" [ "${DELETED_GUARD}" -eq 0 ]

echo "==> SIGTERM 优雅退出"
for i in 1 2 3; do
  pid=$(cat "${TMP}/n${i}/pid" 2>/dev/null || true)
  if [ -n "${pid}" ]; then kill -TERM "${pid}" 2>/dev/null || true; fi
done
sleep 2
for i in 1 2 3; do
  pid=$(cat "${TMP}/n${i}/pid" 2>/dev/null || true)
  if [ -z "${pid}" ]; then
    check "节点${i} 退出码 = 0" false
    continue
  fi
  wait "${pid}" 2>/dev/null
  rc=$?
  check "节点${i} 退出码 = 0" [ "${rc}" -eq 0 ]
done
# 关闭流程包含 BackupReplicator.close（drain）与 QueueLog.sync：位点文件必须仍在
FINAL_CURSORS=$(find "${TMP}" -path '*/logs/backup/*/cursors/*.cursor' -type f 2>/dev/null | wc -l | tr -d ' ')
check "关闭后备份位点仍落盘" [ "${FINAL_CURSORS}" -ge 1 ]

if [ "${#FAILS[@]}" -gt 0 ]; then
  echo "E2E_FAILED"
  for item in "${FAILS[@]}"; do
    echo "  - ${item}"
  done
  exit 1
fi

echo "E2E_OK"
