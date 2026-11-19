#!/usr/bin/env bash
# =============================================================================
# BGE-M3 向量服务一键部署（Linux / WSL Ubuntu 24.04，CPU 可用，有 GPU 也能跑）
#
# 做的事：
#   1. 系统依赖（python3-venv、curl）与独立 venv（/opt/bge-m3/venv）
#   2. 安装 torch(CPU) + transformers + sentencepiece + fastapi + uvicorn
#   3. 从 ModelScope 下载 BGE-M3 权重（HuggingFace 直连在国内常不可用）
#      含 sparse_linear.pt（官方稀疏头，1×1024 投影）与 colbert_linear.pt（1024×1024）
#   4. 写入 OpenAI 兼容的 /v1/embeddings 服务端（dense + sparse + colbert 三路）
#   5. 注册 systemd 服务并做健康检查
#
# 用法：
#   sudo ./deploy_bge_m3.sh                # 安装或更新（幂等，可重复执行）
#   sudo ./deploy_bge_m3.sh status         # 看服务/模型/端口状态
#   sudo ./deploy_bge_m3.sh restart        # 重启服务
#   sudo ./deploy_bge_m3.sh smoke          # 打一发 embedding 自检
#   sudo ./deploy_bge_m3.sh uninstall      # 停服务、删 unit（保留模型）
#   sudo ./deploy_bge_m3.sh uninstall --purge   # 连 /opt/bge-m3 一起删
#
# 可覆盖的环境变量（写在命令前即可）：
#   BGE_HOME=/opt/bge-m3        安装根目录（venv / model / server.py 都在这）
#   BGE_PORT=8000               监听端口
#   BGE_THREADS=8               torch 线程数（默认取物理核的一半，最多 8）
#   BGE_PIP_INDEX=...           pip 主源，默认清华镜像
#   BGE_PIP_EXTRA=             额外 pip 源（默认空）
#   BGE_MODEL_BASE=...          权重源，默认 ModelScope 的 BAAI/bge-m3
#   BGE_FORCE_DOWNLOAD=1        忽略本地已有文件，强制重下
#
# 为什么不用 ollama：ollama.com 的二进制实际重定向到 GitHub Releases，
# 在受限网络里只有 ~0.1 MB/s；ModelScope 走的是国内 CDN，实测 3~5 MB/s。
# =============================================================================

set -euo pipefail

BGE_HOME="${BGE_HOME:-/opt/bge-m3}"
BGE_PORT="${BGE_PORT:-8000}"
BGE_THREADS="${BGE_THREADS:-8}"
BGE_PIP_INDEX="${BGE_PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
BGE_PIP_EXTRA="${BGE_PIP_EXTRA:-}"
BGE_MODEL_BASE="${BGE_MODEL_BASE:-https://modelscope.cn/models/BAAI/bge-m3/resolve/master}"
BGE_FORCE_DOWNLOAD="${BGE_FORCE_DOWNLOAD:-0}"

VENV="$BGE_HOME/venv"
MODEL_DIR="$BGE_HOME/model"
SERVICE=bge-m3
UNIT="/etc/systemd/system/${SERVICE}.service"
PY="$VENV/bin/python"

# 权重文件名与期望字节数（用来判断“已经下好了”，避免重复下载 2.2GB）
FILES="config.json sentence_bert_config.json tokenizer_config.json special_tokens_map.json sentencepiece.bpe.model tokenizer.json sparse_linear.pt colbert_linear.pt"
declare -A EXPECTED=(
  [config.json]=687
  [sentence_bert_config.json]=54
  [tokenizer_config.json]=444
  [special_tokens_map.json]=964
  [sentencepiece.bpe.model]=5069051
  [tokenizer.json]=17098108
  [pytorch_model.bin]=2271145830
  # 官方稀疏头：只有 (1,1024)+bias，所以仅 3.5KB（不是词表大小的矩阵）
  [sparse_linear.pt]=3516
  # 官方 colbert 投影：1024×1024 fp16
  [colbert_linear.pt]=2100674
)

log()  { printf '\033[36m[bge-m3]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[bge-m3]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[bge-m3]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo $0 $*"
}

pip_install() {
  local args=(-q --no-cache-dir -i "$BGE_PIP_INDEX")
  if [ -n "$BGE_PIP_EXTRA" ]; then
    args+=(--extra-index-url "$BGE_PIP_EXTRA")
  fi
  "$VENV/bin/pip" install "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# 1. 系统依赖 + venv
# ---------------------------------------------------------------------------
install_runtime() {
  log "系统依赖：python3-venv / curl"
  if ! dpkg -s python3-venv >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3-venv curl >/dev/null
  fi

  mkdir -p "$BGE_HOME" "$MODEL_DIR"

  if [ ! -x "$PY" ]; then
    log "创建 venv：$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q -U pip
  else
    log "复用已有 venv：$VENV"
  fi
}

# ---------------------------------------------------------------------------
# 2. Python 依赖
# ---------------------------------------------------------------------------
install_deps() {
  log "torch（CPU wheel）"
  if ! "$PY" -c 'import torch' >/dev/null 2>&1; then
    # CPU 轮子约 200MB；默认 PyPI 的 torch 会拖一堆 CUDA 依赖，这里走官方 CPU 源
    if ! pip_install --index-url https://download.pytorch.org/whl/cpu torch; then
      warn "CPU 源失败，回退到主源安装 torch（体积会大很多）"
      pip_install torch
    fi
  else
    log "torch 已存在：$("$PY" -c 'import torch; print(torch.__version__)')"
  fi

  log "transformers / fastapi / uvicorn / sentencepiece"
  if ! "$PY" -c 'import transformers, fastapi, uvicorn, sentencepiece' >/dev/null 2>&1; then
    pip_install transformers sentencepiece fastapi uvicorn
  fi
  log "版本：$("$PY" - <<'PY'
import torch, transformers, fastapi
print(f"torch {torch.__version__} / transformers {transformers.__version__} / fastapi {fastapi.__version__}")
PY
)"
}

# ---------------------------------------------------------------------------
# 3. 权重（ModelScope，按字节数判断是否需要下载）
# ---------------------------------------------------------------------------
human_size() {
  local bytes="$1"
  if [ "$bytes" -ge 1048576 ]; then
    echo "$((bytes / 1048576))MB"
  elif [ "$bytes" -ge 1024 ]; then
    echo "$((bytes / 1024))KB"
  else
    echo "${bytes}B"
  fi
}

fetch_file() {
  local name="$1" url="$2" want="$3" path="$MODEL_DIR/$1"
  local have=0
  [ -f "$path" ] && have=$(stat -c %s "$path")
  if [ "$BGE_FORCE_DOWNLOAD" != "1" ] && [ "$have" = "$want" ]; then
    log "跳过（已完整）：$name ($(human_size "$want"))"
    return 0
  fi
  log "下载 $name（期望 $(human_size "$want")，当前 $(human_size "$have")）"
  curl -fL --retry 3 --retry-delay 3 -C - -m 7200 -o "$path" "$url" \
    || die "下载失败：$url（可重跑本脚本续传）"
  have=$(stat -c %s "$path")
  [ "$have" = "$want" ] || warn "$name 大小不符：$have != $want（可能是源已更新，继续）"
}

install_model() {
  log "权重目录：$MODEL_DIR（源：$BGE_MODEL_BASE）"
  local f
  for f in $FILES; do
    fetch_file "$f" "$BGE_MODEL_BASE/$f" "${EXPECTED[$f]}"
  done
  fetch_file "pytorch_model.bin" "$BGE_MODEL_BASE/pytorch_model.bin" "${EXPECTED[pytorch_model.bin]}"
  # 小文件若被上游改过，大小不符会在上面 warn；这里只保证关键文件存在
  [ -f "$MODEL_DIR/pytorch_model.bin" ] || die "缺少 pytorch_model.bin"
}

# ---------------------------------------------------------------------------
# 4. 服务端代码
# ---------------------------------------------------------------------------
write_server() {
  log "写入服务端：$BGE_HOME/server.py"
  cat > "$BGE_HOME/server.py" <<'PY'
"""BGE-M3 embedding HTTP 服务（OpenAI /v1/embeddings 兼容，三路输出）。

- dense：CLS（last_hidden_state[:,0]）+ L2 归一化，1024 维
- sparse：官方 sparse_linear.pt（Linear(hidden→1) + ReLU），按 token id 取同 id 最大权重
  与 FlagEmbedding `BGEM3FlagModel._process_token_weights` 一致；
  该文件仅 3.5KB，是 (1,1024) 的投影向量，不是词表大小的矩阵
- colbert：官方 colbert_linear.pt（1024→1024）投影后按 token L2 归一化，最多 96 个
"""

import torch
from fastapi import FastAPI
from pydantic import BaseModel
from transformers import AutoModel, AutoTokenizer

MODEL_DIR = "/opt/bge-m3/model"
MAX_LENGTH = 8192
MAX_COLBERT_TOKENS = 96

app = FastAPI(title="bge-m3", version="1.2")
tokenizer = AutoTokenizer.from_pretrained(MODEL_DIR)
model = AutoModel.from_pretrained(MODEL_DIR)
model.eval()

_sparse = torch.load(f"{MODEL_DIR}/sparse_linear.pt", map_location="cpu")
SPARSE_W = _sparse["weight"].to(torch.float32).squeeze(0)
SPARSE_B = _sparse["bias"].to(torch.float32).squeeze(0)

_colbert = torch.load(f"{MODEL_DIR}/colbert_linear.pt", map_location="cpu")
COLBERT_W = _colbert["weight"].to(torch.float32)
COLBERT_B = _colbert["bias"].to(torch.float32)

SPECIAL_IDS = set(tokenizer.all_special_ids)


class EmbedRequest(BaseModel):
    input: list[str] | str
    model: str | None = None
    return_sparse: bool = False
    return_colbert_vecs: bool = False


@app.get("/health")
def health():
    return {"status": "ok", "model": "bge-m3", "dim": 1024,
            "sparse": "official-sparse-head", "colbert": True}


@app.post("/v1/embeddings")
def embeddings(req: EmbedRequest):
    texts = req.input if isinstance(req.input, list) else [req.input]
    if not texts:
        return {"object": "list", "model": "bge-m3", "data": [],
                "usage": {"prompt_tokens": 0, "total_tokens": 0}}

    encoded = tokenizer(texts, padding=True, truncation=True,
                        max_length=MAX_LENGTH, return_tensors="pt")
    with torch.no_grad():
        hidden = model(**encoded).last_hidden_state
        dense = torch.nn.functional.normalize(hidden[:, 0], p=2, dim=1)

    data = []
    for i in range(len(texts)):
        item = {"object": "embedding", "index": i, "embedding": dense[i].tolist()}
        mask = encoded["attention_mask"][i].bool()
        ids = encoded["input_ids"][i][mask].tolist()

        if req.return_sparse:
            scores = torch.relu(hidden[i] @ SPARSE_W + SPARSE_B).tolist()
            weights: dict[str, float] = {}
            for pos, token_id in enumerate(ids):
                if token_id in SPECIAL_IDS:
                    continue
                value = float(scores[pos])
                if value <= 0:
                    continue
                key = str(int(token_id))
                if value > weights.get(key, 0.0):
                    weights[key] = value
            item["lexical_weights"] = weights

        if req.return_colbert_vecs:
            projected = hidden[i][mask] @ COLBERT_W.t() + COLBERT_B
            projected = projected[:MAX_COLBERT_TOKENS]
            projected = torch.nn.functional.normalize(projected, p=2, dim=1)
            item["colbert_vecs"] = projected.tolist()

        data.append(item)

    tokens = int(encoded["attention_mask"].sum())
    return {"object": "list", "model": "bge-m3", "data": data,
            "usage": {"prompt_tokens": tokens, "total_tokens": tokens}}
PY
  # MODEL_DIR 由部署脚本注入，避免服务端写死路径与 BGE_HOME 不一致
  sed -i "s#^MODEL_DIR = .*#MODEL_DIR = \"$MODEL_DIR\"#" "$BGE_HOME/server.py"
}

# ---------------------------------------------------------------------------
# 5. systemd
# ---------------------------------------------------------------------------
write_unit() {
  log "写入 systemd 单元：$UNIT"
  cat > "$UNIT" <<UNIT
[Unit]
Description=BGE-M3 embedding HTTP service (OpenAI compatible)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BGE_HOME
Environment=OMP_NUM_THREADS=$BGE_THREADS
Environment=HF_HUB_OFFLINE=1
Environment=TRANSFORMERS_OFFLINE=1
ExecStart=$VENV/bin/uvicorn server:app --host 0.0.0.0 --port $BGE_PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || warn "enable 失败（可能没有 systemd）"
}

start_service() {
  if ! systemctl restart "$SERVICE" 2>/dev/null; then
    warn "systemd 启动失败，回退到 nohup 方式"
    pkill -f 'uvicorn server:app' 2>/dev/null || true
    ( cd "$BGE_HOME" && OMP_NUM_THREADS="$BGE_THREADS" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
      nohup "$VENV/bin/uvicorn" server:app --host 0.0.0.0 --port "$BGE_PORT" \
      > "$BGE_HOME/uvicorn.log" 2>&1 & )
  fi
  wait_healthy
}

wait_healthy() {
  log "等待模型加载（首次约 10~60 秒）"
  local i code
  for i in $(seq 1 80); do
    sleep 3
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$BGE_PORT/health" || echo 000)
    if [ "$code" = "200" ]; then
      log "服务就绪（$((i * 3))s）"
      return 0
    fi
  done
  die "健康检查超时，排查：journalctl -u $SERVICE -n 50 --no-pager"
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
cmd_install() {
  need_root install
  install_runtime
  install_deps
  install_model
  write_server
  write_unit
  start_service
  cmd_smoke
  cat <<SUMMARY

部署完成
  服务：systemctl status $SERVICE
  端口：http://0.0.0.0:$BGE_PORT  （Windows 侧用 http://localhost:$BGE_PORT）
  权重：$MODEL_DIR
  虚拟环境：$VENV
  自检：curl -s http://localhost:$BGE_PORT/health
SUMMARY
}

cmd_smoke() {
  need_root smoke
  log "自检：POST /v1/embeddings（dense + sparse + colbert）"
  "$PY" - "$BGE_PORT" <<'PY'
import json, sys, urllib.request

port = sys.argv[1]
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/embeddings",
    data=json.dumps({
        "input": ["猫坐在垫子上", "小狗在草地上跑"],
        "return_sparse": True,
        "return_colbert_vecs": True,
    }).encode(),
    headers={"Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=180) as resp:
    payload = json.load(resp)
vectors = [d["embedding"] for d in payload["data"]]
sparse = [len(d.get("lexical_weights", {})) for d in payload["data"]]
colbert = [len(d.get("colbert_vecs", [])) for d in payload["data"]]
print(f"  model={payload['model']} count={len(vectors)} dim={len(vectors[0])} "
      f"tokens={payload['usage']['total_tokens']}")
print(f"  sparse tokens={sparse} colbert tokens={colbert}")
if sparse[0] == 0 or colbert[0] == 0:
    raise SystemExit("sparse/colbert 为空：检查 sparse_linear.pt / colbert_linear.pt 是否就位")
PY
}

cmd_status() {
  need_root status
  echo "服务：$(systemctl is-enabled "$SERVICE" 2>/dev/null || echo '-') / $(systemctl is-active "$SERVICE" 2>/dev/null || echo '-')"
  echo "端口：$(ss -ltn 2>/dev/null | grep ":$BGE_PORT " || echo '未监听')"
  echo "健康：$(curl -s -m 5 "http://127.0.0.1:$BGE_PORT/health" || echo '不可用')"
  echo "权重：$(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)  venv：$(du -sh "$VENV" 2>/dev/null | cut -f1)"
  ps -C uvicorn -o pid=,rss=,etime= 2>/dev/null | while read -r pid rss etime; do
    echo "进程：pid=$pid rss=$((rss / 1024))MB uptime=$etime"
  done
}

cmd_restart() {
  need_root restart
  systemctl restart "$SERVICE" || die "重启失败：journalctl -u $SERVICE -n 50"
  wait_healthy
  cmd_smoke
}

cmd_uninstall() {
  need_root uninstall
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload 2>/dev/null || true
  pkill -f 'uvicorn server:app' 2>/dev/null || true
  log "服务与 unit 已移除"
  if [ "${1:-}" = "--purge" ]; then
    rm -rf "$BGE_HOME"
    log "已删除 $BGE_HOME（含 2.2GB 权重）"
  else
    log "保留 $BGE_HOME；彻底清理请加 --purge"
  fi
}

case "${1:-install}" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  restart)   cmd_restart ;;
  smoke)     cmd_smoke ;;
  uninstall) shift || true; cmd_uninstall "${1:-}" ;;
  *)         die "未知子命令：$1（可用：install / status / restart / smoke / uninstall [--purge]）" ;;
esac
