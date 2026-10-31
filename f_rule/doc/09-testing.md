# 09 测试策略

## 1. 原则

1. **TDD**：每个公开 API 先写用例再实现；网络类先写"插入后应有多少令牌"的断言。
2. **仓颉单元测试为主**：与 `f_egraph`、`f_excel` 一致，测试文件与被测类同目录，命名 `<类名>_test.cj`。
3. **差分优先**：Rete 的匹配结果必须与"朴素顺序匹配"逐条一致；f_jit 表达式与内置解释器结果必须一致。
4. **性能门禁用可重复的基准**，不用墙钟绝对值，用"相对朴素实现的加速比 + 内存上限"。

## 2. 分层

| 层 | 范围 | 手段 |
|---|---|---|
| L1 单元 | 单个类的方法契约 | 直接构造 + 断言 |
| L2 组件 | 事实库、索引、令牌、议程 | 组合少量类 |
| L3 网络 | 规则 → 网络的匹配结果 | 与朴素匹配差分 |
| L4 端到端 | 决策表 → 规则集 → 引擎 | 完整链路 |
| L5 流程 | ResolveTask / JoinTask / 版本切换 | `f_egraph` 真实 Flow |
| L6 性能 | 规模与内存 | 基准用例 + 门禁 |

## 3. 用例矩阵

### 3.1 事实模型

| 编号 | 场景 | 期望 |
|---|---|---|
| F-01 | 强类型事实字段读取 | 与 `getter` 返回值一致 |
| F-02 | 动态事实字段缺失 | `get` 返回 None，`has` 返回 false |
| F-03 | 动态事实 `assert` 后 `set` | 抛 `ILLEGAL_STATE` |
| F-04 | 同一对象重复 `assert` | 抛 `DUPLICATE_FACT` |
| F-05 | `update` 后句柄不变 | id 不变，字段为新值 |
| F-06 | `retract` 不存在的事实 | 返回 false，不抛错 |
| F-07 | `ValueKey` 跨数值类型相等 | `Int64(1) == Float64(1.0)` |
| F-08 | 跨域比较（字符串 vs 数字） | 抛 `TYPE_MISMATCH` |
| F-09 | 会话隔离 | A 会话事实在 B 会话不可见 |
| F-10 | `fork` + `commitToParent` | 子视图事实合并到父 |

### 3.2 条件

| 编号 | 场景 | 期望 |
|---|---|---|
| C-01 | 每个算子各一组正/反例 | 与手写判定一致 |
| C-02 | `In` 空集合 | 恒 false |
| C-03 | `IsNull` vs 字段缺失 | 都判为 true |
| C-04 | 三值逻辑组合 | 与 SQL 真值表一致 |
| C-05 | 约束重排不改变语义 | 重排前后匹配集合相同 |
| C-06 | `Or` 跨类型 | 构建期展开为多条规则 |
| C-07 | 嵌套深度 33 | 抛 `TABLE_INVALID` |
| C-08 | 字段未注册 | 构建期抛 `UNKNOWN_FIELD` |

### 3.3 Rete 网络

| 编号 | 场景 | 期望 |
|---|---|---|
| R-01 | 单模式规则 | 匹配所有满足约束的事实 |
| R-02 | 两模式等值 join | 与嵌套循环结果一致 |
| R-03 | 两模式范围 join | 与嵌套循环结果一致 |
| R-04 | 三模式链式 join | 令牌数 = 笛卡尔积中满足全部 join 的组合数 |
| R-05 | 相同 alpha 签名跨规则 | `AlphaNode` 只创建一次（断言节点计数） |
| R-06 | 相同 join 签名跨规则 | `BetaNode` 只创建一次 |
| R-07 | 前两模式相同、第三模式不同 | 前两个 join 共享，第三个分叉 |
| R-08 | 插入事实后撤销 | 令牌数归零，激活被移除 |
| R-09 | 撤销其中一个 join 事实 | 仅相关令牌消失，其余保留 |
| R-10 | 重复 `assert` 同一事实 | 幂等，不产生重复令牌 |
| R-11 | `update` 事实 | 等价 retract + assert |
| R-12 | 空 alpha memory 撤销 | 不抛错 |
| R-13 | 无规则关心的事实类型 | 不抛错，直接忽略 |
| R-14 | 令牌 refCount 归零 | 从 BetaMemory 与父链释放 |
| R-15 | 100 条规则共享 20 个 alpha 签名 | 节点数 = 20 + join 数，不随规则数线性增长 |

### 3.4 议程

| 编号 | 场景 | 期望 |
|---|---|---|
| A-01 | salience 排序 | 高优先级先执行 |
| A-02 | specificity 排序 | 条件多的先执行 |
| A-03 | FIFO / LIFO | 与产生顺序一致 |
| A-04 | 组合策略全序 | 任意两激活比较不为 0 |
| A-05 | `Refract` 模式 | 同一激活只执行一次 |
| A-06 | `NoLoop` 模式 | 同一绑定跨轮次不重复 |
| A-07 | `Loop` + `limit` | 执行次数等于 limit |
| A-08 | 动作中 retract 当前激活的事实 | 后续激活失效，被跳过 |
| A-09 | 重入 `fire` | 抛 `REENTRANT_FIRE` |
| A-10 | 动作抛异常 | `fire` 终止，异常带因果链 |
| A-11 | 循环检测 | 超过窗口阈值抛 `CYCLE_LIMIT` |

### 3.5 决策表

| 编号 | 场景 | 期望 |
|---|---|---|
| T-01 | CSV 基本解析 | 行数、列数、值正确 |
| T-02 | CSV 引号转义 | 含逗号/引号/换行的单元格正确 |
| T-03 | CSV 注释与元数据 | 属性解析正确，注释行不进数据 |
| T-04 | CSV 列数不一致 | `TABLE_INVALID` + 行号 |
| T-05 | 每个算子单元格 | 解析为对应 `Constraint` |
| T-06 | `${binding.field}` 输出 | 运行期取值正确 |
| T-07 | `Unique` 零命中 | `TABLE_NO_MATCH` |
| T-08 | `Unique` 多命中 | `TABLE_MULTI_MATCH` |
| T-09 | `First` 多命中 | 取第一行 |
| T-10 | `Collect` 多命中 | 返回全部，按行序 |
| T-11 | `Any` 输出不一致 | `TABLE_MULTI_MATCH` |
| T-12 | XLSX 基本解析 | 与等价 CSV 生成相同规则 |
| T-13 | XLSX 合并单元格 | 取左上角值 |
| T-14 | XLSX 大表流式 | 内存不随行数线性增长 |
| T-15 | 空表 | `TABLE_INVALID` |

### 3.6 流程编排

| 编号 | 场景 | 期望 |
|---|---|---|
| P-01 | 一条规则一个 Flow | category/tag 命名正确，可独立启动 |
| P-02 | 父流程嵌入子流程 | 子流程 End 事件作为父流程下一跳 |
| P-03 | ResolveTask 扇出 2 路 | 两个执行器都收到事件 |
| P-04 | 扇出 3 路 | 全部到达 |
| P-05 | 扇出后分支直达 End | 构建期抛 `FANOUT_WITHOUT_JOIN` |
| P-06 | JoinTask 收齐 | 只发出一次 output |
| P-07 | JoinTask 缺一路 | 不发出 output |
| P-08 | JoinTask 重复到达 | 幂等，不重复推进 |
| P-09 | 并发两个 session 交错扇出 | 各自汇合，不串扰 |
| P-10 | 版本切换 | 新 tag 生效，旧 tag 移除 |
| P-11 | 旧 tag 被依赖时移除 | 抛 `GraphException` |
| P-12 | ResolveTask 空产出 | `EMPTY_FANOUT` |

### 3.7 集成

| 编号 | 场景 | 期望 |
|---|---|---|
| I-01 | 决策表 → Rete → 议程 → 输出 | 端到端结果符合预期 |
| I-02 | 决策流 + 产生式混用 | 同一 session 事实互通 |
| I-03 | f_jit 表达式与内置解释器 | 同一表达式结果逐条一致 |
| I-04 | 脚本规则体 `@JitBind` | 能访问登记的类型 |
| I-05 | 未登记类型 | 构建期报错，不进入运行期 |
| I-06 | 1000 规则 / 10000 事实 | 正确性 + 性能门禁 |

## 4. 差分测试

### 4.1 Rete vs 朴素匹配

```cangjie
/** 朴素实现：嵌套循环 + 逐条 join 判定。只用于测试，慢但语义清晰。 */
class NaiveMatcher {
    func match(rules: Array<Rule>, facts: Array<Fact>): Array<Activation>
}
```

对同一组规则与事实：

```
@Assert(rete.activations().sortedBy(key), naive.match(...).sortedBy(key))
```

关键：随机生成规则与事实（属性基测试），覆盖：

- 1~5 个模式；
- 每个模式 0~4 个约束；
- 等值 / 范围 / In / IsNull 混合；
- 事实数 0~200；
- 规则数 0~50；
- 插入后随机撤销 30% 事实，再比对。

不少于 200 组随机用例，seeded 可复现。

### 4.2 f_jit vs 内置解释器

同一批表达式源码：

```
o.amount > 200 && o.level >= 3
lower(o.name) == "vip"
o.tags contains "urgent"
```

用两种模式各跑一遍，断言结果一致；不一致时输出两边的 AST 与求值轨迹。

## 5. 性能门禁

基准用例固定在 `src/bench/`（不随单元测试默认执行），用 `cjpm bench` 或独立可执行入口。

| 编号 | 场景 | 门禁 |
|---|---|---|
| B-01 | 1000 规则（每个 2 模式）构建网络 | < 500ms，节点数 < 3000 |
| B-02 | 10000 事实插入 | < 2s，激活数与朴素匹配一致 |
| B-03 | 插入单条事实（网络已建） | < 1ms（P95） |
| B-04 | 撤销 30% 事实 | < 500ms |
| B-05 | 1000 规则 / 10000 事实 RSS | < 512MB |
| B-06 | 重复构建同一规则集 | 第二次命中缓存，< 50ms |
| B-07 | 决策表 1000 行解析 + 编译 | < 300ms |

内存采样用 `MonoTime` + 平台 RSS 接口（与 `f_excel` 的 M3 门禁一致）。

## 6. 夹具

`src/fixtures/` 放置：

| 夹具 | 用途 |
|---|---|
| `pricing.csv` | 决策表基本用例 |
| `pricing.xlsx` | 与 CSV 等价的 Excel 版本 |
| `pricing_large.xlsx` | 10 万行流式读取 |
| `rules_1000.json` | 1000 条规则的代码生成输入 |
| `facts_10000.json` | 10000 条事实的批量插入 |

Excel 夹具由脚本生成（不手工维护），脚本放 `doc/tools/gen_fixtures.py`。

## 7. 测试组织

```
src/
├── fact/FactBase_test.cj
├── condition/Constraint_test.cj
├── rete/ReteNetwork_test.cj
├── rete/NetworkSharing_test.cj
├── agenda/Agenda_test.cj
├── table/CsvTableParser_test.cj
├── table/XlsxTableParser_test.cj
├── flow/ResolveTask_test.cj
├── flow/JoinTask_test.cj
├── test/NaiveMatcher.cj          # 仅测试用
├── test/PropertyGen.cj           # 随机规则/事实生成
└── bench/BenchMain.cj            # 性能基准
```

`test/` 包内的类型不导出到公开 API（`internal`）。

## 8. 提交门禁

每次提交前必须：

1. `cjpm build` 通过；
2. `cjpm test` 全绿；
3. 新增公开 API 有对应用例；
4. 涉及网络/议程的改动，差分测试必须跑过；
5. 涉及性能路径的改动，基准不退化超过 10%。
