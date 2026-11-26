# Tasks

> 全程 TDD：**严格 RED** —— 每个新增用例都必须在改造前真实失败（跑出失败输出才算），再写最小实现转绿。
> 既有 11 条 ERROR 用例本身已是 RED（缺密钥），归入第 1 组一起修。
> 测试命令统一为 `wsl -d Ubuntu-24.04 -- bash <脚本>`（脚本内 `source cangjie.sh` + `cangjie_env 1.3.0 1.3.0` + `cd f_jwt && cjpm test`）。

## 1. 验签契约（通用）

- [x] 1.1 RED：新增 `testVerifierKeepsTokenAlgHeader`——HS1 token 配 `hmacSHA256` 后 `getHeader("alg")` 仍为
      `Some("HS1")`；验证：改造前实际返回 `Some("HS256")`，用例 FAILED。
- [x] 1.2 RED：新增 `testHmacAlgMismatchThrows`——同一用例三段断言：(a) 未配算法时 `verifySign()` 抛
      `JWTException` 且消息含 `sign algo was not be specified`（既有语义锁定）；(b) HS1 token 配 `hmacSHA256`
      时抛 `JWTException` 且消息含 `HS1` 与 `HS256`；(c) 配正确算法返回 true；
      验证：改造前 (b) 报 `Expected 'JWTException' was not caught`，用例 FAILED。
- [x] 1.3 GREEN：`JWT` 增加包内可见 `algoName` 字段 + 私有 `useAlgo(name, algo)`，13 个算法入口统一登记
      （原 13 个 `HM5()`…`RS512()` 私有 helper 删除）；`JWTEncoder.sign()` 在写完 `headers` 后按 `algoName`
      覆盖写入 `alg`；验证：1.1 / 1.2 转 PASSED。
- [x] 1.4 GREEN：`JWTVerifier.verifySign()` 增加 `algoName` 非空时的 token `alg` 一致性校验（不一致抛
      `JWTException`，消息含两侧算法名，先于实际验签）；验证：1.2 三段全绿。
- [x] 1.5 改造 11 条 ERROR 用例为 `JWT.verifier(token).hmacXXX(key)` 显式配密钥（保持原用例名与覆盖点）；
      验证：这批用例从 ERROR 转 PASSED，`testErrorHandling` 的错密钥分支返回 false 而非抛异常。
- [x] 1.6 文档：`f_jwt/README.md` 与 `README_en.md` 新增「签名与验签约定」章节（13 个入口的 `alg` 表、
      验签必须配算法与密钥、算法不一致抛异常、配置算法不覆盖解析头、空密钥拒绝）；验证：README 的入口表与
      `JWT.cj` 逐一对应，示例与 `testHmacAlgMismatchThrows` 的 (c) 段一致。

## 2. 13 个入口都登记算法名（含非对称）

- [x] 2.1 测试密钥：RSA 用 openssl 生成的一次性 PEM 常量（注释含生成命令与「不得用于生产」）；ECDSA 用
      `ECDSAPrivateKey(Curve.P256)` + `ECDSAPublicKey(pri)` 在用例里现生成；验证：`testAsymmetricAlgorithms`
      的 RSA/ECDSA 正例均验签通过。
- [x] 2.2 RED：新增 `testAsymmetricAlgorithms`——RSA 段：(a) `rsa256` 签 + `rsa256(publicKeyPem:)` 验为 true；
      (b) 配 `rsa384(publicKeyPem:)` 抛 `JWTException` 且消息含 `RS256` 与 `RS384`；(c) 配 `rsa384` 后
      `getHeader("alg")` 仍为 `Some("RS256")`。ECDSA 段同构；验证：在改造前的 `JWT.cj` 上运行，报
      `Expected 'JWTException' was not caught`，用例 FAILED。
- [x] 2.3 RED：新增 `testAlgNameRegisteredForAllEntryPoints`——表驱动遍历 13 个入口各签一个 token，断言
      (a) `getHeader("alg")` 等于该入口预期的算法名；(b) 用同族另一个算法配置 verifier 后 `getHeader("alg")`
      仍为该入口的名字；验证：在改造前的 `JWT.cj` 上运行 FAILED，改造后 PASSED。
- [x] 2.4 GREEN：确认 1.3 的通用改造已覆盖非对称入口（未写额外分支）；验证：2.2 / 2.3 全绿。
- [x] 2.5 文档：README 中英的 `alg` 表覆盖 13 个入口，并注明 `SM2SignAlgo` 没有 `sm2()` 入口；
      验证：README 入口表与 `JWT.cj` 逐一对应。

## 3. HMAC 摘要映射

- [x] 3.1 RED：新增 `testHmacDigestMapping`——从 `hmacSHA256` 签出的 token 拆三段、解码头/载荷，用
      `HMACDigest(key, HashType.SHA256)` 对 `bytesForSign(header, payload)` 重算，断言等于第三段；并断言不等于
      `HashType.SHA1` 的结果；验证：在改造前的 `JWT.cj` 上运行报
      `Different sizes: 20(actual) != 32(...)`，用例 FAILED。
      （说明：摘要修正最初误并入 1.3 的 HMAC 重构；RED 通过在基线 `JWT.cj` 上运行该用例补齐。）
- [x] 3.2 GREEN：`hmacSHA256` / `hmacSHA384` / `hmacSHA512` 的 `HashType` 改为 `SHA256` / `SHA384` / `SHA512`
      （6 个 HMAC 入口统一走 `useAlgo`）；验证：3.1 与 `testAllHmacAlgorithms` 全绿。
- [x] 3.3 文档：README 中英注明 HS256/384/512 自本版本起真正使用 SHA256/384/512（旧实现为 SHA1，旧 token 需重签，
      不提供过渡兼容）；验证：README 与 `JWT.cj` 的 `HashType` 一一对应。

## 4. 空 HMAC 密钥

- [x] 4.1 RED：新增 `testEmptyHmacKeyRejected`（`hmacMD5(Array<Byte>())`、`hmacMD5ByHexKey("")`、
      `hmacSHA256ByBase64Key("")` 三条都抛 `JWTException` 且消息含 `HMAC key must not be empty`）；
      验证：改造前报 `caught exception: CryptoException: Key is empty.`，用例 FAILED。
- [x] 4.2 GREEN：`HMACDigest.init` 统一校验（私有 `HMACDigest.create`），所有 HMAC 入口天然经过；
      验证：4.1 全绿，非对称用例不回归。
- [x] 4.3 改造 `testHmacMD5ByHexKeyEdgeCases`：空密钥改为断言抛 `JWTException` 且消息匹配；保留单字符与
      长密钥两条正例（各自配对应密钥验签）；验证：该用例 PASSED。
- [x] 4.4 文档：README 中英在 HMAC 段与验签约定段写明「密钥不能为空，否则抛 `JWTException`」；
      验证：README 措辞与异常消息一致。

## 5. 集成验证

- [x] 5.1 `cd f_jwt && cjpm test` 全绿：TOTAL 20 / PASSED 20 / ERROR 0 / FAILED 0。
- [x] 5.2 回归 `cd f_security && cjpm test`：编译通过、TOTAL 0（该模块没有测试用例），未因 `f_jwt` 改动报错。
- [x] 5.3 `openspec validate fix-f-jwt-signature-verification --strict` 通过。

## Workflow follow-up

- 归档 `fix-f-jwt-signature-verification` 后用最终版覆盖 `f_jwt/doc/spec/fix-f-jwt-signature-verification/` 四件套。
