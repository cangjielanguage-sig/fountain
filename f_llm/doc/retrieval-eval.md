# 检索质量评测

单测能验证「排序逻辑对不对」，验证不了「语义质量好不好」——后者依赖 embedding 模型版本与网络，
同一批 query 换个模型排名就会变。所以拆成两层：

| 层 | 位置 | 是否进 CI | 测什么 |
|---|---|---|---|
| 骨架 | `src/loom/RetrievalEval_test.cj` | 是（确定性） | 指标算得对、分层算得对、数据集没退化 |
| 真实模型 | `src/loom/RetrievalEvalRunner.cj` + `eval/run_eval.sh` | 否（手动 / nightly） | 真实 embedding 下的 recall / MRR / nDCG / 负样本通过率 |

## 四个指标

| 指标 | 含义 | 什么时候看它 |
|---|---|---|
| `recall@1` | 第一名就命中的比例 | 最直观：用户看到的第一个结果对不对 |
| `recall@5` | 前五名里有命中的比例 | 上下文能塞 5 条时够不够用 |
| `MRR` | 命中排名的倒数和 | 比较「排第 2 还是第 5」，但只看第一个命中 |
| `nDCG@5` | 位置加权的命中质量，按理想排序归一 | **多相关样本**和「排得靠不靠前」；`recall` 看不出这些 |

`nDCG@5` 的定义（二值相关）：

```
DCG  = Σ_{i=1..5} gain_i / log2(i+1)      gain_i = 1 表示第 i 位命中期望文档
IDCG = 期望文档全部排在最前时的 DCG
nDCG = DCG / IDCG
```

两个直接推论：

- 单相关样本命中第 r 名 → `nDCG = 1/log2(r+1)`（第 1 名 1.0、第 2 名 0.63、第 3 名 0.5）；
- 多相关样本命中 3 个中的 1 个 → `nDCG` 明显低于 1，而 `recall@5` 已经是满分——
  **这正是 `recall` 掩盖的问题**，`multi` 主题就是为它准备的。

## 数据格式

`eval/retrieval_corpus.tsv`（`id \t 标题 \t 正文`，50 条）：

```
d01	日报助手	日报用三段式：先给结论，再给关键数据，最后给建议。
```

`eval/retrieval_queries.tsv`（`query \t 期望 id[,期望 id] \t 主题`，612 条正样本 + 10 条负样本）：

```
日报怎么写	d01	report
一天干完活，怎么向上级交代自己做了什么、结果如何	d01	hard
一天的交待和每周的汇总，内容怎么分工	d01,d02	multi
量子计算机怎么造	-	negative
```

| 约定 | 说明 |
|---|---|
| `#` 开头 | 注释；空行忽略 |
| 期望列写多个 id | **多相关标注**：命中任一即算对，nDCG 按理想排序归一 |
| 期望列写 `-` | **负样本**：期望检索不到任何文档，用来验证 `minScore` 阈值 |
| 主题列 | 分层统计用；负样本固定 `negative` |

三类正样本的区别：

| 主题 | 数量 | 特征 | 用途 |
|---|---|---|---|
| 10 个业务主题（`report`/`code`/…） | 300（10 × 30） | 模板化问法，与文档标题高度重合 | 守住链路、定位「哪类主题变差」 |
| `hard` | **300**（50 文档 × 6） | **不含目标标题的实词**，只能靠语义 | **区分模型语义能力** |
| `multi` | **12** | 一条 query 对应 2~3 个都算对的文档 | 验证多相关标注与 nDCG |

## 真实基线（bge-m3，本机 8000）

```
encoder=DefaultEmbedder（读 llm_embeddingUrl）  corpus=50  cases=622
```

| minScore | 全部 recall@1 / @5 / MRR / nDCG | **hard** r@1 / r@5 / nDCG | multi r@1 / r@5 | 负样本通过 |
|---|---|---|---|---|
| 0.2 | 68.62% / 85.62% / 75.37% / 77.54% | **40.00% / 70.66% / 56.60%** | 58.33% / 100% | **0%** |
| **0.5** | 68.46% / 83.82% / 74.54% / 76.48% | **39.66% / 67.66% / 54.76%** | 58.33% / 83.33% | **90%** |

对照：同一个 `hard` 集合，**字符重合检索器只有 22%**，bge-m3 到 40%——这才是「换模型有没有用」的证据。

三条结论：

1. **`minScore` 取 0.5**：从 0.2 提到 0.5 只掉约 2 点 `recall@5`，负样本通过率却从 0% 拉到 90%。
   bge-m3 对无关文本也给 0.4~0.5 的余弦，阈值 0.2 等于不过滤。
2. **全局数字会被模板化样本拉高**：300 条模板化基本满分，把 `hard` 的 40% 平均成了 68%。
   判断模型只看 `hard` 那一行。
3. **`multi` 暴露了 `recall` 的盲区**：`recall@5` 已 83%、`nDCG` 只有 53%——
   命中一个就满分，但漏掉另外两个的代价只有 nDCG 记得。

## 跑真实模型

```bash
eval/run_eval.sh                                   # 默认 bge-m3 + 127.0.0.1:8000
fllm_evalMinScore=0.5 eval/run_eval.sh             # 调阈值
llm_embeddingUrl=http://host/v1/embeddings fllm_evalModel=bge-m3 eval/run_eval.sh
```

脚本做的事：设 `fllm_runEval=1` → `cjpm test --filter=RetrievalEvalManual_test` →
报告写到 `/tmp/fllm_retrieval_eval.txt`，直接 `cat` 即可。

等价的 Cangjie 入口：

```cangjie
let outcome = RetrievalEvalRunner.run(InMemoryMetaStore(), './eval', 'bge-m3', minScore: 0.5f64)
println(outcome.report)
// outcome.embedFailures 必须为 0，否则本次测的是关键词而不是向量
```

输出（`by topic` 按 recall@1 升序，最差的排前面）：

```
== all ==
cases=612 topK=5
recall@1=68.46% recall@5=83.82% mrr=74.54% ndcg@5=76.48%
negatives=10 pass=90.0%
by topic (worst first):
  hard       n=300 r@1=39.66% r@5=67.66% mrr=50.45% ndcg=54.76%
  multi      n=12 r@1=58.33% r@5=83.33% mrr=69.44% ndcg=53.10%
  monitor    n=30 r@1=80.00% r@5=100.00% mrr=90.00% ndcg=92.61%
  db         n=30 r@1=96.66% r@5=100.00% mrr=98.33% ndcg=98.76%
  ...
```

### 一个必须知道的坑：编码失败会静默退回关键词

`SkillCatalog.search` 在编码失败时**整体退回关键词**（可用性优先），这会让「装了编码器却在跑关键词」
完全看不出来。第一次跑出的 `hard=6%` 就是这么来的——`SkillCatalog.embeddingEncoder('bge-m3')`
依赖 `LLMConfs` 里的平台配置，没配时抛异常，被测的其实是关键词。

两道防线：

1. `SkillCatalog.embedFailures()` / `embedFailureDetail()` 暴露失败计数（query 侧 / 技能侧分开）；
2. `RetrievalEvalRunner` 把它带进 `EvalOutcome`，`RetrievalEvalManual_test` 断言 **必须为 0**。

评测入口因此用 `DefaultEmbedder`（读 `llm_embeddingUrl`），不用 `embeddingEncoder`。

### 只跑单主题 / 只看语义能力

```cangjie
let only = ArrayList<EvalCase>()
for(item in cases){
    if(item.topic == 'hard'){      // 换成 'db' 就是单主题
        only.add(item)
    }
}
println(RetrievalEval.evaluate(only, search, topK: 5).render('bge-m3 / hard'))
```

### 与基线比较

```cangjie
let baseline = 0.3966f64      // hard recall@1 的上一次记录
if(report.hardRecall < baseline - 0.06f64){ println('REGRESSION') }
```

| 指标 | 门槛建议 |
|---|---|
| `hard` 的 `recall@1` | **最该盯的一行**：低于基线 6 点即回归（300 条样本噪声约 ±5.7 点） |
| `hard` 的 `nDCG@5` | 低于基线 6 点即回归；比 `recall@5` 更早发现问题 |
| `recall@1` 全局 | 比基线低 5 点即回归（612 条约 ±2.9 点噪声） |
| 任一模板化主题 `recall@1` | 低 10 点即回归（单主题 30 条，阈值放宽） |
| `negatives pass` | 低于 90% 说明 `minScore` 太松（实测 0.2 时为 0%） |
| `misses` | 逐条看，尤其 `hard` 的 miss |

## 扩展数据集

1. 往 `retrieval_corpus.tsv` 加行（id 递增）；
2. **必须**往 `retrieval_queries.tsv` 加对应 query —— 测试会检查「每条语料都被至少一条 query 引用」；
3. 新业务主题要凑够 30 条，否则单主题指标不可用；
4. 加难样本时遵守：**query 里不出现目标文档标题的实词**，否则退化成模板化样本
   （测试会对比两组的字符重合命中率，差距消失就失败）；
5. 多相关样本把多个期望 id 用逗号写，并标 `multi`。

## 已知边界

| 项 | 说明 |
|---|---|
| 模板化 300 条不代表真实语言 | 每个文档 6 种问法；有真实日志后应替换 |
| `hard` 是手写场景句 | 每文档 6 条共 300 条 → 全局噪声约 ±5.7 点，能看量级、仍不够细粒度排名 |
| `multi` 只有 12 条 | 验证语义与 nDCG，不足以评估多相关场景的排序质量 |
| 二值相关 | nDCG 用的是「命中/未命中」，没有分级（很相关 vs 部分相关） |
| 不衡量「内容是否有用」 | 只有命中判定，没有人工相关性评分 |
| 负样本只有 10 条 | 只够验证阈值量级（0.2 与 0.5 的差别已很明显），不能精调 |
| 每条 query 一次 embedding 调用 | 612 条约 610 次请求；本机 bge-m3 约 2 秒跑完，远程服务需考虑限流 |
