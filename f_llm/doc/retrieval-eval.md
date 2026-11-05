# 检索质量评测

单测能验证「排序逻辑对不对」，验证不了「语义质量好不好」——后者依赖 embedding 模型版本与网络，
同一批 query 换个模型排名就会变。所以拆成两层：

| 层 | 位置 | 是否进 CI | 测什么 |
|---|---|---|---|
| 骨架 | `src/loom/RetrievalEval_test.cj` | 是（确定性） | 指标算得对、分层算得对、数据集没退化 |
| 真实模型 | `src/loom/RetrievalEvalRunner.cj` + `eval/run_eval.sh` | 否（手动 / nightly） | 真实 embedding 下的 recall / MRR / 负样本通过率 |

## 数据格式

`eval/retrieval_corpus.tsv`（`id \t 标题 \t 正文`，50 条）：

```
d01	日报助手	日报用三段式：先给结论，再给关键数据，最后给建议。
```

`eval/retrieval_queries.tsv`（`query \t 期望 id[,期望 id] \t 主题`，462 条正样本 + 10 条负样本）：

```
日报怎么写	d01	report
一天干完活，怎么向上级交代自己做了什么、结果如何	d01	hard
一天的交待和每周的汇总，内容怎么分工	d01,d02	multi
量子计算机怎么造	-	negative
```

| 约定 | 说明 |
|---|---|
| `#` 开头 | 注释；空行忽略 |
| 期望列写多个 id | **多相关标注**：命中任一即算对，MRR 取最靠前的那个 |
| 期望列写 `-` | **负样本**：期望检索不到任何文档，用来验证 `minScore` 阈值 |
| 主题列 | 分层统计用；负样本固定 `negative` |

三类正样本的区别：

| 主题 | 数量 | 特征 | 用途 |
|---|---|---|---|
| 10 个业务主题（`report`/`code`/…） | 300（10 × 30） | 模板化问法，与文档标题高度重合 | 守住链路、定位「哪类主题变差」 |
| `hard` | **150**（50 文档 × 3） | **不含目标标题的实词**，只能靠语义 | **区分模型语义能力** |
| `multi` | **12** | 一条 query 对应 2~3 个都算对的文档 | 验证多相关标注与「命中任一算对」语义 |

## 真实基线（bge-m3，本机 8000）

```
encoder=DefaultEmbedder（读 llm_embeddingUrl）  corpus=50  cases=472
```

| minScore | 全部 recall@1 / @5 / MRR | **hard** recall@1 / @5 | multi recall@1 / @5 | 负样本通过 |
|---|---|---|---|---|
| 0.2 | 81.16% / 92.20% / 85.71% | **50.00% / 76.00%** | 58.33% / 100% | **0%** |
| **0.5** | 80.95% / 90.90% / 85.80% | **49.33% / 73.33%** | 58.33% / 83.33% | **90%** |

对照：同一个 `hard` 集合，**字符重合检索器只有 22%**，bge-m3 到 50%——这才是「换模型有没有用」的证据。

两条结论：

1. **`minScore` 取 0.5**：从 0.2 提到 0.5 只掉 1.3 点 recall@5，却把负样本通过率从 0% 拉到 90%。
   bge-m3 对无关文本也会给 0.4~0.5 的余弦，阈值 0.2 等于不过滤。
2. **全局数字没有意义**：模板化 300 条是 100%，把 `hard` 的 50% 平均成了 81%。
   判断模型只看 `hard` 那一行。

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
cases=462 topK=5
recall@1=80.95% recall@5=90.90% mrr=85.80%
negatives=10 pass=90.0%
by topic (worst first):
  hard       n=150 r@1=49.33% r@5=73.33% mrr=58.84%
  multi      n=12 r@1=58.33% r@5=83.33% mrr=69.44%
  monitor    n=30 r@1=80.00% r@5=100.00% mrr=90.00%
  report     n=30 r@1=100.00% ...
```

### 一个必须知道的坑：编码失败会静默退回关键词

`SkillCatalog.search` 在编码失败时**整体退回关键词**（可用性优先），这会让「装了编码器却在跑关键词」
完全看不出来。我第一次跑出的 `hard=6%` 就是这么来的——`SkillCatalog.embeddingEncoder('bge-m3')`
依赖 `LLMConfs` 里的平台配置，没配时抛异常，被测的其实是关键词。

现在有两道防线：

1. `SkillCatalog.embedFailures()` / `embedFailureDetail()` 暴露失败计数；
2. `RetrievalEvalRunner` 把它带进 `EvalOutcome`，`RetrievalEvalManual_test` 断言 **必须为 0**，
   否则测试直接失败——宁可红，也不要拿关键词结果冒充向量结果。

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
let baseline = 0.4933f64      // hard recall@1 的上一次记录
if(report.hardRecall < baseline - 0.08f64){ println('REGRESSION') }
```

| 指标 | 门槛建议 |
|---|---|
| `hard` 的 `recall@1` | **最该盯的一行**：低于基线 8 点即回归（150 条样本噪声约 ±8 点） |
| `recall@1` 全局 | 比基线低 5 点即回归（462 条约 ±3.5 点噪声） |
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
| `hard` 是手写场景句 | 每文档 3 条，150 条 → 全局 noise ±8 点，够看量级、不够做细粒度排名 |
| `multi` 只有 12 条 | 验证语义与流程，不足以评估多相关场景的排序质量 |
| 不衡量「找到的内容是否有用」 | 只有命中判定，没有人工相关性评分 |
| 负样本只有 10 条 | 只够验证阈值量级（0.2 与 0.5 的差别已很明显），不能精调 |
| 单条 query 一次 embedding 调用 | 462 条约 460 次请求；本机 bge-m3 约 1.5 秒跑完，远程服务需考虑限流 |
