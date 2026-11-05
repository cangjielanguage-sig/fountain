# 检索质量评测

单测能验证「排序逻辑对不对」，验证不了「语义质量好不好」——后者依赖 embedding 模型版本与网络，
同一批 query 换个模型排名就会变。所以拆成两层：

| 层 | 位置 | 是否进 CI | 测什么 |
|---|---|---|---|
| 骨架 | `src/loom/RetrievalEval_test.cj` | 是（确定性） | 指标算得对、数据集没退化、数据可被检索到 |
| 离线评测 | 本文档描述的跑法 | 否（nightly / 手动） | 真实模型下的 recall@1、recall@5、MRR |

## 数据格式

`eval/retrieval_corpus.tsv`（`id \t 标题 \t 正文`）：

```
d01	日报助手	日报用三段式：先给结论，再给关键数据，最后给建议。
```

`eval/retrieval_queries.tsv`（`query \t 期望 id[,期望 id]`）：

```
怎么写日报	d01
报销多久到账	d08,d07
```

约定：

- `#` 开头是注释，空行忽略；
- 期望 id 可以写多个，**命中任一即算对**；
- 加了新文档就要加对应 query，`testShippedDatasetIsWellFormed` 会检查「期望 id 必须存在于语料」。

当前随附 20 条中文样本，覆盖日报、评审、故障、索引、缓存、限流、权限等主题。

## 跑真实模型

`RetrievalEval.evaluate` 只接收一个检索函数，接什么都可以。以技能检索为例：

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

知识库或记忆库同理，把 `search` 换成对应的 `knowledge.search` / `memory.search`，返回命中的 id。

## 怎么看结果

```
== bge-m3 / skills ==
cases=20 topK=5
recall@1=85.0% recall@5=100.0% mrr=91.66%
misses(0):
```

| 指标 | 含义 | 用途 |
|---|---|---|
| `recall@1` | 第一名就命中的比例 | 最直观：用户看到的第一个结果对不对 |
| `recall@5` | 前五名里有命中的比例 | 上下文能塞 5 条时，够不够用 |
| `MRR` | 命中排名的倒数和 | 对「排第 2 还是第 5」敏感，适合比较两个模型 |

实践建议：

1. 先跑一次基线，把三个数字记下来；
2. 换模型 / 改切词 / 调 `minScore` 后重跑，**任一指掉超过 5 个百分点就视为回归**；
3. `misses` 列表比总指标更有用——它直接告诉你哪类 query 检索不到。

## 已知边界

| 项 | 说明 |
|---|---|
| 语料只有 20 条 | 足够发现大幅回归，不足以评估细分主题；扩到 100+ 条再谈精度 |
| 每 query 只标 1 个期望 | 真实场景常有多个相关文档，标注成本高，先用单点验证趋势 |
| 不做人工评分 | 指标衡量「能不能找到」，不衡量「找到的内容是否有用」 |
