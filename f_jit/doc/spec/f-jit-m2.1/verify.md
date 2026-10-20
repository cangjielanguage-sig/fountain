# f-jit-m2.1 验收（收口记录）

> 本文件是 `openspec/changes/archive/2026-10-20-f-jit-m2.1/verify.md` 遗留项 2 的收口记录。
> 归档报告保留原样（只追加了「收口」一节并更正一处计数），执行细节与当前证据以本文件为准。

## 结论

M2.1 改动的 3 条 requirement / 14 条 scenario **全部进入矩阵**，无未映射、无缺失；
其中 13 条 full、1 条 partial（理由见 §1.2）。全量测试 **859/859/0**、零 warning；
M1 / M2 既有矩阵未退化。

## 1. 验收证据

| 检查 | 命令 | 结果 |
|---|---|---|
| M2.1 增量矩阵 | `scripts/check_scenarios.sh m2.1` | **14 条映射（full 13 / partial 1 / 缺口 0），未映射 0，缺失 0** |
| T 编号强校验 | `scripts/check_tmap.sh` | 54 条范围内映射（M1+M2），悬空/未断言 0 |
| M1 矩阵 | `scripts/check_scenarios.sh m1` | 156 条，未映射 0 / 缺失 0（7 缺口为历史登记） |
| M2 矩阵 | `scripts/check_scenarios.sh m2` | 156 条，未映射 0 / 缺失 0（5 缺口为历史登记） |
| 全量测试 | `cjpm test --parallel 1` | **859 / 859 / 0**，零 warning |

### 1.1 镜像范围

`doc/spec/f-jit-m2.1/` 是**增量镜像**，只收录本变更实际改动的 3 条 requirement
（2 条 MODIFIED + 1 条 ADDED）：`编译门面与注册表快照`、`反射注册的映射与拒绝`、
`类型化绑定与 @JitBind 宏`。未改动的 capability 与 requirement 仍由 `m2` 矩阵覆盖，
两份矩阵互补、不重复登记。

14 条 scenario = 新增 9 条 + 随 MODIFIED 沿用的 5 条（`重名与超限`、`类名冲突拒绝`、
`快照语义`、`过滤与诊断`、`JSON 谱系拒绝`，复用 M2 的用例映射）。

### 1.2 唯一的 partial

`类型码在编译期确定` → `macroEnrollsAllMemberKinds`（partial）。

该场景含两个断言面：**码值**（宏按源码类型名映射成整数字面量）与**求值方式**
（签名码的求值不调用 `TypeInfo`）。前者可用例断言（`[14]` / `[14,4]` / `[4]` / `[4,0]`
等逐位比对）；后者是生成代码的**结构属性**，运行期无观测点，只能由代码审阅保证。
登记为 partial 而不是 full，避免把「结构属性」说成「已断言」。

## 2. 收口时新增的用例

`JitBind_test.explicitBindingsMergeOverEnrollment`

- 场景：`自动登记与显式覆盖`
- 做法：类已 `@JitBind`，注册时只显式传一条 `greet` 绑定；断言 `u.greet("z")` 返回
  显式实现的值，同时 `tag(u)` 仍可用。
- 为什么用 `tag` 作第二个判据：它是 `mut prop`，getter 签名 `(C) -> String`。若显式传参
  把自动登记整体顶掉，getter 会退回反射并撞上「引用型默认拒绝」，`tag(u)` 直接编译不过 ——
  所以「编译得过 + 返回原值」就证明自动登记仍在生效。

## 3. 收口时修掉的两处过度声明

### 3.1 `bindings` 语义：整体取代 → 合并

原实现 `if (bindings.isEmpty()) 自动登记 else bindings`。后果：为改一个方法而显式传参，
会把该类的字段 / 构造器 / 静态成员绑定全部丢掉；退化的成员回流到反射，其中引用型签名
（`mut prop tag` 这类）还会被本变更自己引入的「默认拒绝」拒掉 —— 想改一处、掉了半类。

现改为 `JitBindSupport.enrolledOf(name).withOverrides(bindings)`：按成员键
（方法名 / 字段名 / 形参码 / 静态成员名）合并，同键以显式项为准。改动落在
`base/JitBindings.withOverrides`（新增）与 `ReflectRegistrar`（取 `effective` 处）。

主规范同步：`### Requirement: 编译门面与注册表快照` 的条文由「显式传参 SHALL 优先于自动登记」
改为合并语义；`#### Scenario: 自动登记与显式覆盖` 的 WHEN/THEN 同步改写。

### 3.2 类型码措辞：`初始化期不调用 TypeInfo` 与实现不符

实现里宏确实不再用 `TypeInfo` 算签名码（`codeToken` 在宏内按源码类型名映射），但包初始化期
仍有 `TypeInfo` 调用：`enrollOf<T>` 取登记键、`bindNameOf<T>` 取 slot 名，都是全限定名。
原措辞把「签名码不查反射」写成了「初始化期不碰反射」，属过度声明。

主规范已改为：「签名码的求值不调用 `TypeInfo`；初始化期仍有 `TypeInfo` 调用，但只用于取
全限定名（登记键与 slot 名），不参与类型码」。

### 3.3 归档报告的一处计数错误

归档 `verify.md` 初版写「delta 的 6 条场景」，实际新增 9 条（另 5 条随 MODIFIED 沿用）。
已在归档报告中就地更正并标注。

## 4. 环境事实（影响可复现性）

- `openspec` CLI 在鸿蒙侧与融合侧都不在 `PATH`，`openspec validate` / `archive` 无法执行；
  归档与本次的规范并入均为手工等价步骤。
- `openspec/` 被 `.gitignore:62` 忽略（`git ls-files openspec` 为空），因此主规范的措辞更正
  **只存在于磁盘**，不进版本控制；`doc/spec/f-jit-m2.1/` 与脚本改动是入库的。

## 5. 复现

```bash
cd f_jit
bash scripts/check_scenarios.sh m2.1
bash scripts/check_tmap.sh
bash scripts/check_scenarios.sh m1
bash scripts/check_scenarios.sh m2
cjpm test --parallel 1
```
