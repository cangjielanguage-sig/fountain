# 跨模块审查条目（`X-*`；§1/§2 拆分自 bug.md，§3 为后续新增）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 3 条**：严重 1（§1.2 `X-1`，f_base `TypeInfos.get(String)` 无限递归）、中 1（§2.24 `X-2`，f_data/f_config 的 `Duration` 配置解析，定级待复核）、低危 1（§3.1 `X-3`，f_jwt 全量 11 条 HMAC 类 ERROR，2026-10-05 新增，定级待复核）。
- **状态（截至 2026-10-05）**：`X-1` ✅已修复（§1.2，`fix/x-1-typeinfos-get`，已并入 `sts/1.3.x`）；**待修/待复核** `X-2`（§2.24，2026-10-05 复现并确认与 `f_cache` 审查改动无关）、`X-3`（§3.1，新增）。

## 1. 严重（本模块 1 条）

### 1.2 [严重｜正确性] `X-1` `f_base.TypeInfos.get(String)` 无限递归（跨模块）✓已复核 → ✅已修复（2026-10-04）

**✅ 修复标记（2026-10-04）**：分支 `fix/x-1-typeinfos-get`（worktree `.worktrees/x-1-typeinfos-get`，基线 `8be67951`），代码、用例、本标记在**同一提交**（提交信息 `fix(f_base): X-1 TypeInfos.get(String) 改查 std.reflect 注册表，无限递归→InfoNotFoundException`）。

- 改动：`f_base/src/TypeInfos.cj:47` 的 `TypeInfos.get(qualifiedName)` → `TypeInfo.get(qualifiedName)`（按名称查 std.reflect 类型注册表；未注册类型由 `TypeInfo.get` 抛 `InfoNotFoundException`）。`INFOS` 缓存与双检锁保留不变。
- 用例：`f_base/src/TypeInfos_test.cj` → `TypeInfos_test.testGetByQualifiedName`（已注册全限定名返回正确 `TypeInfo`）、`TypeInfos_test.testGetUnregisteredThrows`（未注册名抛 `InfoNotFoundException`，不再递归）。
- 测量证据：**修前基线** `cjpm test --filter TypeInfos_test` 卡在 `testGetByQualifiedName`（0/2 用例，2:33 未返回），worker 进程 `f_base@fountain` 101% CPU、`VmRSS 1374372 kB`（`VmSize 2365304 kB`）、CPU 时间 2:49，无任何异常/栈溢出输出，手工 `kill` 终止 ⇒ 无限递归（持锁、吃内存）**不是**可恢复的失败。**修后** `cjpm test --filter TypeInfos_test` = `PASSED: 2, FAILED: 0, ERROR: 0`；`f_base` 全量 `cjpm test` = `PASSED: 3, FAILED: 0, ERROR: 0`（含既有 `Comparator_test.test`），两次都 `cjpm test success`（EXIT=0）。
- 未覆盖：14 处调用方（f_aspect 三条规则 / f_bean 条件装配 / f_orm 回滚规则）只做了同一 API 的直连验证，未逐个跑其端到端用例（f_aspect/f_bean 测试编译耗时长，留给对应条目修复时一并验证）。

位置：`f_base/src/TypeInfos.cj:37-51`

```cangjie
// TypeInfos.cj:37-48
public static func get(qualifiedName: String): TypeInfo {
    if (let Some(x) <- INFOS.get(qualifiedName)) { x }
    else { synchronized(MUTEX) {
        if (let Some(x) <- INFOS.get(qualifiedName)) { x }
        else { let info = TypeInfos.get(qualifiedName)      // ← 调用的还是这个重载（参数是 String）
               INFOS[qualifiedName] = info; info } } }
}
```

影响：`INFOS` 未命中时自调用同一重载（无参重载是 `get<T>()`，不参与重载决议）⇒ 无限递归 ⇒ `StackOverflow`（且持锁递归）。**调用方共 14 处**：

- `f_aspect/src/AspectRoute.cj:114, 116, 118, 140, 183` ⇒ `ArgsRouteRule`/`ReturnTypeRouteRule`/`TargetRouteRule` 三条规则一用就崩
- `f_bean/src/BeanDefCondition.cj:91, 93, 95, 97, 99, 122, 123, 124` ⇒ `@Bean[cond: Current("...")]` 一类的条件装配不可用
- `f_orm/src/base/SqlExecutor.cj:967`

修法：该分支应改为「按名称构造 `TypeInfo`」的实现（例如从 `qualifiedName` 解析包名/类型名后查 `TypeInfo` 注册表，或抛明确的「未注册类型」异常），绝不能回调自身；修完补一条 `TypeInfos.get("a.b.C")` 的单测（断言不递归、返回值或异常符合约定）。

## 2. 中（本模块 1 条）

### 2.24 [中｜正确性] `X-2` `orm_databasePoolMaxWaiting` 的 Duration 配置解析与回退不符约定（跨模块：f_data/f_config）

> 2026-10-04 复跑 f_orm 全量用例时新发现；**追加在 §2 末尾以保持既有编号不变**，定级待复核。

位置：用例 `f_orm/src/wrap/ORMConfig_test.cj:27-44`（用例本身未改）；失败栈落在 `f_config/src/Config.cj:178/215` → `f_data/src/base/DataParsable.cj:30/58`（`Duration.tryParse`）。

证据（`cjpm test` 全量，f_orm）：

```
[ ERROR  ] CASE: testPoolMaxWaiting
Expect Failed: `(ORMConfig.getPoolMaxWaiting() == Duration.second * 45)`   left: 4s    right: 45s
Expect Failed: `(ORMConfig.getPoolMaxWaiting() == Duration.minute)`       left: 106751991167300d15h30m7s999ms999us999ns    right: 1m
An exception has occurred: fountain::f_data.exception.DataParsableException: abc cannot be parsed to Duration
Summary: TOTAL: 28   PASSED: 27, SKIPPED: 0, ERROR: 1, FAILED: 0
```

影响：`orm_databasePoolMaxWaiting`（连接池最大等待，按用例注释「≤0 表示真无限等待、非法值退回默认 30s」）读出来的值与配置文本不符 —— 输入 `45s` 得到 `4s`、`1m` 得到 `Duration.Max`；非法值 `abc` 直接抛 `DataParsableException` 而不回退 ⇒ 生产里配错一个字符可能让启动直接失败，或把等待时长设成错误值。

与 §1.1 的关系：调用链（`f_config`/`f_data`）与 `ORM-1` 的改动（`SqlArgs`/`SqlExecutor`）无交集；其余 27 例全过（含新增的 3 例）⇒ 属**既有缺陷**。

修法方向：先补 `f_data` 层 `Duration.tryParse` 的用例钉住约定（`45s`/`1m`/`0s`/`abc` 各自的期望），再决定是改解析规则还是改调用方（`Config.getData`）的回退分支。

**2026-10-05 复现与归属（来源：`f_cache` 审查的「四个使用模块端到端验证」）**：`f_orm` 全量 `cjpm test` = `TOTAL: 33, PASSED: 32, ERROR: 1`（同一条 `testPoolMaxWaiting`，失败读数与上表一致）；把同一份用例在 **`sts/1.3.x`（不含任何 f_cache 审查改动）** 上复跑得到**完全相同**的结果（32/33、同一条）⇒ 确认为本条目（既有缺陷），与 `f_cache` 审查改动无关：`f_config`/`ORMConfig` 的依赖里**没有** `f_cache`，也不使用本次被改动的 `ConcHashMap`/`SyncLinkedHashMap`。日志 `/tmp/orm_branch.log`（分支侧）、`/tmp/orm_main.log`（主线基线）。

## 3. 低危（本模块 1 条，2026-10-05 由 `f_cache` 审查的端到端验证新增）

### 3.1 [低危｜测试红｜定级待复核] `X-3` `f_jwt` 全量用例 11 条 ERROR（HMAC 类；跨模块：f_jwt / stdx.crypto）

> 2026-10-05 在 `f_cache` 审查的「四个使用模块端到端验证」里发现；**追加为新章节以保持既有编号不变**（同 `X-2` 的先例）；定级待复核 —— 若同一现象能在生产路径复现（签名算法/密钥解析为空），应升为**严重**（JWT 签名与校验失效）。

位置：`f_jwt/src/JWT_test.cj`（11 条用例）；异常栈落在 `f_jwt/src/SignAlgo.cj:181`（`NoneSignAlgo.verify`）与 `f_jwt/src/HMACDigest.cj:24`（← `stdx.crypto.digest.HMAC.init`）← `f_jwt/src/JWT.cj:46/475`。

证据（`cjpm test` 全量，f_jwt；日志 `/tmp/jwt_branch.log`）：

```
Summary: TOTAL: 14
    PASSED: 3, SKIPPED: 0, ERROR: 11
    FAILED: 0

[ ERROR  ] CASE: testBasicHmacSHA1
    REASON: An exception has occurred:fountain::f_jwt.exception.JWTException:sign algo was not be specified
    at fountain::f_jwt.NoneSignAlgo.verify(...)(f_jwt/src/SignAlgo.cj:181)
    at fountain::f_jwt.JWTVerifier.verifySign()(f_jwt/src/JWT.cj:475)
    at fountain::f_jwt/test.JWTTest.testBasicHmacSHA1()(f_jwt/src/JWT_test.cj:37)

[ ERROR  ] CASE: testHmacMD5ByHexKeyEdgeCases
    REASON: An exception has occurred:CryptoException: Key is empty.
    at stdx.crypto.digest.HMAC.init(...)
    at fountain::f_jwt.HMACDigest.init(...)(f_jwt/src/HMACDigest.cj:24)
    at fountain::f_jwt.JWT.hmacMD5(...)(f_jwt/src/JWT.cj:46)
```

- **11 条 ERROR**：`testBasicHmacSHA1`、`testHmacMD5ByHexKey`、`testHmacMD5ByHexKeyEdgeCases`、`testHmacMD5ByBase64Key`、`testAllHmacAlgorithms`、`testVerificationFunctionality`、`testErrorHandling`、`testChainedCalls`、`testKeyFormatCompatibility`、`testBoundaryValues`、`testLargePayload`；仅 3 条 PASSED：`testHeaderFunctionality`、`testPayloadFunctionality`、`testTimeFunctionality`。
- **归属**：同一份用例在 **`sts/1.3.x`** 上复跑得到**完全相同**的 3 PASSED / 11 ERROR ⇒ **既有缺陷**，与 `f_cache` 审查改动无关（f_jwt 与 f_cache 的接触面只有 `JwtIdCache` 的 `set(life:)`/`set(dieAt:)`；失败栈全在 `SignAlgo`/`HMACDigest`）。日志 `/tmp/jwt_main.log`。
- **两种症状都指向「输入没到位」**：① `NoneSignAlgo.verify` ⇒ 校验时拿到的签名算法是**空/None**；② `HMACDigest.init` 拿到的**密钥数组为空** ⇒ `Key is empty.`。可能方向（待复核，未验证）：签名算法/密钥的解析或注册路径在近期改动里被破坏（候选：`1446f48f`/`b56510dd` 的 `unsafe String` 重构、`127f0a98` 的 JSON 解析改动）；也可能是这批用例的期望与当前 API 契约不符（`...EdgeCases` 从名字看是在测边界）。

修法方向：先按用例名单跑定位（`cjpm test` 过滤/单条执行），读 `f_jwt/src/JWT_test.cj` 与 `SignAlgo.cj`/`HMACDigest.cj` 确认「算法/密钥」如何传入；再用 `git log -p` 二分上面三个候选提交。**在归属明确前不要改 `sts/1.3.x` 的 f_jwt 代码**（可能有并行会话在动）。
