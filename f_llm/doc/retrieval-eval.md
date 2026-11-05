# 检索质量评测

单测能验证「排序逻辑对不对」，验证不了「语义质量好不好」——后者依赖 embedding 模型版本与网络，
同一批 query 换个模型排名就会变。所以拆成两层：

| 层 | 位置 | 是否进 CI | 测什么 |
|---|---|---|---|
| 骨架 | `src/loom/RetrievalEval_test.cj` | 是（确定性） | 指标算得对、分层算得对、数据集没退化 |
| 离线评测 | 本文档描述的跑法 | 否（nightly / 手动） | 真实模型下的 recall@1、recall@5、MRR、负样本通过率、按主题分层 |

## 数据格式

`eval/retrieval_corpus.tsv`（`id \t 标题 \t 正文`）：

```
d01	日报助手	日报用三段式：先给结论，再给关键数据，最后给建议。
```

`eval/retrieval_queries.tsv`（`query \t 期望 id[,期望 id] \t 主题`）：

```
日报怎么写	d01	report
报销多久能到账	d47,d46	cost
量子计算机怎么造	-	negative
```

| 约定 | 说明 |
|---|---|
| `#` 开头 | 注释；空行忽略 |
| 期望列写多个 id | 命中任一即算对 |
| 期望列写 `-` | **负样本**：期望检索不到任何文档，用来验证 `minScore` 阈值真的在挡噪声 |
| 第三列主题 | 用于分层统计；负样本固定写 `negative`，难样本固定写 `hard` |
| 难样本 | query **不含目标文档标题里的关键词**，只能靠语义匹配，例如「一天干完活怎么向上级交代」→ `d01 日报助手` |

## 当前规模

| 维度 | 数量 | 能满足的判断 |
|---|---|---|
| 语料 | 50 条（10 主题 × 5） | — |
| 模板化正样本 | 300 条（10 主题 × 30） | 全局：换模型粗判（±4 点）；单主题：±18 点区间内看趋势 |
| **难样本** | **50 条（主题 `hard`）** | **区分模型语义能力**——关键词检索在这里只有 22% |
| 负样本 | 10 条 | `minScore` 是否真的过滤掉了不相关结果 |

**为什么必须有两类正样本**：模板化 query 与文档标题高度重合，字符重合检索器就能到 96%，
它只能证明「链路没崩」，分不出模型好坏；难样本不含标题关键词，只有真正理解语义的检索器才拿得到分。

**规模与统计精度**（recall@1 的 95% 置信区间，`p̂ ± 1.96·√(p̂(1-p̂)/n)`）：

| 样本量 | 观测 85% 时真实区间 | 适合做什么 |
|---|---|---|
| 20 | 69% ~ 100% | 冒烟：只发现「崩了」 |
| **350（现状，全部正样本）** | 81% ~ 89% | **换模型粗判** |
| **50（现状，难样本子集）** | 73% ~ 97% | 看模型语义能力量级，不看小数点 |
| 500 | 82% ~ 88% | 日常回归门禁（能卡 5 点级退步） |
| 每主题 30 | 67% ~ 100% | 单主题只看趋势，不看小数点 |

要稳定检测「90% → 85%」这类 5 点退步（α=0.05、power=0.8），每组约需 **680 条**。
因此日常门禁的实践做法是：**总量指标盯大退步，真正的信号看 `misses` 与分层里垫底的主题**。

## 跑真实模型

`RetrievalEval.evaluate` 只接收一个检索函数，接什么都可以。

### 全局指标

```cangjie
// 1. 把语料灌进技能库（id 用标题代替）
for(doc in RetrievalEval.readCorpus('eval/retrieval_corpus.tsv')){
    Stores.meta().skills.upsert(Skill(0, doc.title, doc.content, '{}', version: 1))
}

// 2. 装上真实编码器
SkillCatalog.install({ => Stores.meta().skills },
                     embedder: SkillCatalog.embeddingEncoder('bge-m3'))

// 3. 跑一遍
let cases = RetrievalEval.readCases('eval/retrieval_queries.tsv')
let report = RetrievalEval.evaluate(cases, { query, topK =>
    let ids = ArrayList<String>()
    for(hit in SkillCatalog.search(query, topK: topK, minScore: 0.2)){
        ids.add(hit.title)
    }
    ids
}, topK: 5)
println(report.render('bge-m3 / skills'))
```

输出（`by topic` 按 recall@1 升序，**最差的排前面**）。下面是**最笨的字符重合检索器**跑同一份数据的实测值：
模板化主题可当作「下限基线」（真实 embedding 不该更低），`hard` 则可当作「关键词方法失效后的参照」：

```
== naive char-overlap ==
cases=350 topK=5
recall@1=85.71% recall@5=92.86% mrr=88.65%
negatives=10 pass=0.00%
by topic (worst first):
  hard       n=50 r@1=22.00% r@5=50.00% mrr=31.53%
  report     n=30 r@1=86.67% r@5=100.00% mrr=93.33%
  code       n=30 r@1=93.33% r@5=100.00% mrr=96.67%
  data       n=30 r@1=93.33% r@5=100.00% mrr=96.67%
  db         n=30 r@1=96.67% r@5=100.00% mrr=98.33%
  ...
misses(25):
  - 一天干完活，怎么向上级交代自己做了什么、结果如何
  - 跟老板说数字的时候，怎么讲清这个数是怎么算出来的
  ...
```

结论很直接：**同一份数据、同一个检索器，模板化 96.3% / 难样本 22.0%**。
所以判断「换模型有没有用」，看 `hard` 那一行，而不是全局平均。

两点必须注意：

1. **模板化那 300 条偏容易**：问法与文档标题高度重合，字符检索器能到 96%——它守的是「链路没崩」
   和「哪类主题变差」，**不能用来判断模型优劣**；
2. **`hard` 那 50 条才是判断依据**：同一个检索器在这里只有 22%（recall@1），模型有没有语义能力，
   看这一行。真实 embedding 若在 `hard` 上远高于 22%，说明它确实在做语义匹配，而不是词面命中；
3. **负样本 0% 是预期的**：字符检索器没有阈值，总会返回 5 条。负样本通过率只在检索函数带
   `minScore` 时才有意义——它验的是阈值，不是排序。

### 只跑单主题（含难样本）

按主题筛选后再评测，用于定位「哪个主题不行」：

```cangjie
let only = ArrayList<EvalCase>()
for(item in cases){
    if(item.topic == 'db'){
        only.add(item)
    }
}
println(RetrievalEval.evaluate(only, search, topK: 5).render('bge-m3 / db'))

// 只看语义能力：只要难样本
let semantic = ArrayList<EvalCase>()
for(item in cases){
    if(item.topic == 'hard'){
        semantic.add(item)
    }
}
println(RetrievalEval.evaluate(semantic, search, topK: 5).render('bge-m3 / hard'))
```

### 与基线比较

`render` 是给人看的，机器比较建议直接用指标：

```cangjie
let baseline = 0.8686f64     // 上一次记录的值（naive 基线）
let current = report.recallAt1()
if(current < baseline - 0.05f64){
    println('REGRESSION: ${baseline} -> ${current}')
}
```

| 指标 | 门槛建议 |
|---|---|
| `hard` 的 `recall@1` | **这是最该盯的一行**：低于基线 8 点即视为回归（50 条样本噪声约 ±13 点，所以只抓大幅退化） |
| `recall@1` 全局 | 比基线低 5 点即视为回归（350 条样本下约 ±4 点噪声） |
| 任一模板化主题 `recall@1` | 低 10 点即视为回归（单主题 30 条，阈值放宽） |
| `negatives pass` | 低于 90% 说明阈值太松，噪声被当成结果返回 |
| `misses` | 逐条看，尤其 `hard` 的 miss——那里才是真正的短板 |

## 扩展数据集

1. 往 `retrieval_corpus.tsv` 加行（id 递增，主题写在内容里即可）；
2. **必须**往 `retrieval_queries.tsv` 加对应 query —— `testShippedDatasetIsWellFormed` 会检查
   「每条语料都被至少一条 query 引用」，漏加会直接失败；
3. 新主题要凑够 30 条 query，否则单主题指标不可用（测试只校验现有主题 ≥30）；
4. 加难样本时遵守一条规则：**query 里不出现目标文档标题的任何实词**，否则它就退化成模板化样本。
   `testShippedDatasetIsRetrievable` 会对比两组的字符重合命中率，差距消失就会失败。

## 已知边界

| 项 | 说明 |
|---|---|
| 模板化 query 不代表真实语言 | 每个文档 6 种问法（怎么写/要点/注意什么/标准做法/常见问题/怎么落地）；有真实日志后应替换 |
| 难样本只有 50 条 | 每个文档 1 条，够看量级、不够做细粒度排名；扩到 150+ 才谈得上精度 |
| 每 query 只标 1 个期望 | 多相关文档的场景没有体现，recall@5 无法反映「5 条里混了 4 条错的」 |
| 不做人工评分 | 指标衡量「能不能找到」，不衡量「找到的内容是否有用」 |
| 负样本只有 10 条 | 只够验证阈值量级，不能用来调 `minScore` 的精确值 |
