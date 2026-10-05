# 跨模块审查条目（`X-*`；§1/§2 拆分自 bug.md，§3 为后续新增）

- **来源**：`.autocode/bugs/bug.md` 按模块拆分（原报告《代码审查报告：f_orm / f_mvc / f_bean / f_aspect》，审查分支 `review/orm-mvc-bean-aspect`，基线 `5a5d6cf3`；拆分日期 2026-10-05）。
- **编号**：条目编号沿用原报告（§x.y 不变），便于与代码注释、其他报告交叉引用；编号不连续属正常（其余编号属其他模块）。总索引见 `bug.md` §0 的「编号索引」。
- **本模块条目 3 条**：严重 1（§1.2 `X-1`，f_base `TypeInfos.get(String)` 无限递归）、中 1（§2.24 `X-2`，f_data 的 `Duration` 配置解析 —— **已修复**：数字分支多余的 `i++` + 非法输入改回 `None`）、低危 1（§3.1 `X-3`，f_jwt 11 条 ERROR —— **作者决定不修**，依赖 stdx 签名库自身健壮性）。
- **状态（截至 2026-10-05，本模块 3 条已全部了结）**：`X-1` ✅已修复（§1.2，已并入 `sts/1.3.x`）；`X-2` ✅已修复**并已并入 `sts/1.3.x`**（§2.24：代码 + 3 条用例，修复前 2 FAILED/1 ERROR ⇒ 修复后 f_data **107/107**、f_orm 端到端 **33/33**；`1753e7cd` 拉齐主线进分支、`85fed54d` 合入主分支）；`X-3` ✅已决（§3.1：不修；①记为「测试待修」，生产路径不受影响）。

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

### 2.24 [中｜正确性] `X-2` `orm_databasePoolMaxWaiting` 的 Duration 配置解析与回退不符约定（跨模块：f_data/f_config）→ ✅ 已修复（2026-10-05）

> 2026-10-04 复跑 f_orm 全量用例时新发现；**追加在 §2 末尾以保持既有编号不变**；定级：中（已复核，见文末状态与修复标记）。

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

**触发原因（2026-10-05 定位，含实测）**：`f_data/src/base/DataParsable.cj:30-65` 的 `Duration.tryParse` 里，**数字分支多了一次 `i++`**：

```cangjie
        while (i < s.size) {
            let r = s[i]
            i++                                  // ← 外层已推进
            duration += match (r) {
                case x where x == b'-' || (x >= b'0' && x <= b'9') =>
                    bytes.add(x)
                    i++                          // ← 又推进一次：吃掉数字后面的那个字符
                    continue
```

⇒ **单位字符被跳过**：`45s` 读到 `4` 后 `i` 直接跳到 `s`，只把 `4` 累加（单位 `s` 被跳掉）⇒ 结果 `4s`；`1m`/`1d2h` 这类「数字紧跟单位」的输入连单位都读不到，`duration` 停在 `Duration.Zero` ⇒ 上游按「≤0 = 真无限等待」映射成 `Duration.Max`。另有 `case _ => throw` 与两处 `getOrThrow`（`:58`、`:62`）让**非法输入直接抛异常**，而 `tryParse` 的语义应返回 `None` ⇒ `Config.getData` 的回退分支永远走不到。

实测（探针，直接调 `Duration.tryParse`，日志 `/tmp/cross_probe.log`）：

| 输入 | 实测 | 期望（用例/文档） |
|---|---|---|
| `45s` | **4s** | 45s |
| `30s` | **3s** | 30s |
| `1m` | **0s**（上游映射成 `Duration.Max`） | 1m |
| `1d2h` | **0s** | 1d2h |
| `0s` | 0s（巧合对上「≤0 ⇒ Max」） | 0s |
| `abc` | **抛 `DataParsableException`** | `None` ⇒ 回退 30s |
| `""` | `Some(0s)` | `None`（修复后即按此实现：空串回退默认值） |

**影响要比用例大**：这是 `f_data` 的通用 `DataParsable` 实现，任何 `xxx=30s` 风格配置都会被静默解析成 `3s`（少一位）⇒ 连接池等待、超时类配置全部按 1/10、甚至按「无限等待」生效。

修法（四处，缺一不可）：①删掉数字分支那次多余的 `i++`；②`case _` 与 `Int64.tryParse` 失败改为返回 `None`；③读到单位后要**清空 `bytes`**（否则多段输入 `1d2h` 会把前段数字带进下一段）；④`case b'm'/b'u'/b'n'` 里的 `s[i]` **没有边界检查** —— 修掉 ① 之后 `1m` 会走到 `if (s[i] == b's')` 而越界（现在正好被 ① 掩盖着，两个缺陷互相遮蔽），必须同时补。

**✅ 修复标记（2026-10-05）**：分支 `fix/x-2-duration-parse`（worktree `.worktrees/x-2-duration-parse`，基线 `584d2e43`），**代码、用例、本标记在同一提交**（提交 `837ca30b`）。

- 改动（`f_data/src/base/DataParsable.cj` 的 `Duration.tryParse`）：①删掉数字分支多余的 `i++`（根因）；②非法输入（未知单位 / 只有数字没给单位 / `Int64` 解析失败 / 空串）改为返回 `None`，不再抛异常；③读到单位结算后 `bytes.clear()` ⇒ 支持 `1d2h` 这类多段输入；④`m/u/n` 分支的 `s[i]` 补 `i < s.size` 边界检查（否则修掉 ① 后 `1m` 会越界）。`parse(s)` 的「抛异常」语义保留不变。
- 用例（新增 `f_data/src/base/DataParsable_test.cj`，3 条）：单单位 10 例（含 `0s`、`-45s`、`ms/us/ns`）、多段 2 例（`1d2h`/`1h30m`）、非法输入 6 例（`abc`/`''`/`45`/`s`/`45x`/`1m2` 全部断言 `None`）。
- 测量：修复前 f_data 全量 = **TOTAL 107 / PASSED 104 / FAILED 2 / ERROR 1**（2 FAILED + 1 ERROR 全是新用例，读数 `left: 45s right: 4s`、`left: 1d2h right: 0s`、`abc` 抛 `DataParsableException`）；修复后 = **107/107 PASSED、FAILED 0、ERROR 0、`cjpm test success`（EXIT=0）**。日志 `/tmp/x2_test.log`。
- 端到端：`f_orm` 全量复跑 = **TOTAL 33 / PASSED 33 / FAILED 0 / ERROR 0（EXIT=0）**，`ORMConfigTest.testPoolMaxWaiting` 由 ERROR 转 PASSED（四个期望 `45s`/`1m`/`0s`/`abc→30s` 全部通过；日志 `/tmp/x2_orm_run2.out`）。
- **已并入 `sts/1.3.x`（2026-10-05）**：`1753e7cd` 拉齐主线进分支、`85fed54d` 合入主分支；合并后主工作区复跑 f_data = **107/107 PASSED、FAILED 0、ERROR 0**（日志 `/tmp/x2_main_test.log`）。合并完成后该 worktree 与分支已按作者指示删除（内容全部在 `sts/1.3.x`）。
- 过程记录（不属本条）：新用例若把包名写成 `fountain::f_data`（而 `src/base/` 下应为 `fountain::f_data.base`），链接期会因泛型实例化符号缺失（`_CGP16fountain::f_dataiiHv`/`ilHv`）失败 —— 属工具链的包内实例化问题，按正确包名写即规避。

**2026-10-05 复现与归属（来源：`f_cache` 审查的「四个使用模块端到端验证」）**：`f_orm` 全量 `cjpm test` = `TOTAL: 33, PASSED: 32, ERROR: 1`（同一条 `testPoolMaxWaiting`，失败读数与上表一致）；把同一份用例在 **`sts/1.3.x`（不含任何 f_cache 审查改动）** 上复跑得到**完全相同**的结果（32/33、同一条）⇒ 确认为本条目（既有缺陷），与 `f_cache` 审查改动无关：`f_config`/`ORMConfig` 的依赖里**没有** `f_cache`，也不使用本次被改动的 `ConcHashMap`/`SyncLinkedHashMap`。日志 `/tmp/orm_branch.log`（分支侧）、`/tmp/orm_main.log`（主线基线）。

## 3. 低危（本模块 1 条，2026-10-05 由 `f_cache` 审查的端到端验证新增）

### 3.1 [低危｜测试红｜已决（不修）] `X-3` `f_jwt` 全量用例 11 条 ERROR（HMAC 类；跨模块：f_jwt / stdx.crypto）

> 2026-10-05 在 `f_cache` 审查的「四个使用模块端到端验证」里发现；**追加为新章节以保持既有编号不变**（同 `X-2` 的先例）；**已复核**：生产路径（f_security / fdemo 的 `keySetter` 用法）不复现 ⇒ 不升为**严重**；作者决定见文末「决定：不修」。

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
- **两种症状都指向「输入没到位」**：① `NoneSignAlgo.verify` ⇒ 校验时拿到的签名算法是**空/None**；② `HMACDigest.init` 拿到的**密钥数组为空** ⇒ `Key is empty.`。**已定位（2026-10-05，见下）**：①不是「解析被破坏」，而是**用例漏了给 verifier 接线算法与密钥**（产品侧写法是对的）；②空密钥在**构造 HMAC 时**就抛，库内无守卫。先前猜的三个候选提交（`unsafe String` 重构 / JSON 解析改动）**已排除**。

**触发原因（2026-10-05 定位，含实测；日志 `/tmp/cross_probe.log`）**：两类，彼此独立。

1. **用例没给 verifier 接线算法与密钥**（9 条用例的写法）。`JWT` 是 `sealed abstract class`（`f_jwt/src/JWT.cj:31`），`var signAlgo: SignAlgo = NoneSignAlgo.INSTANCE`（`:34`）**只在编码器方法里被赋值**（`hmacMD5`/`hmacSHA1`/… `:46-224`）；`JWT.verifier(data)`（`:316`）只解析 token，**不会**从 header 的 `alg` 反解算法 —— 实测 header 里确实有 `alg=Some("HS1")`，但实现不使用它 ⇒ `signAlgo` 落到默认的 `NoneSignAlgo` ⇒ `verifySign()`（`:474`）必抛 `sign algo was not be specified`（`SignAlgo.cj:181`）。
   实测：`JWT.verifier(token).verifySign()` ⇒ **抛异常**；`JWT.verifier(token).hmacSHA1(key).verifySign()` ⇒ **true**。
   ⇒ **属用例与 API 约定不一致，不是产品缺陷**：产品侧的正确用法在 `f_security/src/JWTSecurityContext.cj:36-39`（`let verifier = JWT.verifier(jwt); … keySetter(verifier, principal).verify()`）与 `fdemo/user/src/util/UserSessionCache.cj:29-30`（`{verifier, principal => hmacKey(verifier, principal)}`）—— 都是用回调把算法/密钥配到 verifier 上，这 9 条用例漏了这一步。
   ⇒ 修法二选一：①改用例（补 `.hmacSHA1(key)` 之类的接线，最省事）；②若希望 verifier 支持「按 header 的 `alg` + 调用方提供的密钥」自动解析，则需在 `JWTVerifier` 侧实现解析（属 API 设计变更，需作者确认）。

2. **空/非法密钥在构造阶段就抛异常**（`testHmacMD5ByHexKeyEdgeCases` 等）。`HMACDigest.init(key:algorithm:)`（`f_jwt/src/HMACDigest.cj:23-25`）直接 `HMAC(key, algorithm)`，**没有空密钥守卫** ⇒ `hmacMD5ByHexKey("")`（`fromHex("")` ⇒ 空数组）在**编码阶段**就抛 `CryptoException: Key is empty.`（来自 `stdx.crypto.digest.HMAC`）。用例的意图（注释：「验证空密钥和无效十六进制字符串的处理」）是优雅处理 ⇒ 契约不一致。
   ⇒ 修法：在 `HMACDigest.init`（或 `hmac*ByHexKey`/`ByBase64Key`）加显式守卫 —— 抛库自己的 `JWTException` 明确报「空密钥」，或让 `verifySign()` 捕获该异常返回 `false`（「快速失败」还是「校验不通过」由作者定）。

**定级建议**：第 1 条应改记为「测试待修」而非产品缺陷；第 2 条属产品侧健壮性/契约问题（低危）。生产路径（f_security / fdemo 的 `keySetter` 用法）不受影响。

**决定：不修（2026-10-05，作者）——「依赖 `stdx` 签名库自身的健壮性」。**

- ② 空密钥行为保持现状：`HMACDigest.init` 不加守卫，沿用 `stdx.crypto.digest.HMAC` 抛出的 `CryptoException: Key is empty.`；
- ① 11 条用例保持现状（`JWT.verifier(...)` 不接线算法/密钥就 `verifySign()` ⇒ 仍会抛 `sign algo was not be specified`），记为「测试待修」，不阻塞；
- **若将来要让这 11 条转绿**：只需按触发原因 ① 给用例补接线（`.hmacSHA1(key)` 等），**不需要改产品代码**；
- 本条状态：**已决（不修）**，产品代码无改动。
