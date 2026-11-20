# Spec Delta

## Purpose

定义 `f_jwt` 的签名与验签契约：算法名如何映射到摘要算法、每个签名入口都必须登记算法名、验签必须显式配置算法与
密钥、token 声明的算法必须与配置一致（对 HMAC / ECDSA / RSA 全部生效）、HMAC 密钥的合法性约束。该契约与算法族
无关：一致性校验适用于全部算法，空密钥约束只适用于 HMAC。

## ADDED Requirements

### Requirement: HMAC 算法名与摘要一致

每个 HMAC 构造入口 MUST 用与该算法名对应的摘要算法计算签名，MUST NOT 复用其它摘要算法：

| 入口 | header `alg` | 摘要 |
|---|---|---|
| `hmacMD5(key)` | `HM5` | MD5 |
| `hmacSHA1(key)` | `HS1` | SHA1 |
| `hmacSHA224(key)` | `HS224` | SHA224 |
| `hmacSHA256(key)` | `HS256` | SHA256 |
| `hmacSHA384(key)` | `HS384` | SHA384 |
| `hmacSHA512(key)` | `HS512` | SHA512 |

`ByHexKey` / `ByBase64Key` 变体 MUST 与对应字节数组入口得到相同签名。

#### Scenario: HS256 使用 SHA256 摘要

- **WHEN** 用同一密钥分别构造 `HS256` 与 `HS1` 的签名，且对同一个 `header.payload` 字节串计算
- **THEN** `HS256` 的签名等于 `SHA256` HMAC 的结果，且不等于 `SHA1` HMAC 的结果

#### Scenario: 六个 HMAC 变体自洽

- **WHEN** 分别用六个 HMAC 入口签一个 token，再用同一个密钥验签
- **THEN** 六次验签都返回 true，且 token 头的 `alg` 分别是 `HM5` / `HS1` / `HS224` / `HS256` / `HS384` / `HS512`

#### Scenario: 密钥编码变体等价

- **WHEN** 同一密钥分别以字节数组、HEX 字符串、Base64 字符串三种形式构造签名
- **THEN** 三者的验签结果都为 true

### Requirement: 每个签名入口都登记算法名

`JWT` 上每个配置签名算法的公开入口（HMAC 6 个、ECDSA 4 个、RSA 3 个，共 13 个）MUST 在配置签名算法与密钥的
同时登记该算法名；编码出的 token 头 MUST 带与该入口一致的 `alg` 值。MUST NOT 存在「配了算法但没有 `alg` 头」或
「`alg` 头与实际算法不符」的入口。

#### Scenario: HMAC 入口登记算法名

- **WHEN** 依次用 6 个 HMAC 入口签名
- **THEN** 6 个 token 的 `alg` 头分别是 `HM5` / `HS1` / `HS224` / `HS256` / `HS384` / `HS512`

#### Scenario: ECDSA 入口登记算法名

- **WHEN** 依次调用 `ecdsa224` / `ecdsa256` / `ecdsa384` / `ecdsa512` 各签一个 token
- **THEN** 各 token 的 `alg` 头分别是 `ES224` / `ES256` / `ES384` / `ES512`

#### Scenario: RSA 入口登记算法名

- **WHEN** 依次调用 `rsa256` / `rsa384` / `rsa512` 各签一个 token
- **THEN** 各 token 的 `alg` 头分别是 `RS256` / `RS384` / `RS512`

### Requirement: 验签必须显式配置算法与密钥

`JWTVerifier.verifySign()` MUST 使用调用方在该 verifier 上配置的签名算法与密钥（HMAC 用共享密钥；RSA / ECDSA 用
公钥）；未配置时 MUST 抛 `fountain::f_jwt.exception.JWTException`，MUST NOT 返回 true。

#### Scenario: 未配置算法

- **WHEN** 对一个合法 token 直接调用 `JWT.verifier(token).verifySign()`
- **THEN** 抛 `JWTException`，消息包含 `sign algo was not be specified`

#### Scenario: HMAC 配置正确密钥

- **WHEN** 调用 `JWT.verifier(token).hmacSHA1(key).verifySign()` 且 `key` 与签名时一致
- **THEN** 返回 true

#### Scenario: HMAC 配置错误密钥

- **WHEN** 用与签名时不同的密钥配置 verifier 后验签
- **THEN** 返回 false，且不抛异常

#### Scenario: RSA 配置公钥

- **WHEN** token 由 `rsa256(privateKeyPem: pri)` 签发，验签端调用 `JWT.verifier(token).rsa256(publicKeyPem: pub).verifySign()`
- **THEN** 返回 true

#### Scenario: ECDSA 配置公钥

- **WHEN** token 由 `ecdsa256(privateKeyPem: pri)` 签发，验签端调用 `JWT.verifier(token).ecdsa256(publicKeyPem: pub).verifySign()`
- **THEN** 返回 true

### Requirement: token 算法与配置算法必须一致

`verifySign()` MUST 比对 token 头部 `alg` 与已配置算法名，该判定 MUST 对全部算法族生效（HMAC / ECDSA / RSA）；
两者不一致时 MUST 抛 `JWTException`，消息 MUST 同时给出 token 的算法名与配置的算法名。校验 MUST 发生在实际验签
之前，MUST NOT 因密钥不匹配而退化成返回 false。

#### Scenario: HMAC 算法不一致

- **WHEN** token 头 `alg` 为 `HS1`，verifier 配置的是 `hmacSHA256(key)`
- **THEN** 抛 `JWTException`，消息同时包含 `HS1` 与 `HS256`

#### Scenario: RSA 算法不一致

- **WHEN** token 头 `alg` 为 `RS256`，verifier 配置的是 `rsa384(publicKeyPem: pub)`
- **THEN** 抛 `JWTException`，消息同时包含 `RS256` 与 `RS384`

#### Scenario: ECDSA 算法不一致

- **WHEN** token 头 `alg` 为 `ES256`，verifier 配置的是 `ecdsa384(publicKeyPem: pub)`
- **THEN** 抛 `JWTException`，消息同时包含 `ES256` 与 `ES384`

#### Scenario: 算法缺少 alg 头

- **WHEN** token 头没有 `alg` 字段，verifier 已配置算法
- **THEN** 抛 `JWTException`，消息包含配置的算法名

### Requirement: 验签器保留 token 解析出的头

在 `JWTVerifier` 上配置签名算法与密钥 MUST NOT 改写从 token 解析出来的头部字段；
`getHeader("alg")` MUST 始终返回 token 自带的算法名。

#### Scenario: 配置算法后读取 alg

- **WHEN** token 头 `alg` 为 `HS1`，调用 `JWT.verifier(token).hmacSHA256(key)` 后再读 `getHeader("alg")`
- **THEN** 返回 `Some("HS1")`

### Requirement: 拒绝空 HMAC 密钥

所有 HMAC 构造入口（含 `ByHexKey` / `ByBase64Key`）收到长度为 0 的密钥时 MUST 抛 `JWTException`，
消息 MUST 包含 `HMAC key must not be empty`；MUST NOT 让底层 `CryptoException` 漏出。该约束只针对 HMAC，
非对称算法不受影响。

#### Scenario: 空字节数组密钥

- **WHEN** 调用 `hmacMD5(Array<Byte>())`
- **THEN** 抛 `JWTException`，消息包含 `HMAC key must not be empty`

#### Scenario: 空 HEX 密钥

- **WHEN** 调用 `hmacMD5ByHexKey("")`
- **THEN** 抛 `JWTException`，消息包含 `HMAC key must not be empty`

#### Scenario: 空 Base64 密钥

- **WHEN** 调用 `hmacSHA256ByBase64Key("")`
- **THEN** 抛 `JWTException`，消息包含 `HMAC key must not be empty`
