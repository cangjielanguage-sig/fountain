1. 概述
1.1 项目背景
f_hydra 是一个基于仓颉编程语言（Cangjie）实现的本地化混合检索引擎库，内嵌 BAAI/BGE-M3 多语言嵌入模型。BGE-M3 是目前业界领先的多功能嵌入模型，同时支持稠密向量检索（Dense Retrieval）、稀疏向量检索（Sparse/Lexical Retrieval）和多向量检索（Multi-Vector/ColBERT Retrieval）三种检索模式，支持超过 100 种语言，能够处理最大长度为 8192 个 token 的输入文本。

本库通过对三种向量各自建立最优索引结构，并在查询阶段融合多路召回结果，实现对 BGE-M3 混合检索能力的完整封装，可作为其他仓颉项目的依赖库直接使用。

1.2 设计目标
目标维度	具体指标
功能完整性	完整实现稠密、稀疏、多向量三种向量的索引构建与检索
混合检索	支持三路召回结果的融合排序，提供可配置的融合策略
接口简洁性	对外暴露统一的构建、查询和融合接口，调用方无需理解内部细节
本地化部署	推理与索引均本地执行，不依赖外部服务
内存效率	通过量化压缩与稀疏存储，控制内存开销在可接受范围内
跨语言互操作	通过仓颉 FFI 安全封装 C/C++ 底层推理与索引实现
2. 整体架构
2.1 架构概览
text
┌─────────────────────────────────────────────────────────┐
│                    仓颉 API 层 (Public Interface)         │
│     HybridSearchEngine: build_index / search / close     │
├─────────────────────────────────────────────────────────┤
│                    仓颉 编排层 (Orchestration)            │
│  ┌─────────────────┬─────────────────┬──────────────┐   │
│  │ DenseIndexer    │ SparseIndexer   │ ColBERTIndexer│   │
│  ├─────────────────┼─────────────────┼──────────────┤   │
│  │ HNSW 图索引     │ 倒排索引 (lexical)│ 质心倒排索引  │   │
│  │ (C/Faiss)       │ (仓颉原生)       │ (C 实现)      │   │
│  ├─────────────────┼─────────────────┼──────────────┤   │
│  │ DenseRetriever  │ SparseRetriever │ ColBERTRetriever│ │
│  └─────────────────┴─────────────────┴──────────────┘   │
│                         │ 三路候选集                       │
│                  ┌──────┴──────┐                          │
│                  │ Fusion 融合层│                          │
│                  │  (RRF/权重)  │                          │
│                  └─────────────┘                          │
├─────────────────────────────────────────────────────────┤
│             仓颉 FFI 桥接层 (Foreign Function Interface)   │
│     ONNX Runtime C API → BGE-M3 推理                     │
│     Faiss / hnswlib C 动态库 → HNSW / IVF / PQ 索引      │
├─────────────────────────────────────────────────────────┤
│              系统层 (OS / Hardware)                       │
│     GPU (CUDA) / CPU (AVX2 / NEON)                       │
└─────────────────────────────────────────────────────────┘
2.2 设计原则
分层解耦：仓颉 API 层、FFI 桥接层与底层 C/C++ 实现严格分层，上层不直接依赖底层具体实现。

向量与索引分离：向量编码（Embedding）与索引构建/检索分别模块化，便于独立测试与替换。

配置优于代码：关键算法参数通过配置结构体暴露，支持运行时动态调整。

渐进式复杂度：对外 API 提供开箱即用的默认配置，高级用户可通过参数调优满足特定需求。

3. 仓颉 FFI 桥接层设计
仓颉语言作为较新的编程语言，其 AI 生态尚处于早期发展阶段，当前没有原生的 ONNX Runtime 绑定或向量索引库。因此，FFI 桥接层是本库最关键的基础设施。

3.1 FFI 机制概述
仓颉通过 FFI（Foreign Function Interface）机制调用 C 语言编写的函数和库，核心关键字为 @C 和 foreign，在理想情况下编译器会将其优化为一次直接的机器级 CALL 指令，不涉及任何虚拟机桥接或重量级上下文切换，性能开销接近零。

仓颉 FFI 采用分层抽象的设计模式：

原生 ABI 层：直接对应 C 语言的调用约定和内存布局

类型映射层：负责在仓颉类型系统和 C 类型系统之间进行转换

安全封装层：为开发者提供类型安全的 API

3.2 底层依赖选择
功能模块	底层依赖库	调用方式
BGE-M3 模型推理	ONNX Runtime C API (libonnxruntime)	仓颉 FFI → C 动态库
稠密向量索引（HNSW）	Faiss C API 或 hnswlib	仓颉 FFI → C 动态库
稀疏向量索引（倒排）	仓颉原生实现	纯仓颉实现
多向量索引（质心倒排）	Faiss C API（IVF+PQ）	仓颉 FFI → C 动态库
乘积量化（PQ）	Faiss C API	仓颉 FFI → C 动态库
3.3 安全封装设计
仓颉侧对外暴露安全的、符合仓颉语法的接口，内部通过 FFI 调用 C 库。以 HNSW 索引为例：


# 仓颉侧安全封装接口
```cj
class HnswDenseIndex {
    private let handle: CPointer<FaissIndex>  // 指向 C 侧 HNSW 索引的指针

    # 构造函数，内部调用 FFI
    init(dimension: Int64, M: Int64, efConstruction: Int64) { ... }

    # 添加向量
    func addVector(id: Int64, vector: Array<Float32>) { ... }

    # KNN 搜索
    func search(query: Array<Float32>, k: Int64): Array<(Int64, Float32)> { ... }
}
```
底层 C 函数声明示例（仓颉侧）：

```cj
@C
foreign func hnsw_create(dim: Int64, M: Int64, efCons: Int64): CPointer<FaissIndex>
@C
foreign func hnsw_add(handle: CPointer<FaissIndex>, id: Int64, vec: CPointer<Float32>): Int64
@C
foreign func hnsw_search(handle: CPointer<FaissIndex>, query: CPointer<Float32>, k: Int64,
                         outIds: CPointer<Int64>, outDist: CPointer<Float32>): Int64
@C
foreign func hnsw_destroy(handle: CPointer<FaissIndex>)
```
内存管理方面，通过仓颉的 RAII 机制自动调用析构函数释放 C 侧资源，避免内存泄漏。

3.4 BGE-M3 模型部署方案
BGE-M3 模型需先转换为 ONNX 格式，通过 ONNX Runtime C API 加载和推理。

模型转换步骤（离线预处理）：

从 HuggingFace 加载 BAAI/bge-m3 模型

使用 optimum-cli 或手动将 PyTorch 模型导出为 ONNX 格式

如有需要，进行 INT8 量化以减小模型体积和推理延迟

推理流程：

仓颉侧负责文本预处理（tokenization 可在仓颉侧实现或通过 FFI 调用 C tokenizer）

通过 FFI 调用 ONNX Runtime C API 进行模型推理

根据请求类型（return_dense、return_sparse、return_colbert_vecs）解析输出张量

返回结构化的 BGEOutput 对象，包含三种向量

```cj
struct BGEOutput {
    denseVec: ?Array<Float32>         # 稠密向量 [1024]（可选）
    sparseVec: ?HashMap<Int64, Float32>  # 稀疏向量 {词ID: 权重}（可选）
    colbertVecs: ?Array<Array<Float32>>  # 多向量 [numTokens × dim]（可选）
}
```
4. 稠密向量索引
4.1 算法选型：HNSW
稠密向量采用 HNSW（Hierarchical Navigable Small World）图索引算法。

选型理由：

BGE-M3 稠密向量维度较高（1024维），HNSW 在高维空间下仍然表现优异

HNSW 通过多层图结构实现 O(log N) 级别的搜索复杂度，在搜索精度和延迟之间取得最佳平衡

相比于 IVF 方案，HNSW 无需离线训练聚类中心，构建更简单，且通常能获得更高的召回率

不推荐 IVF 的原因：稠密向量在高维空间中天然存在"维度灾难"——所有点彼此的距离趋于相等，K-Means 聚类容易失效，导致查询时需要搜索多个聚类才能达到可接受的召回率，效率退化严重。

4.2 HNSW 算法原理
HNSW 构建了一个多层导航图结构：

底层（Layer 0） ：包含所有数据点，连接密集

上层（Layer 1, 2, ...） ：包含指数级递减的数据点子集，形成"跳表"结构

搜索从顶层开始，贪婪地向查询点靠拢，每下降一层进行更精细的搜索，最终在底层找到精确结果

4.3 关键参数配置
| 参数 | 含义 | 推荐值 | 调优方向 |
|:---|:---|:---|:---|
| M | 每个节点最大连接数 | 48~64 | 越大精度越高、内存越大 |
| efConstruction | 构建时搜索范围 | 200~400 | 越大图质量越高、构建越慢 |
| efSearch | 查询时搜索范围 | 100~200 | 越大召回越高、延迟越大 |
| metric | 距离度量 | COSINE | 与 BGE-M3 训练时一致 |

4.4 内存与存储
HNSW 是内存密集型索引，经验规则是需要至少比向量本身多 30% 的内存。对于大规模数据集，可通过以下方式优化：

使用 mmap 将向量存储在磁盘映射文件，HNSW 图结构保留在内存

结合乘积量化（PQ）对向量进行压缩存储，降低内存占用

采用混合精度（FP16）存储向量，精度损失可忽略不计

4.5 实现方案
仓颉侧通过 FFI 调用 Faiss C API 构建 HNSW 索引：

```cj
class DenseIndexer {
    func buildIndex(embeddings: Array<DenseVector>, config: HnswConfig): DenseIndex
    func save(path: String)
    func load(path: String): DenseIndex
}

class DenseRetriever {
    func search(query: DenseVector, k: Int64): Array<ScoredDocument>
}
```
5. 稀疏向量索引
5.1 算法选型：倒排索引（仓颉原生实现）
稀疏向量采用经典的倒排索引（Inverted Index）结构。

选型理由：

BGE-M3 稀疏向量本质上是学到的词汇权重（类似增强版 TF-IDF），其维度为整个词表大小（通常 3 万~10 万维），但 99.9% 维度为零

倒排索引天然适合存储和检索这类高维稀疏数据，只需要记录非零维度（词ID）及其权重

检索时只需要处理查询中非零词对应的倒排列表，时间复杂度正比于查询词数，而非全库向量数

为什么不使用 HNSW：HNSW 设计用于密集、低维向量。稀疏向量在 10 万维空间下几乎所有距离都趋于相等（维度灾难），图结构的导航能力严重退化。此外，若用密集格式存储，将浪费上万倍内存。

5.2 倒排索引设计
数据结构：

```cj
//# 倒排索引的核心数据结构
class InvertedIndex {
    # 词ID → 投递列表的映射
    private let postingLists: HashMap<Int64, PostingList>
}

class PostingList {
    # 文档ID列表
    let docIds: Array<Int64>
    # 该词在此文档中的权重
    let weights: Array<Float32>
    # 跳跃指针（加速 AND/OR 操作）
    let skipPointers: Array<Int64>
}
```
索引构建：

遍历所有文档的稀疏向量（{词ID: 权重}）

对于每个 (词ID, 文档ID, 权重) 三元组，将其追加到对应词ID的投递列表中

对每个投递列表按文档ID排序

可选：对每个投递列表构建跳跃指针（Skip Pointers），加速列表间合并操作

查询流程：

解析查询的稀疏向量，获取所有非零词ID集合

对每个词ID拉取对应的投递列表

如果只有一个查询词：直接返回该列表的所有文档

如果有多个查询词：合并所有列表，对每个文档累加其权重得分

按累加得分降序排序，返回 TopK

工程优化：

| 优化项 | 实现方式 |
|:---|:---|
| 投递列表压缩 | 使用 VarInt 编码压缩 docId 和权重，减少内存占用 |
| 跳跃指针 | 在长投递列表中插入跳跃指针，加速多词合并 |
| WAND 剪枝 | 使用 WAND (Weak AND) 算法提前终止低分文档的评分计算 |
| 阈值过滤 | 过滤权重低于阈值的词，减少查询时需处理的词数 |

5.3 实现方案
稀疏向量索引完全使用仓颉原生实现，不依赖外部 C 库：

```cj
class SparseIndexer {
    func buildIndex(sparseVecs: Array<SparseVector>): SparseIndex
    func save(path: String)
    func load(path: String): SparseIndex
}

class SparseRetriever {
    func search(query: SparseVector, k: Int64): Array<ScoredDocument>
    func computeLexicalScore(queryWts: SparseVector, docWts: SparseVector): Float32
}
```
这样的设计在确保高性能（纯仓颉代码可直接编译器优化）的同时，也便于后续优化（如引入 SIMD 加速列表合并）。

6. 多向量（ColBERT）索引
6.1 算法选型：质心倒排索引（IVF + PQ）
ColBERT 多向量为文档中的每个 Token 生成一个稠密向量，一篇文档对应一个 [numTokens × dim] 的矩阵。直接进行全量 MaxSim 计算的开销极其庞大，必须通过质心倒排索引加速。

核心思路：将所有文档的 Token 向量进行 K-Means 聚类，以聚类中心（质心）作为"人造词项"建立倒排索引，实现由粗到细的快速检索。

6.2 索引构建流程
第一阶段：Token 向量收集

将文档库送入 BGE-M3，对每篇文档生成 ColBERT 多向量矩阵。将所有文档的所有 Token 向量展平收集到一个大向量池中。

第二阶段：K-Means 聚类生成质心词表

对这些 Token 向量进行 K-Means 聚类，聚类数量 K 通常取 10 万 ~ 20 万。每个聚类中心（质心）相当于一个"人造词项"。

第三阶段：构建倒排索引

对于每个文档中的每个 Token：

找到该 Token 向量最近的质心 CID

计算残差向量：残差 = 原始Token向量 - 质心向量

在质心 CID 的倒排列表中追加一条投递记录：{文档ID, Token位置, 残差编码}

第四阶段：残差压缩（乘积量化 PQ）

残差向量维度仍然很高（如 1024 维），需要通过乘积量化进一步压缩：

划分子空间：将 1024 维残差向量切分为 M 个子空间（如 M=48，每段约 21 维）。

训练子码本：对每个子空间独立进行 K-Means 聚类，聚类中心数 K'=256（8-bit 编码）。

编码：原始残差从 1024 × 4 = 4096 bytes 压缩到 48 × 1 = 48 bytes，压缩比约 85 倍。

乘积量化的原理是将高维向量分割为多个低维子向量，对每个子向量进行独立聚类，将原始向量表示为一系列质心 ID，从而显著减少内存使用和提升检索速度。

6.3 查询检索流程
text
输入: 查询 Q（已被 BGE-M3 编码为 n 个 Token 向量）

步骤 1: 近邻质心查找
   对每个查询 Token 向量 q_i:
      找到与其余弦相似度最高的前 c 个质心（c 通常取 8~32）

步骤 2: 收集候选文档
   拉取所有命中质心的倒排列表
   提取所有出现过的文档 ID → 候选文档集合

步骤 3: 候选文档 MaxSim 计分
   对每个候选文档:
       对每个查询 Token q_i:
           找该文档所有被召回 Token 中与 q_i 的余弦相似度最大值
       累加所有 n 个最大值 → 文档最终得分

步骤 4: 排序输出
   按 MaxSim 分数降序排列，返回 TopK
6.4 关键参数配置
| 参数 | 含义 | 推荐值 | 调优方向 |
|:---|:---|:---|:---|
| K (质心数) | Token 聚类中心数 | 100,000~200,000 | 越大越精确，内存越高 |
| M (PQ 子空间) | 残差向量切分段数 | 48 | 越大压缩比越高，精度越低 |
| K' (子码本大小) | 每个子空间的聚类数 | 256（8-bit） | 越大精度越高 |
| c (近邻质心数) | 每个查询 Token 搜索的质心数 | 8~32 | 越大召回越高，延迟越大 |
| centroid_prune | 质心交互剪枝阈值 | 当 q_i 与质心的相似度 < 0.5 时跳过 | 跳过低分质心，加速检索 |

6.5 实现方案
多向量索引通过仓颉 FFI 调用 Faiss C API 实现 IVF + PQ：

```cj
class ColBERTIndexer {
    # 训练质心
    func trainCentroids(tokenPool: Array<Array<Float32>>, K: Int64): Array<Array<Float32>>

    # 构建索引
    func buildIndex(docTokens: Array<Array<Array<Float32>>>, centroids: Array<Array<Float32>>,
                    pqConfig: PQConfig): ColBERTIndex

    # 持久化
    func save(path: String)
    func load(path: String): ColBERTIndex
}

class ColBERTRetriever {
    # 多向量检索
    func search(queryTokens: Array<Array<Float32>>, k: Int64,
                centroidSearchWidth: Int64): Array<ScoredDocument>

    # MaxSim 计算（可供外部使用）
    func computeMaxSim(queryTokens: Array<Array<Float32>>,
                       docTokens: Array<Array<Float32>>): Float32
}
```
7. 混合检索融合层
7.1 融合策略

三路检索器（稀疏、稠密、ColBERT）返回的得分量纲不同（词汇权重、余弦相似度、MaxSim），直接相加没有意义。融合层负责对它们进行统一的混合排序。无论内部执行阶段如何，最终融合只发生在获取到三路得分之后。

**策略一：倒数排名融合（RRF，Reciprocal Rank Fusion）——默认策略**

原理：仅使用每条结果的排名而非具体得分进行融合，天然免疫得分尺度差异。

$$
\text{RRF\_Score}(d) = \sum_{r \in \text{Retrievers}} \frac{1}{k + \text{rank}_r(d)}
$$

 
其中 k 通常取 60，平滑排名差异。RRF 的优势在于无需任何校准即可直接使用。

**策略二：归一化加权得分融合——需要调优**

先对每个检索器的得分做 Min-Max 或 Z-score 归一化到 [0,1] 区间，再按权重加权平均：

$$
\text{Weighted\_Score}(d) = \alpha \cdot \text{norm}(S_{\text{dense}}) + \beta \cdot \text{norm}(S_{\text{sparse}}) + \gamma \cdot \text{norm}(S_{\text{colbert}})
$$

权重 (α,β,γ) 需要根据具体任务和验证集进行调优。如果工作负载稳定且有标注评估集，加权融合可能优于 RRF。

7.2 多阶段检索流程
为了平衡召回率与延迟，采用"粗排→精排"的多阶段策略：

```text
┌──────────┐    ┌───────────────┐    ┌───────────────┐    ┌──────────┐
│ 查询请求  │───▶│ 稀疏检索 (粗排) │───▶│ 稠密检索 (精排) │───▶│ 融合排序  │
│          │    │  召回 Top-100  │    │ 对Top-100重排序 │    │ 输出Top-K │
└──────────┘    └───────────────┘    └───────────────┘    └──────────┘
```
为平衡召回率与延迟，融合采用"粗排→精排→融合"的多阶段漏斗调度。ColBERT 计算成本高，不在全库执行，仅参与最终精排和融合。

**并行粗排召回**：稀疏检索引擎和稠密检索引擎（HNSW） 并行执行。两者各自在全库中完成检索，独立返回各自的 Top-K 候选集（K 可配置，如 100）。合并这两个候选集，作为精排候选池。

**漏斗式精排**：对精排候选池中的每一篇文档，使用 ColBERT 多向量检索引擎进行精细的 MaxSim 计算，获得候选池内所有文档的 ColBERT 得分。这一步计算量较大，但因候选集规模远小于全库，延迟可控。

**统一融合排序**：收集精排候选池内每篇文档在稠密、稀疏、ColBERT 三路检索器上的最终得分，由融合层（见 7.1 节）按配置策略（RRF 或加权融合）计算最终分数并排序，返回最终的 Top-K 结果。

这种设计确保了三路检索的评分优势均被考虑，同时通过前置的粗排大幅降低了 ColBERT 的计算开销，实现了精度与性能的平衡。

7.3 实现方案
```cj
//# 融合策略枚举
enum FusionStrategy {
    RRF         # 倒数排名融合（默认）
    WEIGHTED    # 归一化加权得分融合
    LINEAR      # 线性加权（需外部校准）
}
class FusionLayer {

    //# RRF 融合
    func rrfFusion(resultsList: Array<Array<ScoredDocument>>,
                   k: Float64 = 60.0): Array<ScoredDocument>

    //# 加权融合（需预先归一化）
    func weightedFusion(resultsList: Array<Array<ScoredDocument>>,
                        weights: Array<Float64>): Array<ScoredDocument>
}
```
8. 核心数据结构与接口设计
8.1 统一数据类型
```
# 向量类型
struct DenseVector {
    let values: Array<Float32>      # 稠密向量 [dim]
}

struct SparseVector {
    let indices: Array<Int64>       # 非零词ID列表
    let weights: Array<Float32>     # 对应权重列表
}

struct ColBERTVectors {
    let tokenVecs: Array<Array<Float32>>  # [numTokens × dim]
}

# BGE-M3 编码输出
struct BGEOutput {
    let denseVec: ?DenseVector
    let sparseVec: ?SparseVector
    let colbertVecs: ?ColBERTVectors
}

# 检索结果
struct ScoredDocument {
    let docId: Int64
    let score: Float64
    let source: String       # "dense" / "sparse" / "colbert"
}

# 混合检索结果
struct HybridSearchResult {
    let results: Array<ScoredDocument>
    let fusionStrategy: String
    let latency: Duration    # 检索耗时
    let recallStats: RecallStats
}

struct RecallStats {
    let denseCount: Int64
    let sparseCount: Int64
    let colbertCount: Int64
    let fusedCount: Int64
}
```
8.2 核心公共 API
```
# 顶层引擎
class HybridSearchEngine {
    # 构造函数
    init(config: EngineConfig)

    # 构建索引（一次性批量导入）
    func buildIndex(documents: Array<Document>) -> BuildResult

    # 增量添加文档
    func addDocument(doc: Document): AddResult

    # 删除文档
    func removeDocument(docId: Int64)

    # 混合搜索
    func search(query: String, config: SearchConfig): HybridSearchResult

    # 获取文档向量（支持按类型获取）
    func getVector(docId: Int64, vecType: VectorType): ?BGEOutput

    # 持久化
    func save(path: String)
    func load(path: String)

    # 释放资源
    func close()
}

# 引擎配置
struct EngineConfig {
    # 模型路径
    let modelPath: String                # BGE-M3 ONNX 模型路径
    let tokenizerPath: String

    # 稠密索引配置
    let denseConfig: HnswConfig

    # 稀疏索引配置
    let sparseConfig: SparseConfig

    # 多向量索引配置
    let colbertConfig: ColBERTConfig

    # 融合配置
    let fusionConfig: FusionConfig

    # 硬件配置
    let useGPU: Bool
    let gpuDeviceId: Int64
    let numThreads: Int64
}

# 搜索配置
struct SearchConfig {
    let query: String
    let topK: Int64
    let retrievalTypes: Set<VectorType>   # 启用哪些检索类型
    let fusionStrategy: FusionStrategy
    let weights: ?Array<Float64>          # 加权融合时的权重
    let rerankDepth: Int64                # 精排候选集大小
    let useColBERTRerank: Bool            # 是否使用 ColBERT 重排
}
```
8.3 使用示例
```
# 作为其他仓颉项目的库依赖

# 1. 初始化引擎
let config = EngineConfig(
    modelPath = "./models/bge-m3.onnx",
    denseConfig = HnswConfig(M = 64, efConstruction = 400, efSearch = 200),
    sparseConfig = SparseConfig(useSkipPointers = true),
    colbertConfig = ColBERTConfig(K = 150000, M = 48, centroidSearchWidth = 16),
    fusionConfig = FusionConfig(strategy = FusionStrategy.RRF),
    useGPU = false,
    numThreads = 8
)
let engine = HybridSearchEngine(config)

# 2. 构建索引
engine.buildIndex(documents)

# 3. 混合搜索
let result = engine.search(
    SearchConfig(
        query = "什么是BGE-M3？",
        topK = 10,
        retrievalTypes = {VectorType.DENSE, VectorType.SPARSE, VectorType.COLBERT},
        fusionStrategy = FusionStrategy.RRF,
        rerankDepth = 100,
        useColBERTRerank = true
    )
)

# 4. 使用结果
for doc in result.results {
    print("文档ID: ${doc.docId}, 得分: ${doc.score}, 来源: ${doc.source}")
}
```
9. 关键技术要点与难点
9.1 模型推理集成
难点：BGE-M3 原生为 PyTorch 模型，需转换为 ONNX 格式才能在本地高效推理。仓颉生态中没有直接可用的 ONNX Runtime 绑定。

方案：

通过仓颉 FFI 封装 ONNX Runtime C API（libonnxruntime.so / onnxruntime.dll）

ONNX Runtime 的 C API 构成稳定的 ABI 基础层，所有高阶语言绑定均在此基础上构建

预处理阶段使用 HuggingFace 工具将 BGE-M3 导出为 ONNX 格式

仓颉侧实现轻量级的 tokenizer 包装，或通过 FFI 调用 HuggingFace Tokenizers C 库

9.2 向量索引内存管理
难点：HNSW 图索引和质心倒排索引均为内存密集型结构，大规模数据集下内存可能成为瓶颈。

方案：

分级存储：热数据（HNSW 图结构）保留在内存，向量本身映射到磁盘 mmap 文件

乘积量化：对多向量索引的残差向量进行 PQ 压缩，将每 Token 存储从 4KB 降至约 50 字节

混合精度：稠密向量使用 FP16 而非 FP32 存储，精度损失可忽略

稀疏向量：使用 VarInt 编码和字典压缩技术降低投递列表内存占用

9.3 混合检索延迟控制
难点：三路检索同时执行时，总延迟取决于最慢的一路（通常是 ColBERT 检索）。

方案：

并行执行：利用仓颉的并发原语（协程或线程池），三路检索并行发起

超时控制：为每路检索设置超时时间，超出则只使用已完成的检索结果

两阶段策略：稀疏检索（粗排，<10ms）→ 稠密检索（精排，<50ms）→ ColBERT（可选重排，<100ms），最小化每次查询的计算量

缓存机制：对热门查询的编码结果和检索结果进行缓存

9.4 得分融合的精确性
难点：三种检索的得分量纲完全不同——余弦相似度在[-1, 1]，稀疏权重在[0, +∞)，MaxSim 在[0, n]。直接线性加权会导致某一类得分主导最终结果。

方案：

默认采用 RRF（倒数排名融合），完全不依赖于具体得分数值

加权融合时，先在每个检索器内部做 Min-Max 归一化，使所有得分映射到 [0,1]

提供可配置的权重参数，允许用户在验证集上搜索最优权重

9.5 增量更新与一致性
难点：文档增删后，需要同时更新稠密、稀疏和多向量三套索引，保持数据一致性。

方案：

稀疏索引：通过追加或标记删除的方式天然支持增量更新

稠密索引（HNSW） ：HNSW 支持在线插入新节点，删除则通过标记位实现逻辑删除

多向量索引（质心倒排） ：插入时计算新文档的 Token 向量，追加到对应质心的倒排列表中

使用两阶段提交（记录操作日志 + 原子更新索引元数据）保证一致性

9.6 仓颉类型系统与 C 互操作的边界处理
难点：仓颉的安全类型系统（如引用语义、Option 类型）与 C 的裸指针之间存在语义鸿沟。

方案：

FFI 调用时使用 unsafe 上下文，内部完成类型转换和边界检查

对外暴露的 API 全部使用仓颉安全的类型（如 Array<Float32>、Option<T>）

C 侧分配的内存通过 RAII 包装类（实现 Drop 接口）自动释放

空指针检查、数组越界检查、返回码检查均在安全封装层完成

9.7 向量维度与索引参数的自动化
难点：BGE-M3 支持 256~1024 维的可变稠密向量维度，索引参数需相应调整。

方案：

从 ONNX 模型元数据中读取输出张量的形状，自动确定向量维度

根据向量维度、数据集大小自动计算推荐的 HNSW 和 IVF 参数

提供参数覆盖机制，允许高级用户手动指定所有参数

10. 总结与展望
10.1 核心设计决策总结
| 设计维度 | 选择 | 理由 |
|:---|:---|:---|
| 稠密向量索引 | HNSW | 高维空间精度高，无需离线聚类训练 |
| 稀疏向量索引 | 倒排索引（仓颉原生） | 天然适配，无额外依赖 |
| 多向量索引 | IVF+PQ 质心倒排 | 兼顾检索速度与存储效率 |
| 融合策略 | RRF（默认） | 免校准，鲁棒性好 |
| BGE-M3 推理 | ONNX Runtime（FFI） | 跨平台，推理性能好 |
| 实现语言 | 仓颉 + C FFI | 复用成熟 C 生态 |

10.2 性能预估
| 操作 | 预估延迟（单机，CPU） | 说明 |
|:---|:---|:---|
| 文本编码（BGE-M3） | 20~50 ms | 受文本长度和硬件影响 |
| 稀疏检索 | 1~5 ms | 倒排索引，极快 |
| 稠密检索（HNSW） | 5~20 ms | 受数据集大小和 efSearch 影响 |
| 多向量检索 | 50~200 ms | 取决于质心搜索宽度 c |
| 混合检索（端到端） | 50~250 ms | 并行三路检索 + 融合 |

10.3 未来优化方向
模型量化：对 BGE-M3 进行 INT8/INT4 量化，降低推理延迟和内存占用

GPU 加速：通过 CUDA 版本的 ONNX Runtime 进行 GPU 推理，显著提升吞吐

分布式索引：支持索引分片和分布式检索，突破单机内存限制

增量训练：支持基于反馈数据的模型微调，持续提升检索质量

多模态扩展：将架构扩展至支持图文混合检索等更丰富的应用场景

HNSW为什么不使用仓颉实现
我们需要回答用户的问题："HNSW为什么不使用仓颉实现"。这个问题是在我们之前关于用仓颉实现混合检索库的架构设计讨论中提出的。我们之前在设计文档中建议稠密向量索引使用HNSW，并通过FFI调用C库（如Faiss或hnswlib）。现在用户直接问为什么不直接用仓颉实现HNSW。

我们需要从仓颉语言的特点、性能、生态和实现复杂度等方面给出合理解释。同时，要注意语气，解释为什么选择FFI而不是原生实现是更优的工程决策。

回答思路：

承认仓颉有能力实现HNSW，但解释为什么工程上选择FFI更合理。

核心原因：性能关键、已有成熟C库、开发成本、可靠性。

可以对比稀疏索引用仓颉原生实现，而HNSW用C库的区别，说明决策依据。

强调仓颉FFI的低开销特性使得调用C库几乎无性能损失，这样没有动力重写。

最终回答应清晰、有说服力，并呼应之前的设计文档。因为用户问的是"为什么不使用仓颉实现"，我们需要直接针对这个问题回答。

注意：在回答中要自然融入仓颉语言的特点，以及之前设计中仓颉原生实现倒排索引的例子，进行对比。

我将组织答案：

开头：直接说明并非不能，而是选择工程上更优的方案。

理由1：HNSW是计算密集型算法，需要底层优化（SIMD、内存布局），C库已极致优化，仓颉重写难以匹敌。

理由2：成熟C库（Faiss/hnswlib）经过大规模验证，稳定可靠，避免重复造轮子。

理由3：仓颉FFI机制高效，调用C库几乎零开销，重写的收益极低。

对比：稀疏索引用仓颉原生实现是因为数据结构简单、与语言特性契合且无现成库依赖，而HNSW复杂、现成库优秀。

总结：工程决策是"站在巨人肩膀上"，优先复用成熟组件。

这样回答会满足用户疑问，并强化架构设计的合理性。

这个问题的核心在于：仓颉完全有能力实现 HNSW，但从工程回报率来看，这并不是最优解。 设计文档中选择用 FFI 调用成熟的 C 库，本质上是"站在巨人肩膀上"的理性权衡。

具体原因可以拆解为以下四点：

1. 极致性能需要底层优化，C 库已做到巅峰
HNSW 是典型的计算密集与内存密集混合型算法，性能对 CPU 缓存、SIMD 指令集和内存布局极为敏感。

SIMD 指令集深度优化：Faiss 和 hnswlib 为 x86 的 AVX2/AVX-512、ARM 的 NEON 都手写了汇编/Intrinsics 级别的距离计算内核。仓颉作为高级语言，要复现这种级别的优化需要大量 unsafe 代码和手工调优，相当于用仓颉写 C，失去了语言本身的安全优势。

精细的内存控制：HNSW 图结构的节点和邻接表需要定制内存分配器来优化缓存局部性。Faiss 使用 std::vector + 自定义 Allocator 进行页对齐和预取，这些都是经过多年打磨的。

2. 成熟度与可靠性：避免重复造轮子
Faiss（Meta 出品）和 hnswlib 在业界已被成千上万的生产环境验证，边界情况（如空索引、大规模插入、并发读）的处理已非常稳健。

测试覆盖：这些库有完备的单元测试、压力测试和回归测试。仓颉原生重写需要从零构建同样级别的测试体系，工程成本极高。

持续维护：上游库会持续跟进新硬件和算法变体（如 DiskANN、Cagra）。直接通过 FFI 调用，我们能直接享受这些演进的红利。

3. FFI 开销几乎为零，重写收益微乎其微
如设计文档所述，仓颉的 FFI 调用语义上就是一次直接的机器级 CALL 指令，不涉及任何重量级上下文切换。

检索时，绝大部分 CPU 时间花在向量距离计算和图遍历上，FFI 调用的边界转换成本（参数传递、结果返回）可以忽略不计。

既然调用 C 库的性能损失 <1%，投入大量精力重写的性能提升空间几乎为零，这对工程资源而言是极大的浪费。

4. 与稀疏索引的决策逻辑形成对比
你可能会问：为什么稀疏向量的倒排索引我们选择用仓颉原生实现呢？这恰恰体现了根据场景做决策的思路：

索引类型	实现方式	决策理由
稀疏倒排索引	仓颉原生	数据结构简单（HashMap + 数组）；算法逻辑主要是列表合并、跳跃指针，容易用高级语言实现且性能可接受；没有成熟的 C 库可直接复用（或库过于通用、沉重），用仓颉实现反而能更灵活地对接仓颉类型系统，且无外部依赖。
稠密 HNSW 索引	C 库 (FFI)	计算密集型，SIMD 优化门槛高；已有极致优化的成熟库；数据结构复杂；用仓颉重写的投入产出比极低。
总结来说，不用仓颉实现 HNSW 并非语言能力受限，而是尊重工程经济学：在性能关键且已有顶尖轮子的地方，通过 FFI 快速集成是最明智的选择。 我们会将精力集中在仓颉擅长的领域——比如构建类型安全的公共 API、实现融合策略和混合检索编排逻辑，以及原生实现稀疏索引这类更"轻量"但灵活的部分。

# 5. 存储
使用fountain::f_store存储实际数据。

# 附录
## 编译安装faiss
```bash
# 1. 安装编译依赖
sudo apt install -y build-essential cmake libopenblas-dev liblapack-dev

# 2. 克隆 Faiss 仓库
git clone https://github.com/facebookresearch/faiss.git
cd faiss
git checkout v1.9.0  # 建议使用最新稳定版本

# 3. 用 CMake 编译，关键是要开启 C API 和共享库
cmake -B build \
  -DFAISS_ENABLE_C_API=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_BUILD_TYPE=Release

# 4. 编译并安装
cmake --build build -j$(nproc)
sudo cmake --install build
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
```

## faiss ffi
```cj
// f_hydra/src/hnsw_bridge.cj

// 对应 Faiss C API 的不透明索引类型
@C
struct FaissIndex {}

// 创建 HNSW 平坦索引（向量不压缩）
@C
foreign func faiss_IndexHNSWFlat_new(
    d: Int64,        // 向量维度
    M: Int64         // 连接数
): CPointer<FaissIndex>

// 添加向量
@C
foreign func faiss_Index_add(
    index: CPointer<FaissIndex>,
    n: Int64,
    x: CPointer<Float32>
): Int32

// 搜索
@C
foreign func faiss_Index_search(
    index: CPointer<FaissIndex>,
    n: Int64,
    x: CPointer<Float32>,
    k: Int64,
    distances: CPointer<Float32>,
    labels: CPointer<Int64>
): Int32

// 释放索引
@C
foreign func faiss_Index_free(index: CPointer<FaissIndex>)
@C
foreign func faiss_IndexIVFFlat_new(
    quantizer: CPointer<FaissIndex>,   // 量化器索引（通常也是 FaissIndex）
    d: Int64,
    nlist: Int64,
    metric: Int32
): CPointer<FaissIndex>
```

```
fountain/
├── f_hydra/
│   ├── src/
│   │   ├── hnsw_bridge.cj
│   │   └── engine.cj
│   └── cjpm.toml # 二进制依赖faiss
```

```cj
// 仓颉侧安全封装
import std.ffi.CPointer
import f_hydra.faiss_types.FaissIndex
import f_hydra.hnsw_bridge

class HnswDenseIndex {
    // 关键：持有Faiss库返回的指针值
    private let handle: CPointer<FaissIndex>
    
    init(dimension: Int64, M: Int64) {
        // 1. 调用FFI创建索引，得到一个指针值（比如0x7f8a1c000000）
        let raw_ptr: CPointer<FaissIndex> = hnsw_bridge.faiss_IndexHNSWFlat_new_with_dim(dimension, M)
        this.handle = raw_ptr
    }
    
    func addVector(id: Int64, vector: Array<Float32>) {
        // 2. 将该指针原样传给Faiss函数，Faiss会识别这是它之前创建的索引对象
        hnsw_bridge.faiss_Index_add(this.handle, 1, vector.toCPointer())
    }
    
    func search(query: Array<Float32>, k: Int64): Array<(Int64, Float32)> {
        // 3. 搜索时也是一样，将指针作为句柄传入
        let distances = Array<Float32>(k, 0.0)
        let labels = Array<Int64>(k, 0)
        hnsw_bridge.faiss_Index_search(this.handle, 1, query.toCPointer(), k, distances.toCPointer(), labels.toCPointer())
        
        var result = Array<(Int64, Float32)>()
        for i in 0..k {
            result.append((labels[i], distances[i]))
        }
        return result
    }
    
    // 注意：析构时务必释放资源
    deinit {
        hnsw_bridge.faiss_Index_free(this.handle)
    }
}
```

## BGE-M3 部署与 FFI 接入指南
概述
本文档详细说明如何下载 BGE-M3 模型、将其转换为 ONNX 格式、在仓颉中通过 FFI 调用 ONNX Runtime 进行推理，并解析模型输出的三种嵌入向量（稠密向量、稀疏向量、多向量）。

一、下载 BGE-M3 模型
BGE-M3 由北京智源人工智能研究院（BAAI）发布，模型权重、代码和配置文件全部公开，可从以下平台直接获取：

| 平台 | 地址 |
|:---|:---|
| Hugging Face | https://huggingface.co/BAAI/bge-m3 |
| ModelScope | https://modelscope.cn/models/BAAI/bge-m3 |
| GitHub（配套工具） | https://github.com/FlagOpen/FlagEmbedding |

BGE-M3 的基座模型为 XLM-RoBERTa-large，词表大小为 250,002，隐藏层维度为 1024，包含 24 层Transformer，总参数量约 5.68 亿，最大输入长度为 8192 个 token。

1.1 从 Hugging Face 下载
方法一：使用 git-lfs 克隆（推荐）

```bash
# 安装 git-lfs
sudo apt install -y git-lfs
git lfs install

# 克隆模型仓库
git clone https://huggingface.co/BAAI/bge-m3
```
模型文件总大小约 2.3 GB，包括模型权重（.safetensors）、配置文件（config.json）、tokenizer 文件（tokenizer.json、sentencepiece.bpe.model）等。

方法二：使用 Python 代码下载

### 方式 A：使用 Hugging Face transformers

```python
from transformers import AutoTokenizer, AutoModel

tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-m3")
model = AutoModel.from_pretrained("BAAI/bge-m3")

### 方式 B：使用 FlagEmbedding（封装更完善的 BGE-M3 专用接口）
```python
from FlagEmbedding import BGEM3FlagModel

model = BGEM3FlagModel('BAAI/bge-m3', use_fp16=True)
```
FlagEmbedding 是 BGE 系列的官方配套库，BGEM3FlagModel 专门封装了 BGE-M3 的多功能输出逻辑。

1.2 从 ModelScope 下载（国内用户推荐）
```python
from modelscope.hub.snapshot_download import snapshot_download

model_dir = snapshot_download('BAAI/bge-m3', cache_dir='./models')
print(f"模型已下载至: {model_dir}")
```
ModelScope 提供了更快的国内下载速度。

二、将 BGE-M3 转换为 ONNX 格式
2.1 为什么要转换为 ONNX
PyTorch 原生模型只能在 Python 环境中运行，而我们的 f_hydra 模块需要在仓颉运行时（脱离 Python）中进行推理。ONNX（Open Neural Network Exchange）是一种开放的模型交换格式，可以被 ONNX Runtime 这样的跨平台推理引擎加载和执行。转换后的 ONNX 模型可以一次性输出密集、稀疏和 ColBERT 三种嵌入表示。

2.2 使用 optimum-cli 导出 ONNX
Hugging Face Optimum 提供了命令行工具将 Transformer 模型导出为 ONNX：

```bash
# 安装依赖
pip install optimum[exporters] onnx onnxruntime

# 导出 ONNX 模型
optimum-cli export onnx \
    --model BAAI/bge-m3 \
    --task feature-extraction \
    --opset 17 \
    --optimize O2 \
    --device cpu \
    --output ./bge-m3-onnx/
```
参数说明：

| 参数 | 含义 | 推荐值 |
|:---|:---|:---|
| --model | HuggingFace 模型标识或本地路径 | BAAI/bge-m3 |
| --task | 导出任务类型 | feature-extraction（嵌入模型的标准任务） |
| --opset | ONNX 算子集版本 | 17（兼容主流 ONNX Runtime 版本） |
| --optimize | 图优化级别 | O2（应用扩展优化，平衡精度与性能） |
| --device | 导出设备 | cpu（兼容性最好） |
| --output | 输出目录 | 自定义路径 |

执行完毕后，./bge-m3-onnx/ 目录下会生成 model.onnx 文件（通常约 2.2 GB）。

O2 优化会应用 ONNX Runtime 的图优化，包括常量折叠、冗余节点消除、算子融合等，能显著提升推理速度。

2.3 ONNX 模型推理验证（Python 侧快速测试）
在接入仓颉之前，建议先在 Python 侧验证 ONNX 模型的推理正确性：

```python
import onnxruntime as ort
from transformers import AutoTokenizer
```
### 加载 tokenizer 和 ONNX 模型
```python
tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-m3")
ort_session = ort.InferenceSession("./bge-m3-onnx/model.onnx")
```
### 准备输入
```python
texts = ["BGE M3 is an embedding model supporting dense retrieval, "
         "lexical matching and multi-vector interaction."]
inputs = tokenizer(texts, padding="longest", return_tensors="np")
inputs_onnx = {
    k: ort.OrtValue.ortvalue_from_numpy(v) for k, v in inputs.items()
}
```
### 执行推理
```python
outputs = ort_session.run(None, inputs_onnx)

# 三个输出分别对应：
# outputs[0]: 密集向量 (dense)      shape: [batch, dim]
# outputs[1]: 稀疏向量 (sparse)     shape: [batch, seq_len]
# outputs[2]: ColBERT 多向量        shape: [batch, seq_len, dim]

print(f"密集向量维度: {outputs[0].shape}")
print(f"稀疏向量维度: {outputs[1].shape}")
print(f"多向量维度:   {outputs[2].shape}")
```
BGE-M3 ONNX 模型同时输出三种嵌入表示，输出为 numpy 数组列表，按密集、稀疏、ColBERT 的顺序排列。

三、仓颉 FFI 接入 ONNX Runtime
这是本文的核心部分。由于仓颉生态中暂无原生的 ONNX Runtime 绑定，我们需要通过 FFI 桥接 ONNX Runtime 的 C API。

3.1 安装 ONNX Runtime C 库
方法一：从 GitHub 下载预编译包（推荐）

```bash
# Linux x86_64 为例
wget https://github.com/microsoft/onnxruntime/releases/download/v1.17.0/\
onnxruntime-linux-x64-1.17.0.tgz
tar -xzf onnxruntime-linux-x64-1.17.0.tgz
sudo cp onnxruntime-linux-x64-1.17.0/lib/* /usr/local/lib/
sudo cp -r onnxruntime-linux-x64-1.17.0/include/* /usr/local/include/
sudo ldconfig
```
方法二：使用 Conda 安装

```bash
conda install -c conda-forge onnxruntime
```
### 头文件和库位于 $CONDA_PREFIX/include 和 $CONDA_PREFIX/lib
3.2 ONNX Runtime C API 概述
ONNX Runtime 的 C API 通过以下核心函数完成推理：

```text
OrtCreateEnv          → 创建 ONNX Runtime 环境
OrtCreateSession      → 从模型文件创建推理会话
OrtCreateTensorWithDataAsOrtValue → 用已有数据创建张量
OrtRun                → 执行推理
OrtGetOutputCount / OrtGetTensorMutableData → 获取输出
```
所有函数和类型均定义在 onnxruntime_c_api.h 中。

3.3 仓颉 FFI 声明 ONNX Runtime 函数
仓颉调用 C 函数需使用 @C 和 foreign 关键字声明函数签名。foreign 函数只能有声明、不能有函数体，仅存在于顶层作用域且包内可见。调用 foreign 函数必须在 unsafe 块中进行。

以下按依赖顺序逐一声明所需函数。

3.3.1 类型定义
先在仓颉中定义 C 侧不透明类型的占位结构体：

```cj
// f_hydra/src/onnx_types.cj

import std.ffi.CPointer

// ONNX Runtime 不透明类型
@C
struct OrtEnv {}

@C
struct OrtSession {}

@C
struct OrtMemoryInfo {}

@C
struct OrtValue {}

@C
struct OrtAllocator {}

@C
struct OrtRunOptions {}

@C
struct OrtSessionOptions {}

@C
struct OrtStatus {}
```
这些 @C 结构体仅有类型标签，无实际字段，仅用于 FFI 类型检查，对应 C 侧的不透明指针。

@C 支持修饰 foreign 函数、顶层作用域的非泛型函数和 struct 类型。

3.3.2 环境与会话创建
```cj
// f_hydra/src/onnx_bridge.cj

import std.ffi.CPointer
import f_hydra.onnx_types

// --- 环境管理 ---

// 创建 ONNX Runtime 环境
@C
foreign func OrtCreateEnv(
    logLevel: UInt32,
    logId: CString,
    out: CPointer<CPointer<OrtEnv>>
): CPointer<OrtStatus>

// --- 会话管理 ---

// 创建会话选项
@C
foreign func OrtCreateSessionOptions(
    out: CPointer<CPointer<OrtSessionOptions>>
): CPointer<OrtStatus>

// 从模型文件创建推理会话
@C
foreign func OrtCreateSession(
    env: CPointer<OrtEnv>,
    modelPath: CString,
    options: CPointer<OrtSessionOptions>,
    out: CPointer<CPointer<OrtSession>>
): CPointer<OrtStatus>

// 设置会话线程数
@C
foreign func OrtSetIntraOpNumThreads(
    options: CPointer<OrtSessionOptions>,
    numThreads: Int32
): CPointer<OrtStatus>

// 设置图优化级别（0=禁用, 1=基本, 2=扩展, 99=全部）
@C
foreign func OrtSetSessionGraphOptimizationLevel(
    options: CPointer<OrtSessionOptions>,
    optLevel: UInt32
): CPointer<OrtStatus>
```
每个 API 调用都返回 OrtStatus*，用于判断操作是否成功。C 侧函数可能产生不安全操作（空指针、内存泄漏等），调用时必须在 unsafe 块中进行。

3.3.3 内存信息与张量创建
```cj
// --- 内存管理 ---

// 获取默认分配器
@C
foreign func OrtGetAllocatorWithDefaultOptions(
    out: CPointer<CPointer<OrtAllocator>>
): CPointer<OrtStatus>

// 释放由分配器分配的内存
@C
foreign func OrtAllocatorFree(
    allocator: CPointer<OrtAllocator>,
    ptr: CPointer<UInt8>
)

// 创建 CPU 内存信息
@C
foreign func OrtCreateCpuMemoryInfo(
    deviceAllocatorType: Int32,
    memoryType: Int32,
    out: CPointer<CPointer<OrtMemoryInfo>>
): CPointer<OrtStatus>

// --- 张量操作 ---

// 用已有数据创建张量（零拷贝：直接使用传入的内存，不复制）
@C
foreign func OrtCreateTensorWithDataAsOrtValue(
    info: CPointer<OrtMemoryInfo>,
    data: CPointer<UInt8>,
    dataLen: UInt64,
    shape: CPointer<Int64>,
    shapeLen: UInt64,
    type: Int32,             // 1=FLOAT, 7=INT64
    out: CPointer<CPointer<OrtValue>>
): CPointer<OrtStatus>

// 获取张量的可变数据指针（用于读取输出）
@C
foreign func OrtGetTensorMutableData(
    value: CPointer<OrtValue>,
    out: CPointer<CPointer<UInt8>>
): CPointer<OrtStatus>
```
OrtCreateTensorWithDataAsOrtValue 是零拷贝接口，直接使用用户已分配的内存作为张量数据，避免额外的内存复制，对推理延迟敏感的场景至关重要。

3.3.4 推理执行
```cj
// --- 推理执行 ---

// 获取模型输入/输出名称
@C
foreign func OrtSessionGetInputName(
    session: CPointer<OrtSession>,
    index: UInt64,
    allocator: CPointer<OrtAllocator>,
    out: CPointer<CString>
): CPointer<OrtStatus>

@C
foreign func OrtSessionGetOutputName(
    session: CPointer<OrtSession>,
    index: UInt64,
    allocator: CPointer<OrtAllocator>,
    out: CPointer<CString>
): CPointer<OrtStatus>

// 获取输入/输出数量
@C
foreign func OrtSessionGetInputCount(
    session: CPointer<OrtSession>,
    out: CPointer<UInt64>
): CPointer<OrtStatus>

@C
foreign func OrtSessionGetOutputCount(
    session: CPointer<OrtSession>,
    out: CPointer<UInt64>
): CPointer<OrtStatus>

// 执行推理
// inputNames/outputNames: 字符串指针数组
// inputValues/outputValues: OrtValue 指针数组
@C
foreign func OrtRun(
    session: CPointer<OrtSession>,
    runOptions: CPointer<OrtRunOptions>,
    inputNames: CPointer<CString>,
    inputValues: CPointer<CPointer<OrtValue>>,
    inputCount: UInt64,
    outputNames: CPointer<CString>,
    outputCount: UInt64,
    outputValues: CPointer<CPointer<OrtValue>>
): CPointer<OrtStatus>
```
3.3.5 资源释放
```cj
// --- 资源释放（每个创建函数都有对应的释放函数） ---

@C
foreign func OrtReleaseEnv(env: CPointer<OrtEnv>)
@C
foreign func OrtReleaseSession(session: CPointer<OrtSession>)
@C
foreign func OrtReleaseSessionOptions(options: CPointer<OrtSessionOptions>)
@C
foreign func OrtReleaseMemoryInfo(info: CPointer<OrtMemoryInfo>)
@C
foreign func OrtReleaseValue(value: CPointer<OrtValue>)
@C
foreign func OrtReleaseStatus(status: CPointer<OrtStatus>)
```
3.4 仓颉安全封装层
FFI 层的函数直接暴露了 C 指针和 unsafe 调用，不便于上层使用。我们需要一个安全封装层来处理类型转换、错误检查和资源生命周期。

```cj
// f_hydra/src/bge_engine.cj

import std.ffi.CPointer
import std.collections.HashMap
import f_hydra.onnx_types
import f_hydra.onnx_bridge

// 推理引擎的错误类型
enum BgeEngineError {
    InitError(String)
    TokenizeError(String)
    InferenceError(String)
    OutputError(String)
}

// BGE-M3 ONNX 推理引擎
class BgeEngine {
    private let env: CPointer<OrtEnv>
    private let session: CPointer<OrtSession>
    private let allocator: CPointer<OrtAllocator>
    private let memInfo: CPointer<OrtMemoryInfo>

    // 输入/输出元数据（初始化时缓存，避免每次推理都查询）
    private let inputNames: Array<CString>
    private let outputNames: Array<CString>
    private let inputCount: UInt64
    private let outputCount: UInt64

    // --- 初始化 ---
    init(modelPath: String, numThreads: Int64 = 4) throws {
        // 1. 创建环境
        // 创建会话选项
        // 设置线程数
        // 2. 创建会话
        // 3. 获取输入/输出元数据
        // 获取分配器和内存信息
    }
```
在初始化方法中，按步骤创建 ONNX Runtime 环境、配置会话选项、加载模型、获取输入输出元数据：

```cj
    init(modelPath: String, numThreads: Int64 = 4) throws {
        // 1. 创建 ONNX Runtime 环境
        var envPtr = CPointer<CPointer<OrtEnv>>()
        var envStatus = unsafe {
            OrtCreateEnv(3, "f_hydra".toCString(), envPtr)  // 3 = ORT_LOGGING_LEVEL_ERROR
        }
        // 检查状态...

        this.env = envPtr.read()
        // 2. 创建会话选项
        // 3. 设置线程数和优化级别
        // 4. 创建推理会话
        // 5. 获取输入/输出名称（缓存）
        // ...
    }

    // --- 推理接口 ---
    func encode(text: String): BgeOutput {
        // 1. Tokenize: 文本 → input_ids + attention_mask
        let tokens = this.tokenize(text)

        // 2. 创建输入张量
        let inputValues = this.createInputTensors(tokens)

        // 3. 执行推理
        let outputValues = this.runInference(inputValues)

        // 4. 解析输出
        return this.parseOutputs(outputValues)
    }

    // --- 释放资源 ---
    func close() {
        // 释放 session、env、allocator 等 C 侧资源
    }
}
```
错误处理：每个 ONNX Runtime C API 调用都返回 OrtStatus*。安全封装层应在每次调用后检查状态，如果失败则提取错误信息并抛出仓颉异常。空指针（nullptr）也需要显式检查。FFI 调用必须包裹在 unsafe 块中。

3.5 编译与链接配置
在 cjpm.toml 中指定链接的 ONNX Runtime 动态库：

```toml
[package]
name = "f_hydra"
version = "0.1.0"

[build]
link-libs = ["onnxruntime"]

[profile.release]
opt-level = 2
```
确保动态库在系统搜索路径中：

```bash
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
```
四、BGE-M3 ONNX 模型输出解析
4.1 Tokenizer 处理
模型的输入为经过 tokenizer 处理的 input_ids 和 attention_mask。BGE-M3 使用 XLM-RoBERTa 的 tokenizer，底层基于 SentencePiece 分词器，词表大小为 250,002。

由于仓颉生态中暂无 SentencePiece 原生实现，Tokenizer 建议采用以下方案之一：

方案 A（推荐）：通过 FFI 调用 HuggingFace Tokenizers C 库

HuggingFace 的 tokenizers 库提供了 C API，可通过 FFI 直接调用。

方案 B（备选）：在仓颉中实现基于 JSON 词表的简化 Tokenizer

将 tokenizer.json 文件加载为 HashMap<String, Int64>，实现基于词表的最长匹配分词。

4.2 输入格式
BGE-M3 ONNX 模型的输入：

| 输入名称 | 形状 | 数据类型 | 说明 |
|:---|:---|:---|:---|
| input_ids | [batch_size, seq_len] | Int64 | 文本分词后的 token ID 序列 |
| attention_mask | [batch_size, seq_len] | Int64 | 1 表示有效 token，0 表示 padding |

4.3 输出格式
BGE-M3 ONNX 模型输出三个张量，按以下顺序排列：

| 索引 | 名称 | 形状 | 数据类型 | 说明 |
|:---|:---|:---|:---|:---|
| 0 | 密集向量 (Dense) | [batch_size, dim] | Float32 | 取 [CLS] token 的隐藏状态并做归一化 |
| 1 | 稀疏向量 (Sparse) | [batch_size, seq_len, 1] | Float32 | 每个 token 的词汇权重，需压缩去零 |
| 2 | 多向量 (ColBERT) | [batch_size, seq_len, dim] | Float32 | 每个 token 的归一化嵌入，用于 MaxSim 计算 |

输出解析关键处理：

```cj
struct BgeOutput {
    denseVec: Array<Float32>           // 密集向量 [dim]
    sparseVec: HashMap<Int64, Float32> // 稀疏向量 {tokenID: weight}
    colbertVecs: Array<Array<Float32>> // 多向量 [numTokens × dim]
}

// 解析稀疏输出：只保留非零权重、过滤特殊 token
// 特殊 token：cls_token_id, eos_token_id, pad_token_id, unk_token_id
// 对于重复 token，保留最大权重
func parseSparseOutput(rawSparse: Array<Float32>, inputIds: Array<Int64>,
                       clsId: Int64, eosId: Int64,
                       padId: Int64, unkId: Int64): HashMap<Int64, Float32> {
    var result = HashMap<Int64, Float32>()
    let unusedTokens = [clsId, eosId, padId, unkId]
    for i in 0..inputIds.size {
        let tokenId = inputIds[i]
        let weight = rawSparse[i]
        if (!unusedTokens.contains(tokenId) && weight > 0.0) {
            if (!result.contains(tokenId) || weight > result[tokenId]) {
                result[tokenId] = weight
            }
        }
    }
    return result
}
```
这个解析逻辑与 FlagEmbedding 官方提供的 process_token_weights 函数一致：过滤掉特殊 token（CLS、EOS、PAD、UNK），并仅保留权重大于 0 的 token；对于同一 token ID 出现多次的情况，取最大权重。

4.4 推理结果与索引的对接
BgeEngine 输出的 BgeOutput 结构体可直接传递给 f_hydra 模块中对应的索引构建器和检索器：

```text
BgeOutput.denseVec    → DenseIndexer.buildIndex()      → HNSW 图索引（Faiss C API）
BgeOutput.sparseVec   → SparseIndexer.buildIndex()     → 倒排索引（仓颉原生）
BgeOutput.colbertVecs → ColBERTIndexer.buildIndex()    → 质心倒排索引（Faiss IVF+PQ）
```
检索时流程对称：查询文本 → BgeEngine.encode() → 三路 Retriever.search() → 融合排序。

五、仓颉 FFI 的类型映射与注意事项
5.1 核心类型映射
仓颉与 C 之间遵循严格的类型映射关系。foreign 声明的函数，参数和返回类型必须符合该映射规则。

| C 类型 | 仓颉类型 | 说明 |
|:---|:---|:---|
| int32_t | Int32 | 32 位有符号整数 |
| int64_t | Int64 | 64 位有符号整数 |
| uint32_t | UInt32 | 32 位无符号整数 |
| uint64_t | UInt64 | 64 位无符号整数 |
| float | Float32 | 32 位浮点数 |
| double | Float64 | 64 位浮点数 |
| const char* | CString | 以空字符结尾的 C 字符串 |
| T* | CPointer<T> | 指向 C 类型 T 的指针 |
| struct T* | CPointer<@C struct T> | 指向 C 结构体的不透明指针 |

5.2 关键注意事项
unsafe 块必不可少：所有 FFI 调用必须在 unsafe 块中进行，仓颉编译器会强制检查，否则产生编译错误。

内存管理边界：仓颉侧分配的内存（如通过 LibC.mallocCString 分配的字符串）必须手动释放；C 侧分配的内存（如 ONNX Runtime 的输出张量）也需调用对应的 Release 函数释放，不能依赖仓颉 GC 自动回收。

foreign 函数仅作声明：foreign 修饰的函数只能有声明、不能有实现，编译器会报错。

空指针检查：每次 FFI 调用返回的 CPointer<T> 在使用前都应检查是否为空。

栈溢出风险：仓颉虽提供了栈扩容能力，但 FFI 进入 C 函数后实际使用的栈大小仓颉无法感知，仍存在栈溢出风险，必要时需调整 cjStackSize 配置。

六、完整文件结构
```text
f_hydra/
├── src/
│   ├── onnx_types.cj          # 不透明类型声明（OrtEnv、OrtSession 等）
│   ├── onnx_bridge.cj         # ONNX Runtime C API FFI 声明
│   ├── bge_engine.cj          # BgeEngine 安全封装类
│   ├── faiss_types.cj         # Faiss 不透明类型声明
│   ├── hnsw_bridge.cj         # Faiss HNSW C API FFI 声明
│   ├── dense_index.cj         # 稠密向量索引封装
│   ├── sparse_index.cj        # 稀疏向量索引实现（仓颉原生）
│   ├── colbert_index.cj       # 多向量索引封装
│   ├── fusion.cj              # 融合排序层（RRF / 加权融合）
│   └── engine.cj              # 顶层 HybridSearchEngine
├── models/
│   ├── bge-m3-onnx/           # 转换后的 ONNX 模型文件
│   │   └── model.onnx
│   └── tokenizer.json         # Tokenizer 词表文件
├── cjpm.toml                  # 项目配置（含 link-libs）
└── README.md
```
七、总结
本文档涵盖了三项关键工作：

| 步骤 | 关键操作 | 产物 |
|:---|:---|:---|
| 下载模型 | git clone 或 modelscope snapshot_download | BGE-M3 原始权重 |
| 转换 ONNX | optimum-cli export onnx | model.onnx |
| 仓颉 FFI 接入 | 声明 @C foreign 函数 + 安全封装层 | BgeEngine 可调用类 |

在 f_hydra 模块的架构中，bge_engine.cj 将作为底层嵌入引擎，为稠密、稀疏、多向量三种索引提供统一的向量化接口。上层 HybridSearchEngine 通过组合 BgeEngine 和三类 Indexer/Retriever，最终实现完整的混合检索能力。

## 有和没有GPU访问BGE-M3的对比
有GPU与无GPU两种场景下，访问BGE-M3嵌入模型的完整方案对比。

一、有GPU场景方案
方案1：基于TEI（Text Embeddings Inference）的高性能部署
适用场景：生产环境、高吞吐、低延迟要求

TEI是Hugging Face官方推出的嵌入模型专用推理服务，对BGE-M3有深度适配。

部署步骤：

```bash
# 拉取Docker镜像（需NVIDIA Docker环境）
model=BAAI/bge-m3
volume=$PWD/data

docker run -p 8080:80 \
  --gpus all \
  -v $volume:/data \
  ghcr.io/huggingface/text-embeddings-inference:turing-1.4 \
  --model-id $model
```
关键特性：

原生支持Flash Attention和CUDA内核优化，在主流GPU上可获得显著的吞吐提升

支持最大8192个token的输入，自动分批与动态padding

实测数据：在RTX 3090上，单卡推理文本编码速度可在优化后获得数倍提升

适用硬件： NVIDIA GPU（推荐至少8GB显存），16GB以上更佳

仓颉访问方式： 通过HTTP客户端调用REST API（/embed 端点），无需FFI集成

方案2：基于ONNX Runtime + GPU Execution Provider
适用场景：已有ONNX Runtime基础设施、需要多后端灵活切换

部署步骤：

```bash
# 1. 安装ONNX Runtime GPU版
pip install onnxruntime-gpu

# 2. 安装CUDA Toolkit和cuDNN
# 3. 导出ONNX模型（参见前文文档）
optimum-cli export onnx \
    --model BAAI/bge-m3 \
    --task feature-extraction \
    --device cuda \
    --output ./bge-m3-onnx
```
在仓颉中通过FFI调用：

仓颉侧通过FFI绑定ONNX Runtime C API，在创建Session时指定GPU Execution Provider。ONNX Runtime支持CUDA、TensorRT、OpenVINO等多种Execution Provider，实现硬件自适应加速。实测中，ONNX Runtime的GPU推理延迟可与TensorRT接近（误差<5%）。

```cj
// 核心FFI声明
@C
foreign func OrtSessionOptionsAppendExecutionProvider_CUDA(
    options: CPointer<OrtSessionOptions>,
    deviceId: Int32
): CPointer<OrtStatus>
```
适用硬件： NVIDIA GPU（需安装CUDA Toolkit和cuDNN）

方案3：基于vLLM + BGE-M3嵌入模式
适用场景：已部署vLLM服务、统一LLM和Embedding推理

vLLM在2024-2025年新增了对嵌入模型的支持，可通过统一的服务框架同时提供LLM和Embedding能力。

```bash
# 启动vLLM嵌入服务
vllm serve BAAI/bge-m3 \
  --task embed \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.9
```
仓颉访问方式： 通过HTTP客户端调用OpenAI兼容的 /v1/embeddings 端点

二、无GPU场景（纯CPU）方案
方案1：基于ONNX Runtime + CPU优化
适用场景：中等CPU配置、无需GPU硬件、已有ONNX工作流

这是目前生产环境中最成熟的纯CPU方案之一。ONNX Runtime在ResNet50推理测试中，CPU推理速度比原生PyTorch快1.8倍。

部署步骤：

```bash
# 安装CPU版ONNX Runtime
pip install onnxruntime

# 导出ONNX模型（--device cpu）
optimum-cli export onnx \
    --model BAAI/bge-m3 \
    --task feature-extraction \
    --device cpu \
    --output ./bge-m3-onnx
```
仓颉FFI访问： 与前文文档中描述的方式完全一致，无需任何GPU相关配置。ONNX Runtime支持20+硬件后端（CPU/GPU/NPU），代码无需修改即可在不同硬件间切换。

适用硬件： 建议至少8核CPU、16GB内存。在8核16G服务器上，每次请求约需3-4秒。

方案2：基于OpenVINO加速（Intel CPU优化）
适用场景：Intel CPU（尤其是至强、酷睿系列），需要极致CPU推理性能

OpenVINO是Intel推出的深度学习推理优化工具包，针对Intel CPU架构做了深度指令集优化（AVX-512、VNNI等）。其推理引擎支持动态设备选择与多后端自适应调度。

部署步骤：

```bash
# 安装OpenVINO
pip install openvino
```
```python
# 转换模型为OpenVINO IR格式
from optimum.intel import OVModelForFeatureExtraction

model = OVModelForFeatureExtraction.from_pretrained(
    "BAAI/bge-m3",
    export=True
)
model.save_pretrained("./bge-m3-ov")
```
仓颉访问方式：

通过FFI调用OpenVINO C API（ov_core_compile_model、ov_infer_request_*系列函数）：

```cj
// 核心FFI声明
@C
foreign func ov_core_compile_model(
    core: CPointer<OvCore>,
    model: CPointer<OvModel>,
    deviceName: CString,
    compiledModel: CPointer<CPointer<OvCompiledModel>>
): CPointer<OvStatus>
```
适用硬件： Intel CPU（Core i7/i9/Xeon），需支持AVX2或AVX-512指令集

方案3：基于GGUF量化（llama.cpp生态）
适用场景：资源极度受限的设备、边缘部署、ARM架构

BGE-M3已有社区转换的GGUF格式模型，可通过llama.cpp进行量化推理，大幅降低内存占用。

部署步骤：

```bash
# 下载预转换的GGUF模型
wget https://huggingface.co/ChristianAzinn/bge-m3-Q8_0-GGUF/resolve/main/bge-m3-q8_0.gguf

# 使用llama.cpp的embedding功能
./llama-embedding \
    -m bge-m3-q8_0.gguf \
    -p "Your text here" \
    --pooling cls \
    -ngl 0  # 纯CPU模式，设为0层GPU
```
仓颉访问方式： 通过FFI调用llama.cpp的C API，或直接调用编译后的可执行文件。

适用硬件： 最低可在4核CPU、8GB内存的机器上运行，适合边缘设备和低成本服务器

方案4：基于Xinference框架的纯CPU方案
适用场景：需要统一模型管理、避免GPU资源争抢

Xinference框架提供统一的模型管理，可显式指定模型运行在CPU上，避免GPU资源不足时的问题。

```bash
# 安装并启动Xinference
pip install xinference
xinference-local --host 0.0.0.0 --port 9997

# 部署BGE-M3到CPU
xinference launch \
    --model-name bge-m3 \
    --model-format pytorch \
    --device cpu
```
仓颉访问方式： 通过HTTP客户端调用Xinference REST API

三、GPU vs CPU 方案对比总览
| 维度 | GPU方案 | CPU方案 |
|:---|:---|:---|
| 推荐引擎 | TEI / ONNX Runtime GPU / vLLM | ONNX Runtime CPU / OpenVINO / GGUF |
| 推理延迟（单次） | 10-50ms | 100ms - 4s（取决于硬件和方案） |
| 并发吞吐 | 高（千级QPS） | 中（数十到百级QPS） |
| 内存占用 | 模型加载约2.2GB显存（FP16） | 模型加载约4GB内存（FP32），GGUF可降至1-2GB |
| 硬件最低要求 | NVIDIA GPU 8GB显存起 | 8核CPU、16GB内存 |
| 优化手段 | Flash Attention、CUDA内核、TensorRT | OpenVINO指令集优化、量化、批处理 |
| 仓颉接入方式 | FFI + C API 或 HTTP API | FFI + C API 或 HTTP API |
| 仓颉侧代码差异 | 指定GPU Execution Provider | 默认CPU执行，无需额外配置 |

四、仓颉侧统一接口设计建议
无论底层采用何种推理后端（GPU或CPU、ONNX Runtime或OpenVINO），建议在仓颉层抽象统一接口：

```cj
// f_mix/src/bge_backend.cj
interface BgeBackend {
    func encode(text: String): BgeOutput
    func close()
}

// ONNX Runtime 后端（CPU/GPU共用同一代码路径）
class OrtBgeBackend: BgeBackend {
    init(modelPath: String, useGPU: Bool = false) {
        // useGPU=true 时附加 CUDA Execution Provider
    }
}

// OpenVINO 后端
class OvBgeBackend: BgeBackend {
    init(modelPath: String) {
        // 仅CPU模式
    }
}

// HTTP 后端（适用于TEI、vLLM、Xinference等）
class HttpBgeBackend: BgeBackend {
    init(endpoint: String) {
        // 调用REST API
    }
}
```
这样上层 HybridSearchEngine 完全不感知底层推理后端是GPU还是CPU，仅通过初始化时传入不同Backend实例即可切换。ONNX Runtime支持的Execution Provider机制天然保证同一套FFI声明在不同硬件上复用，这也是当前架构设计的核心优势。

五、方案选择决策树
```text
是否有NVIDIA GPU且显存≥8GB？
  ├─ 是 → 是否追求最高吞吐和最低延迟？
  │       ├─ 是 → 使用 TEI 或 vLLM（HTTP API方式）
  │       └─ 否 → 使用 ONNX Runtime + CUDA（FFI方式）
  └─ 否 → 是否为Intel CPU？
          ├─ 是 → 使用 OpenVINO（FFI方式，指令集深度优化）
          └─ 否 → 资源是否极度受限（<8GB内存）？
                  ├─ 是 → 使用 GGUF 量化版（llama.cpp生态）
                  └─ 否 → 使用 ONNX Runtime CPU（FFI方式，兼容性最广）
```
对于 f_mix 模块的默认构建配置，建议优先支持 ONNX Runtime 作为统一后端（通过Execution Provider切换CPU/GPU），OpenVINO 作为Intel CPU的可选加速后端，TEI HTTP 作为生产环境高性能部署的可选后端。

---

## 跨平台统一推理接口设计

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

---

### 统一融合排序详解

#### 概述

"统一融合排序"是混合检索流水线的最后一环。它要解决的问题是：**稀疏、稠密、ColBERT 三种检索方式产生的得分量纲完全不同，如何公平地把它们融合成一个最终的全局排序。**

进入融合阶段时，我们手上有经过精排的候选文档池（例如 200 篇），每篇文档同时拥有三个得分：

- **稀疏得分**（词汇权重累加，范围不定）
- **稠密得分**（余弦相似度，通常在 [-1, 1] 或 [0, 1]）
- **ColBERT 得分**（MaxSim 总和，范围 [0, 序列长度]）

统一融合排序的任务就是利用这三个得分，输出一份融合后的 Top‑K 排序结果。

---

#### 两种融合策略

根据架构设计文档 7.1 节，`f_hydra` 支持两种可切换的融合策略：

| 策略 | 核心思想 | 优点 | 适用场景 |
| :--- | :--- | :--- | :--- |
| **RRF (Reciprocal Rank Fusion)** | 只使用排名，不看原始分数 | 免校准，完全免疫量纲问题 | 默认策略，绝大多数场景 |
| **归一化加权融合** | 先归一化再加权求和 | 可对三路检索赋予不同重要性 | 有明确先验权重的场景 |

---

#### 策略一：倒数排名融合 (RRF)

##### 原理

RRF 不关心分数的绝对大小，只关心在一路检索中，文档的相对排名。其公式为：

$$
\text{RRF\_Score}(d) = \frac{1}{k + \text{rank}_{\text{sparse}}(d)} + \frac{1}{k + \text{rank}_{\text{dense}}(d)} + \frac{1}{k + \text{rank}_{\text{colbert}}(d)}
$$

- `rank_x(d)`：文档 d 在 x 检索路中的排名（1 为最高）。
- `k`：平滑参数，默认 **60**。k 越大，排名差异的影响越小。

##### 实现步骤

1. **路内排名**：在精排候选池内，分别按稀疏、稠密、ColBERT 得分降序排列，得到每篇文档的三个独立排名。
2. **RRF 计算**：对池内每篇文档，代入公式计算 RRF 总分。
3. **全局排序**：按 RRF 总分从高到低排序，取前 `topK` 个文档输出。

##### 示例

假设精排池有 3 篇文档，k = 60：

| 文档 | 稀疏排名 | 稠密排名 | ColBERT排名 | RRF 总分 | 最终排名 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Doc_A | 1 | 3 | 2 | 1/61 + 1/63 + 1/62 = 0.0484 | 2 |
| Doc_B | 3 | 1 | 1 | 1/63 + 1/61 + 1/61 = 0.0492 | **1** |
| Doc_C | 2 | 2 | 3 | 1/62 + 1/62 + 1/63 = 0.0481 | 3 |

> 说明：所有排名和计算都在精排候选池内部完成，与全库排名无关。

---

#### 策略二：归一化加权融合

##### 原理

当用户清楚每一路检索的重要程度时，可以将原始得分归一化到同一尺度，再按权重组合。公式为：

$$
\text{Weighted\_Score}(d) = \alpha \cdot \text{norm}(S_{\text{dense}}) + \beta \cdot \text{norm}(S_{\text{sparse}}) + \gamma \cdot \text{norm}(S_{\text{colbert}})
$$

- `norm(S)` 为 **Min‑Max 归一化**，将分数映射至 [0, 1] 区间。
- 权重 `α, β, γ` 由用户配置，默认均为 `1/3`。

##### 实现步骤

1. **路内归一化**：分别对稀疏、稠密、ColBERT 三路得分执行 Min‑Max 归一化：
`norm(S) = (S - min) / (max - min)`

其中 `min` 和 `max` 从当前精排候选池内统计。
2. **加权求和**：按配置的权重计算每篇文档的加权总分。
3. **全局排序**：按加权总分从高到低排序，取前 `topK` 篇文档。

##### 示例

假设稠密得分范围为 [0.65, 0.92]，稀疏范围为 [8.2, 15.0]，ColBERT 范围为 [19.5, 25.8]，权重均为 1/3：

| 文档 | 稠密(原始→归一化) | 稀疏(原始→归一化) | ColBERT(原始→归一化) | 加权总分 | 排名 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Doc_A | 0.87 → 0.815 | 12.5 → 0.632 | 22.1 → 0.413 | 0.620 | 2 |
| Doc_B | 0.92 → 1.000 | 8.2 → 0.000 | 19.5 → 0.000 | 0.333 | 3 |
| Doc_C | 0.65 → 0.000 | 15.0 → 1.000 | 25.8 → 1.000 | **0.667** | **1** |

> 注意：因样本量小，Doc_B 的稀疏和 ColBERT 得分恰好是最小值，归一化后为 0，这是极端的简化示意。

---

#### 精排候选池内的分数对齐

一个关键设计点是：**融合层的所有排名和归一化计算均在精排候选池内部完成，不会回到全库尺度。**

- **RRF 模式**：排名是基于候选池内文档的相对比较，而非全库排名。
- **加权模式**：Min‑Max 归一化的最小/最大值也从候选池内统计。

这样既保证了三路得分的公平比较，也避免了全库排名带来的额外开销，逻辑自洽。

---

#### 与多阶段流程的关系

统一融合排序是 `7.2 融合执行流程` 的最后阶段，前面还有：

1. **并行粗排召回**：稀疏和稠密检索引擎在全库并行检索，各自返回 Top‑K（如 100），合并为粗排候选池。
2. **漏斗式精排**：ColBERT 在粗排候选池上执行精细 MaxSim 计算，得到各文档的 ColBERT 得分。

融合层在拿到三路得分后，才执行上述 RRF 或加权融合，输出最终的 Top‑K。

> 为什么不提前融合？  
> 因为 ColBERT 计算成本高，不能在全库执行；如果先融合稀疏和稠密再送 ColBERT，可能会导致稠密高分但稀疏低分的文档被过早剪枝，ColBERT 失去看到它们的机会。因此让 ColBERT 最后参与，再统一融合，是最合理的编排。

---

#### 仓颉实现概览

```cj
enum FusionStrategy { RRF, WEIGHTED }
class FusionLayer {

 func fuse(
     candidates: Array<ScoredDoc>,   // 必须包含 denseScore, sparseScore, colbertScore
     strategy: FusionStrategy,
     weights: ?Array<Float64>,
     topK: Int64
 ): Array<ScoredDoc> {
     match (strategy) {
         case FusionStrategy.RRF      => fuseRRF(candidates, topK)
         case FusionStrategy.WEIGHTED => fuseWeighted(candidates, weights, topK)
     }
 }

 private func fuseRRF(candidates: Array<ScoredDoc>, topK: Int64): Array<ScoredDoc> {
     // 1. 计算三个维度的排名
     let rankSparse = computeRanks(candidates, doc => doc.sparseScore)
     let rankDense  = computeRanks(candidates, doc => doc.denseScore)
     let rankColbert = computeRanks(candidates, doc => doc.colbertScore)
     // 2. 计算 RRF 得分 (k = 60)
     for doc in candidates {
         doc.finalScore = 1.0/(60.0 + rankSparse[doc.id]) 
                        + 1.0/(60.0 + rankDense[doc.id]) 
                        + 1.0/(60.0 + rankColbert[doc.id])
     }
     // 3. 按 finalScore 降序排序，取前 topK
     return candidates.sortDescendingBy(doc => doc.finalScore).take(topK)
 }

 private func fuseWeighted(candidates: Array<ScoredDoc>, 
                           weights: Array<Float64>, 
                           topK: Int64): Array<ScoredDoc> {
     // 1. 对三路得分 Min-Max 归一化
     let normDense  = minMaxNorm(candidates, doc => doc.denseScore)
     let normSparse = minMaxNorm(candidates, doc => doc.sparseScore)
     let normColbert = minMaxNorm(candidates, doc => doc.colbertScore)
     // 2. 加权求和
     let (alpha, beta, gamma) = (weights[0], weights[1], weights[2])
     for doc in candidates {
         doc.finalScore = alpha * normDense[doc.id] 
                        + beta  * normSparse[doc.id] 
                        + gamma * normColbert[doc.id]
     }
     // 3. 按 finalScore 降序排序，取前 topK
     return candidates.sortDescendingBy(doc => doc.finalScore).take(topK)
 }
}
```

#### 总结
RRF：推荐默认使用，无需调参，仅依赖排名，能自动平衡三路信号。

归一化加权：在有明确先验（如"稀疏检索最重要"）时使用，需要提供验证过的权重。

计算边界：所有融合计算都限制在精排候选池内，既不增加全库开销，又保证三路公平。

统一融合排序使 f_hydra 能够真正融合"关键词匹配、语义理解、精细交互"三种检索方式的长处，输出兼具高召回和高精度的最终结果。
