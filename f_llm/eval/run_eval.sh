#!/usr/bin/env bash
# 真实 embedding 的检索评测入口。
#
# 用法：
#   eval/run_eval.sh                     # 默认 bge-m3，地址 http://127.0.0.1:8000/v1/embeddings
#   llm_embeddingUrl=http://host/v1/embeddings fllm_evalModel=bge-m3 eval/run_eval.sh
#
# 前提：本机（或指定地址）有 OpenAI 兼容的 /v1/embeddings 服务。
set -e

here="$(cd "$(dirname "$0")" && pwd)"
module="$(dirname "$here")"

export fllm_runEval=1
export fllm_evalDir="${fllm_evalDir:-$here}"
export fllm_evalModel="${fllm_evalModel:-bge-m3}"
export llm_embeddingUrl="${llm_embeddingUrl:-http://127.0.0.1:8000/v1/embeddings}"

cd "$module"
echo "eval dir: $fllm_evalDir"
echo "encoder : $fllm_evalModel @ $llm_embeddingUrl"
cjpm test --filter=RetrievalEvalManual_test
