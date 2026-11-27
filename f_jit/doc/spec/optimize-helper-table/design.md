# 设计：helper 表建一次、压引用

## 1. 现状

```
callLocked:
  helpers = (isWrapper ? owner.helperEntries : this.helperEntries)
  if (helpers.size > 0) UserHelperTable.push(0u16, helpers)
  ...
  finally: UserHelperTable.pop()
```

`push` 内 `HashMap` 新建 + F 次 `add`；`pop` 弹栈。F 与注册函数数同阶。

## 2. 方案

### 2.1 表在绑定期构建

`JitFunction.bindUserHelpers(entries)` 除保存 `helperEntries` 外，构建并缓存
`HashMap<Int64, UserHelperEntry>`。该函数在单元装载时调用一次，**发布前完成**，
因此不存在并发构建。

### 2.2 调用期只压引用

```cangjie
if (helperTable.size > 0) {
    UserHelperTable.pushTable(helperTable)   // 1 次 ArrayList.add
}
```

`pushTable` 不做任何构建、不复制 map。多线程并发**只读**同一张 `HashMap` 是安全的；
压栈的仍是各线程自己的栈（`ThreadLocal` 保留）。

### 2.3 包装闭包实例

`wrapClosure` 产生的实例 `owner = Some(parent)`，自身 `helperEntries` 为空。
`callLocked` 里：

```cangjie
let helperTable = if (isWrapper) {
    match (this.owner) {
        case Some(o) => o.helperTableRef()
        case None => this.helperTableRef()
    }
} else {
    this.helperTableRef()
}
```

`helperTableRef()` 返回缓存；若从未绑定（测试直造实例）则按 `helperEntries` 现场建一次并缓存。

### 2.4 为什么不动栈的 TLS

`UserHelperTable.find(hid)` 被 `runtime/UserHelper.cj` 与 `runtime/AnyHelpers.cj` 从
**C 调用路径**调用，签名里没有 `rs`；把栈迁进 `RuntimeState` 需要改这两处 helper 的契约，
收益仅为每次 find 省一次 TLS get（~300 ns），风险不成比例。本轮只解决 O(F) 的构建。

## 3. 护栏

`src/HelperTableScope_test.cj`（根包）：

| 用例 | 断言 |
| --- | --- |
| `nestedTablesShadowAndRestore` | 压 A、压 B（同 hid）→ find 得 B；pop → 得 A；pop → None |
| `callLeavesNoResidue` | 单元调用 100 次后，栈为空（find 为 None） |
| `buildTableKeepsHidOrder` | `buildTable(0, entries)` 的 hid 依次为 `USER_BASE + i` |
| `pushTableDoesNotCopy` | 同一张表压两次、弹一次后仍可 find（引用语义） |

变异：把 `pushTable` 改回「每次 `buildTable`」→ 功能仍绿（说明语义不变），
故性能由 A/B 数据判定，不由用例判定。

## 4. 判定

MOV = `max(3%, 2×离散度)`；预期 **两个数量级**，方向一致即 keep。
