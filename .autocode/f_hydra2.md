f_hydra 跨平台统一推理接口设计
1. 设计目标
f_hydra 作为仓颉语言实现的混合检索引擎，需要在 Linux、HarmonyOS、Windows、macOS 等多种操作系统上，统一访问 BGE-M3 嵌入模型，并充分利用各类硬件加速器（CPU、NVIDIA/AMD/Intel GPU、NPU、TPU 等）。本文档定义一套平台无关的仓颉接口（BgeBackend），并重点给出 HarmonyOS（基于 MindSpore Lite） 与 Linux（基于 ONNX Runtime） 的完整技术方案。Windows 与 macOS 可依相同模式扩展。

核心原则：

接口统一：上层混合检索逻辑仅依赖 BgeBackend 接口，不感知具体后端。

后端可替换：通过工厂模式根据平台与硬件配置自动选择最优实现。

最小依赖：每个平台仅引入必需的推理库，通过仓颉 FFI 与 Native 动态库交互。

2. 统一仓颉接口定义
所有后端必须实现以下接口：

```cj
// f_hydra/src/bge_backend.cj

// 嵌入输出结构体
struct BgeOutput {
    denseVec: Array<Float32>            // 稠密向量 [dim]
    sparseVec: HashMap<Int64, Float32>  // 稀疏向量 {tokenID: weight}
    colbertVecs: Array<Array<Float32>>  // 多向量 [numTokens × dim]
}

// 推理后端统一接口
interface BgeBackend {
    // 对单条文本编码，返回三种向量
    func encode(text: String): BgeOutput

    // 释放后端占用的资源
    func close()
}
```
工厂函数 根据平台和配置创建实例：

```cj
// f_hydra/src/bge_factory.cj

enum BackendType {
    MINDSPORE_LITE   // HarmonyOS
    ONNX_RUNTIME     // Linux/Windows/macOS 通用
    COREML           // macOS 专用（可选）
}

struct BgeConfig {
    let modelPath: String          // 模型文件路径
    let backend: BackendType       // 后端类型
    let device: String             // "cpu", "cuda", "npu", "auto"
    let numThreads: Int64
    // 各后端特有配置可在此扩展
}

func createBgeBackend(config: BgeConfig): BgeBackend {
    match (config.backend) {
        case BackendType.MINDSPORE_LITE => MindSporeBgeBackend(config)
        case BackendType.ONNX_RUNTIME  => OnnxRuntimeBgeBackend(config)
        case BackendType.COREML        => CoreMlBgeBackend(config)
        // ... 可继续扩展
    }
}
```
上层调用示例：

```cj
let backend = createBgeBackend(BgeConfig(
    modelPath = "./models/bge_m3_npu.ms",
    backend = BackendType.MINDSPORE_LITE,
    device = "npu",
    numThreads = 4
))
let output = backend.encode("什么是 BGE-M3？")
// 使用 output.denseVec, output.sparseVec, output.colbertVecs 构建索引
backend.close()
```
3. 平台后端实现概览
| 平台 | 推荐后端 | 加速硬件 | 模型格式 | 仓颉集成方式 |
|:---|:---|:---|:---|:---|
| HarmonyOS | MindSpore Lite | 麒麟 NPU、CPU | .ms | 仓颉 FFI → NAPI 动态库 → libmindspore-lite.so |
| Linux | ONNX Runtime | CPU, NVIDIA GPU (CUDA/TensorRT), AMD GPU (ROCm), Intel GPU (OpenVINO), Google TPU (需额外适配) | .onnx | 仓颉 FFI → ONNX Runtime C API 动态库 (libonnxruntime.so) |
| Windows | ONNX Runtime | CPU, DirectML, CUDA | .onnx | 同上 |
| macOS | ONNX Runtime 或 Core ML | CPU, Apple Neural Engine (通过 CoreML EP) | .onnx / .mlmodel | ONNX Runtime C API 或 Core ML C API |

HarmonyOS 与 Linux 是本文重点，下面详细展开。

4. HarmonyOS 实现方案（MindSpore Lite）
4.1 整体架构
```text
┌─────────────────────────────────────────┐
│ f_hydra (仓颉)                           │
│  MindSporeBgeBackend : BgeBackend        │
│    ↕ FFI (@C foreign)                    │
│ libbge_mindspore.so (NAPI 动态库)        │
│    ↕ C 函数调用                          │
│ libmindspore-lite.so (MindSpore Lite)    │
│    ↕                                    │
│ 麒麟 NPU / CPU                           │
└─────────────────────────────────────────┘
```
4.2 模型转换：PyTorch → ONNX → .ms
导出 ONNX：`optimum-cli export onnx --model BAAI/bge-m3 --task feature-extraction --opset 17 --optimize O2 --device cpu --output ./bge-m3-onnx/`

使用 MindSpore Lite Converter 转换为 .ms，开启 FP16 量化并针对 NPU 优化：

```bash
./converter_lite --fmk=ONNX --modelFile=model.onnx --outputFile=bge_m3_npu --optimize=general --quantType=FP16
```
产出 bge_m3_npu.ms 文件。

4.3 NAPI 适配层封装
创建 HarmonyOS Native 模块 bge_infer，在 bridge.cpp 中提供纯 C 接口：

```cpp
// bge_infer/src/main/cpp/bridge.cpp
#include <mindspore/model.h>
#include <mindspore/context.h>
#include <mindspore/device.h>
#include <vector>
#include <cstring>

extern "C" {

typedef void* InferHandle;

InferHandle BgeCreate(const char* model_path, int num_threads, bool use_npu) {
    auto ctx = MSContextCreate();
    if (use_npu) {
        auto npu_info = MSDeviceInfoCreate(kMSDeviceTypeNPU);
        MSContextAddDeviceInfo(ctx, npu_info);
    }
    auto cpu_info = MSDeviceInfoCreate(kMSDeviceTypeCPU);
    MSContextAddDeviceInfo(ctx, cpu_info);
    MSContextSetThreadNum(ctx, num_threads);

    auto model = MSModelCreate();
    if (MSModelBuildFromFile(model, model_path, kMSModelTypeMindIR, ctx) != kMSStatusSuccess) {
        MSContextDestroy(&ctx);
        return nullptr;
    }
    struct HandleImpl { MSModelHandle model; MSContextHandle context; };
    return new HandleImpl{model, ctx};
}

int BgeInfer(InferHandle handle,
             const int64_t* input_ids, int64_t seq_len,
             const int64_t* attn_mask,
             float* dense_out,      // [dim]
             float* sparse_out,     // [seq_len]
             float* colbert_out,    // [seq_len * dim]
             int64_t dim) {
    auto* h = static_cast<HandleImpl*>(handle);
    // ... 构造输入张量，执行推理，拷贝输出 ... (详见前文)
    return 0;
}

void BgeDestroy(InferHandle handle) {
    auto* h = static_cast<HandleImpl*>(handle);
    MSModelDestroy(&h->model);
    MSContextDestroy(&h->context);
    delete h;
}

} // extern "C"
```
编译产出 libbge_mindspore.so，依赖 libmindspore-lite.so。

4.4 仓颉侧实现 MindSporeBgeBackend
```cj
// f_hydra/src/harmonyos/mindspore_backend.cj
import std.ffi.CPointer
import f_hydra.bge_backend

// 不透明句柄
@C struct InferHandle {}

@C foreign func BgeCreate(modelPath: CString, numThreads: Int32, useNpu: Bool): CPointer<InferHandle>
@C foreign func BgeInfer(handle: CPointer<InferHandle>, inputIds: CPointer<Int64>, seqLen: Int64,
                         attnMask: CPointer<Int64>, denseOut: CPointer<Float32>,
                         sparseOut: CPointer<Float32>, colbertOut: CPointer<Float32>,
                         dim: Int64): Int32
@C foreign func BgeDestroy(handle: CPointer<InferHandle>)

class MindSporeBgeBackend: BgeBackend {
    private let handle: CPointer<InferHandle>
    private let dim: Int64 = 1024
    private let tokenizer: Tokenizer  // 自行实现或 FFI 调用 SentencePiece

    init(config: BgeConfig) {
        this.handle = unsafe { BgeCreate(config.modelPath.toCString(), config.numThreads, config.device == "npu") }
        this.tokenizer = Tokenizer(config.modelPath) // 加载词表
    }

    func encode(text: String): BgeOutput {
        let tokens = tokenizer.tokenize(text)  // 产出 inputIds, attnMask
        let dense = Array<Float32>(dim, 0.0)
        let sparse = Array<Float32>(tokens.seqLen, 0.0)
        let colbert = Array<Float32>(tokens.seqLen * dim, 0.0)

        unsafe {
            BgeInfer(handle, tokens.inputIds.toCPointer(), tokens.seqLen,
                     tokens.attnMask.toCPointer(), dense.toCPointer(),
                     sparse.toCPointer(), colbert.toCPointer(), dim)
        }
        // 解析 sparse 输出为 HashMap，过滤特殊 token
        return BgeOutput(dense, parseSparse(sparse, tokens.inputIds), reshapeColbert(colbert, tokens.seqLen))
    }

    func close() {
        unsafe { BgeDestroy(handle) }
    }
}
```
这样，HarmonyOS 上即可通过 NPU 高效运行 BGE-M3，且对 f_hydra 其他模块完全透明。

5. Linux 实现方案（ONNX Runtime 统一后端）
5.1 为何选择 ONNX Runtime
跨硬件 Execution Provider (EP)：同一套代码，通过切换 EP 即可支持 CPU、CUDA、TensorRT、ROCm、OpenVINO、DirectML 等。

成熟的 C API：仓颉 FFI 可直接调用，无需额外 NAPI 桥接。

模型格式统一：全部使用 ONNX 模型，避免多平台格式碎片化。

5.2 整体架构
```text
┌──────────────────────────────────────────────┐
│ f_hydra (仓颉)                                │
│  OnnxRuntimeBgeBackend : BgeBackend           │
│    ↕ FFI (@C foreign)                         │
│ libonnxruntime.so (ONNX Runtime C API)         │
│    ↕ EP 选择                                   │
│ CPU / CUDA / ROCm / OpenVINO / TensorRT ...    │
└──────────────────────────────────────────────┘
```
5.3 模型准备
导出 BGE-M3 ONNX 模型（与 4.2 相同），得到 model.onnx。无需额外转换。

5.4 仓颉 FFI 声明 ONNX Runtime C API
关键函数声明（完整声明参见前文 BGE-M3 部署指南）：

```cj
// f_hydra/src/linux/onnx_bridge.cj
@C foreign func OrtCreateEnv(logLevel: UInt32, logId: CString, out: CPointer<CPointer<OrtEnv>>): CPointer<OrtStatus>
@C foreign func OrtCreateSession(env: CPointer<OrtEnv>, modelPath: CString,
                                 options: CPointer<OrtSessionOptions>,
                                 out: CPointer<CPointer<OrtSession>>): CPointer<OrtStatus>
@C foreign func OrtSessionOptionsAppendExecutionProvider_CUDA(options: CPointer<OrtSessionOptions>, deviceId: Int32): CPointer<OrtStatus>
@C foreign func OrtSessionOptionsAppendExecutionProvider_ROCm(options: CPointer<OrtSessionOptions>, deviceId: Int32): CPointer<OrtStatus>
@C foreign func OrtSessionOptionsAppendExecutionProvider_OpenVINO(options: CPointer<OrtSessionOptions>, device: CString): CPointer<OrtStatus>
@C foreign func OrtCreateTensorWithDataAsOrtValue(...): CPointer<OrtStatus>
@C foreign func OrtRun(session: CPointer<OrtSession>, ...): CPointer<OrtStatus>
// ... 资源释放函数
```
5.5 实现 OnnxRuntimeBgeBackend
```cj
// f_hydra/src/linux/onnx_backend.cj
class OnnxRuntimeBgeBackend: BgeBackend {
    private let session: CPointer<OrtSession>
    private let env: CPointer<OrtEnv>
    private let dim: Int64 = 1024
    private let tokenizer: Tokenizer

    init(config: BgeConfig) {
        // 1. 创建环境
        this.env = createEnv()
        // 2. 创建会话选项，根据 device 添加对应 EP
        let opts = createSessionOptions()
        match (config.device) {
            case "cuda"  => appendCUDA(opts, 0)
            case "rocm"  => appendROCm(opts, 0)
            case "openvino" => appendOpenVINO(opts, "CPU")
            case "tensorrt" => appendTensorRT(opts, 0)
            default          => { /* 仅 CPU */ }
        }
        this.session = createSession(env, config.modelPath, opts)
        this.tokenizer = Tokenizer(config.modelPath)
    }

    func encode(text: String): BgeOutput {
        let tokens = tokenizer.tokenize(text)
        // 创建输入 OrtValue
        let inputIdsValue = createTensor(tokens.inputIds, [1, tokens.seqLen])
        let attnMaskValue = createTensor(tokens.attnMask, [1, tokens.seqLen])
        // 运行推理
        let outputs = runSession(session, ["input_ids", "attention_mask"],
                                 [inputIdsValue, attnMaskValue], 3)
        // 解析输出张量 (dense, sparse, colbert)
        return parseOutputs(outputs, tokens)
    }

    func close() {
        unsafe {
            OrtReleaseSession(session)
            OrtReleaseEnv(env)
        }
    }
}
```
5.6 支持多种硬件的关键
ONNX Runtime 通过动态加载 EP 库实现硬件切换。运行时只要环境中有对应的 EP 共享库（如 libonnxruntime_providers_cuda.so），并在 SessionOptions 中注册即可。用户只需在 BgeConfig 中指定 device，工厂方法即可创建正确的后端实例，无需修改任何上层代码。

对于 Google TPU 等更特殊的硬件，ONNX Runtime 目前没有官方 TPU EP，但可通过实现一个自定义 TpuBgeBackend（例如内部调用 TensorFlow Lite）来满足接口，同样纳入工厂管理，保持架构一致。

6. 其他平台简要说明
Windows：与 Linux 完全相同，使用 ONNX Runtime，device 可指定 cuda、dml（DirectML）或 cpu，FFI 调用 onnxruntime.dll。

macOS：可使用 ONNX Runtime + CoreML EP（appendCoreML），或单独实现 CoreMlBgeBackend 通过 Core ML C API 调用 .mlmodel，充分利用 Apple Neural Engine。

7. 与 f_hydra 混合检索引擎集成
在 f_hydra 的引擎初始化阶段，根据配置文件或运行时环境自动选择后端：

```cj
// f_hydra/src/engine.cj
class HybridSearchEngine {
    private let embedder: BgeBackend
    private let denseIndexer: DenseIndexer
    private let sparseIndexer: SparseIndexer
    private let colbertIndexer: ColBERTIndexer
    private let fusion: FusionLayer

    init(config: EngineConfig) {
        // 根据平台与硬件自动决策后端类型与参数
        let bgeConfig = detectBgeConfig(config)
        this.embedder = createBgeBackend(bgeConfig)
        // 构建索引时使用 embedder
        this.denseIndexer = DenseIndexer(...)
        // ...
    }

    func search(query: String, topK: Int64): HybridSearchResult {
        let queryVec = embedder.encode(query)
        let denseResults = denseIndexer.search(queryVec.denseVec, topK)
        let sparseResults = sparseIndexer.search(queryVec.sparseVec, topK)
        let colbertResults = colbertIndexer.search(queryVec.colbertVecs, topK)
        return fusion.fuse(denseResults, sparseResults, colbertResults, topK)
    }
}
```
detectBgeConfig 可根据操作系统、环境变量、硬件探测（如检查 NPU 驱动、CUDA 可用性）自动填充 BackendType 和 device。

8. 总结
通过定义统一的 BgeBackend 接口，f_hydra 成功将 BGE-M3 的推理细节与硬件加速彻底解耦。本文重点给出了：

HarmonyOS：基于 MindSpore Lite，通过 NAPI + 仓颉 FFI 接入麒麟 NPU，充分发挥端侧 AI 算力。

Linux：基于 ONNX Runtime，凭借丰富的 Execution Provider 生态，一套代码覆盖 CPU 到各类 GPU/NPU 的广泛硬件。

Windows、macOS 等其他平台依循相同模式即可平滑接入。这种设计让 f_hydra 能够在任何主流环境中本地部署混合检索能力，而无需改动核心检索逻辑，为跨平台 AI 应用提供了坚实底座。