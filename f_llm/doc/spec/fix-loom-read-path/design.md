# Design

## Context

- `LoomStoreGateway.cj:167-187`：`search` 用 `kindOf(args, defaultKind)` 得到单个 kind（experience 分支即 `'experience'`），失败经验读不到。
- `LoomStoreGateway.cj:371+`：`intOf` 缺字段返回 0；`list`/`docIds` 直接把 0 传给底层 → 空结果。
- `LoomCompiler.cj:56-79`：jit 分支直接拼 `step.input` 进源码，不做 `LoomHostApi.render`。

## Decisions

### D1. experience 的 kind 集合在网关内展开，不下沉到 Store

```cangjie
let kinds = ArrayList<String>()
let explicit = strOf(args, 'kind')
if(!explicit.isEmpty()){
    kinds.add(explicit)
}else if(defaultKind == 'experience'){
    kinds.add('experience')
    kinds.add('experience_failed')
}else if(!defaultKind.isEmpty()){
    kinds.add(defaultKind)
}
```

**替代**：让 `MemoryStore.search` 支持前缀匹配 `experience*`。否决——把业务语义塞进存储层，且 pgvector 的 kind 过滤是数组等值。

### D2. 分页缺省用常量 50，`<=0` 视为未给

`list`/`docIds` 取 `let limit = intOf(args,'limit'); let take = if(limit > 0){ limit } else { DEFAULT_PAGE }`。

**替代**：改 `intOf` 让它返回 50。否决——`offset`/`topK` 的语义不同（topK 已有自己的缺省 5），全局改会串味。

### D3. jit 的占位符在编译期拒绝，而不是运行时静默

`LoomCompiler` 在拼 jit 源码前扫一遍：正则近似 `\{[a-zA-Z_][\w.\-]*\}` 命中即抛
`LoomException('jit step does not support {…} templates: use an llm/tool step, or loomStore/loomCallTool inside the snippet')`。

**替代**：在运行时把 `{start.output}` 替换成值再执行。否决——jib 源码是编译期固定的字符串，运行时无法重新编译；真要支持得引入 eval，收益与风险不成比例。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 既有流程用 jit + 占位符会从「能编译」变「编译失败」 | 原本就是错用（占位符不会生效）；错误信息给出替代写法 |
| experience 检索结果变多 | 显式 kind 仍可收窄；`experience_failed` 权重与 experience 相同 |

## Migration Plan

无需迁移。存量的 jit 流程若报错，按提示改成 `llm`/`tool` 步骤即可。
