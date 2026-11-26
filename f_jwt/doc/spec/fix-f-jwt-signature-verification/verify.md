# Verification Report: fix-f-jwt-signature-verification

## 汇总

| 维度 | 结果 |
|---|---|
| Completeness | 21/21 任务完成；spec 5 条 ADDED requirement 全覆盖 |
| Correctness | 5/5 requirement 有实现与用例；26 个 scenario 中 25 个有用例 |
| Coherence | 设计 D1~D7 全部遵循；1 处偏差已回写 design（D5 撤销） |

## 证据

### 测试

```text
# f_jwt
Summary: TOTAL: 20
    PASSED: 20, SKIPPED: 0, ERROR: 0
    FAILED: 0

# f_security（依赖 f_jwt，编译回归）
Summary: TOTAL: 0
    PASSED: 0, SKIPPED: 0, ERROR: 0
```

### RED 证据（严格 TDD）

| 用例 | 改造前表现 |
|---|---|
| `testVerifierKeepsTokenAlgHeader` | `getHeader("alg")` 返回 `"HS256"`（应为 `"HS1"`） |
| `testHmacAlgMismatchThrows` | `Expected 'JWTException' was not caught`（错配时返回 true） |
| `testAsymmetricAlgorithms` | `Expected 'JWTException' was not caught`（RS256 token 配 RS384 不报错） |
| `testAlgNameRegisteredForAllEntryPoints` | FAILED（配置算法覆盖了 token 的 `alg` 头） |
| `testHmacDigestMapping` | `Different sizes: 20(actual) != 32(...)`（实际 SHA1） |
| `testEmptyHmacKeyRejected` | `caught exception: CryptoException: Key is empty.` |

后两条中的 `testHmacDigestMapping` 与 `testAsymmetricAlgorithms` / `testAlgNameRegisteredForAllEntryPoints`
是在已完成改动的工作区上补的，RED 通过把 `f_jwt/src/JWT.cj` 临时回退到基线 commit 后运行取得。

## Requirement 映射

| Requirement | 实现 | 用例 |
|---|---|---|
| HMAC 算法名与摘要一致 | `JWT.cj` `hmacSHA256/384/512` → `HashType.SHA256/384/512` | `testHmacDigestMapping`、`testAllHmacAlgorithms`、`testKeyFormatCompatibility` |
| 每个签名入口都登记算法名 | `JWT.cj` `useAlgo()` + 13 个入口 | `testAlgNameRegisteredForAllEntryPoints`（HMAC 6 / ECDSA 4 / RSA 3） |
| 验签必须显式配置算法与密钥 | `JWTVerifier.verifySign()` + `NoneSignAlgo` | `testHmacAlgMismatchThrows`(a)(c)、`testErrorHandling`、`testAsymmetricAlgorithms` |
| token 算法与配置算法必须一致 | `JWTVerifier.verifySign()` 前置比对 | `testHmacAlgMismatchThrows`(b)、`testAsymmetricAlgorithms`（RSA/ECDSA 错配） |
| 验签器保留 token 解析出的头 | `algoName` 与 `headers` 解耦 | `testVerifierKeepsTokenAlgHeader`、`testAlgNameRegisteredForAllEntryPoints`(b) |
| 拒绝空 HMAC 密钥 | `HMACDigest.create()` | `testEmptyHmacKeyRejected`、`testHmacMD5ByHexKeyEdgeCases` |

## 问题

### CRITICAL

无。

### WARNING

- **Scenario 未直接用例覆盖**：`token 算法与配置算法必须一致` 的「算法缺少 alg 头」场景。
  代码路径已实现（`tokenAlg == ""` 时必然与配置算法名不等 → 抛 `JWTException`），但按「严格 RED」
  的要求没有新增一个「写出来就通过」的用例。建议后续有相关改动时用构造的无 `alg` token 补一条用例。

### SUGGESTION

- `DigestSignAlgo.verify` 仍用数组相等比较签名，非恒定时间；可评估改用 `HMAC.equal`（本次 Out of Scope）。

## 结论

无 CRITICAL 问题，1 条 WARNING（1 个 scenario 无直接用例），1 条 SUGGESTION。可以归档。
