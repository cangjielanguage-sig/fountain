# Proposal

## Why

`f_jwt` 的验签路径从来没把「算法 + 密钥」接到 `JWTVerifier` 上：`signAlgo` 恒为 `NoneSignAlgo`，
`verifySign()` 必然抛 `sign algo was not be specified`，模块 `cjpm test` 14 例里 11 例 ERROR。
同一批用例还暴露出三个实质缺陷：`hmacSHA256/384/512` 错用 SHA1 摘要（与 header 声明的 `HS256/HS384/HS512`
不符，跨语言互操作必错）、空 HMAC 密钥把 stdx 的 `CryptoException` 直接漏给调用方、同一算法实例第二次签名抛
`Digest calculation already completed`。这些是签名/验签契约的缺陷，不是测试写法问题，必须修在模块里。

## What Changes

- **修正 HMAC 摘要映射**（行为变更）：`hmacSHA256` / `hmacSHA384` / `hmacSHA512` 由 `HashType.SHA1` 改为
  `SHA256` / `SHA384` / `SHA512`；header 里的 `alg` 名称（`HS256` / `HS384` / `HS512`）保持不变。
- **算法名与解析头解耦**（行为变更）：`JWT` 内新增非公开字段保存已配置的算法名，13 个算法入口
  （HMAC 6 / ECDSA 4 / RSA 3）统一登记到该字段；`alg` 头只在 `JWTEncoder.sign()` 写进编码出的 JSON；
  `JWTVerifier` 上配置算法不再覆盖 token 解析出的 `alg`。
- **`verifySign()` 前置校验**（行为变更，对 HMAC / ECDSA / RSA 全部生效）：
  - 未配置签名算法 → 抛 `JWTException`（消息沿用现状 `sign algo was not be specified`）；
  - token 头 `alg` 与已配置算法名不一致 → 抛 `JWTException`（防算法混淆攻击），消息同时给出两侧算法名；
  - 校验先于实际验签，不因密钥/公钥不匹配退化成返回 false。
- **空 HMAC 密钥拒绝**（行为变更）：`hmacMD5` / `hmacSHA*` 及其 `ByHexKey` / `ByBase64Key` 变体收到空密钥时
  抛 `JWTException("HMAC key must not be empty")`，不再漏出 stdx `CryptoException`。
- **测试改造**：11 个 ERROR 用例改为显式 `JWT.verifier(token).hmacXXX(key)` 再验签；新增摘要映射、13 个入口
  算法名登记、空密钥、算法不一致（HMAC / RSA / ECDSA 各一组）、解析头不被覆盖、非对称正例六类用例；
  非对称用例用一次性 RSA PEM 测试密钥对（注释记录 openssl 生成命令），ECDSA 密钥在用例里现生成。
- **不删除任何现有签名算法**：HMAC MD5/SHA1/SHA224/SHA256/SHA384/SHA512、ECDSA 224/256/384/512、
  RSA 256/384/512、SM2、`NoneSignAlgo` 全部保留。

## Capabilities

### New Capabilities

- `jwt-signature`: JWT 签名/验签契约——算法名与摘要的映射、验签必须显式配置算法与密钥、token 算法与配置算法
  一致性、HMAC 密钥非空约束、同一算法实例的可重复签名。

### Modified Capabilities

（无：`openspec/specs/` 现有 capability `data-assist-compare` / `data-assist-supertypes` 与 JWT 无关。）

## Impact

- 代码：`f_jwt/src/JWT.cj`、`f_jwt/src/SignAlgo.cj`、`f_jwt/src/HMACDigest.cj`、`f_jwt/src/JWT_test.cj`。
- 公开 API：**签名不变**（无新增/删除公开函数与类型）；变化只在行为——空密钥与算法不一致从「异常类型不明 /
  静默覆盖」变为明确 `JWTException`。
- 调用方：`f_security` 的 `JWTSecurityContext`（先 `keySetter(verifier, principal)` 再 `verify()`）与
  `fdemo` 的 `UserSessionCache` 用法不变，无需改动。
- 文档：`f_jwt/README.md` / `README_en.md` 需补充「验签必须配置算法与密钥」「HMAC 密钥非空」「算法需与 token
  一致」三条约束。
