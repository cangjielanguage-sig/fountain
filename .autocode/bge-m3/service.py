#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
BGE-M3 三合一向量 HTTP 服务（PyTorch 版）
自动选择硬件：昇腾 NPU -> NVIDIA GPU -> CPU
支持批量文本编码，返回稠密、稀疏、多向量（ColBERT）
"""

"""
开始执行前首先设置环境变量
export HF_HOME=/path/to/models
确保HF_HOME下面存在子目录models--BAAI--bge-m3
"""

import os
import logging
from typing import List, Optional, Dict, Any

import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# FlagEmbedding 是 BGE-M3 官方推荐库
from FlagEmbedding import BGEM3FlagModel

# ---------- 日志配置 ----------
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# ---------- 配置 ----------
MODEL_NAME = "BAAI/bge-m3"                    # Hugging Face 模型 ID
DEFAULT_MAX_LENGTH = 512                     # 默认最大 token 数
USE_FP16 = True                              # 是否使用 FP16 加速（可减少显存）

# ---------- 请求/响应模型 ----------
class EmbedRequest(BaseModel):
    texts: List[str] = Field(..., description="待编码的文本列表，至少一个")
    max_length: Optional[int] = Field(DEFAULT_MAX_LENGTH, description="最大Token数，默认512")

class EmbedResponse(BaseModel):
    dense_vecs: List[List[float]] = Field(..., description="稠密向量，每个文本对应 1024 维")
    sparse_vecs: List[Dict[int, float]] = Field(..., description="稀疏向量，{索引: 权重}")
    colbert_vecs: List[List[List[float]]] = Field(..., description="多向量（ColBERT），每个文本为 [token数 × 1024]")


# ---------- 硬件自动检测 ----------
def get_device() -> str:
    """按优先级返回可用的设备字符串：'npu' -> 'cuda' -> 'cpu'"""
    # 检查昇腾 NPU
    try:
        import torch_npu
        if torch.npu.is_available():
            logger.info("检测到昇腾 NPU，将使用 NPU 加速")
            return "npu"
    except ImportError:
        pass

    # 检查 NVIDIA GPU
    if torch.cuda.is_available():
        logger.info("检测到 NVIDIA GPU，将使用 CUDA 加速")
        return "cuda"

    logger.info("未检测到 GPU/NPU，将使用 CPU")
    return "cpu"


# ---------- 全局加载模型 ----------
device = get_device()
logger.info(f"正在加载 BGE-M3 模型 '{MODEL_NAME}'，设备: {device} ...")
try:
    # BGEM3FlagModel 会自动处理设备，但我们可指定 device 参数
    # 注意：若为 'npu'，需要安装 torch_npu 并导入
    model = BGEM3FlagModel( # 首次执行时会自动安装BGE-M3
        MODEL_NAME,
        use_fp16=USE_FP16,
        device=device           # 支持 'cuda', 'cpu', 'npu'
        # 如需指定设备索引，可使用 device='cuda:0' 或 'npu:0'
    )
    logger.info("模型加载成功")
except Exception as e:
    logger.error(f"模型加载失败: {e}")
    raise


# ---------- 创建 FastAPI 应用 ----------
app = FastAPI(title="BGE-M3 Multi-Vector Embedding Service (PyTorch)", version="1.0")

@app.on_event("startup")
async def startup_event():
    logger.info(f"服务启动完成，使用设备: {device}")

@app.get("/health")
async def health_check():
    return {"status": "ok", "device": device}

@app.post("/embed", response_model=EmbedResponse)
async def embed(request: EmbedRequest):
    """
    接收文本列表，返回三种向量。
    """
    try:
        texts = request.texts
        max_length = request.max_length or DEFAULT_MAX_LENGTH

        if not texts:
            raise HTTPException(status_code=400, detail="texts 不能为空")

        # 调用模型编码，一次性获得三种向量
        output = model.encode(
            texts,
            return_dense=True,
            return_sparse=True,
            return_colbert_vecs=True,
            max_length=max_length,          # 直接控制最大 token 数
            # 还可传入 batch_size 等参数
        )

        # 提取结果（均为 numpy 数组或字典）
        dense_vecs = output['dense_vecs'].tolist()          # shape: (batch, 1024)
        sparse_vecs = output['lexical_weights']             # list of dict {int: float}
        colbert_vecs = output['colbert_vecs'].tolist()      # shape: (batch, seq_len, 1024)

        # 注意：稀疏向量已经是字典列表，可直接 JSON 序列化
        return EmbedResponse(
            dense_vecs=dense_vecs,
            sparse_vecs=sparse_vecs,
            colbert_vecs=colbert_vecs
        )

    except Exception as e:
        logger.exception("推理过程中发生错误")
        raise HTTPException(status_code=500, detail=str(e))


# ---------- 启动服务 ----------
if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)