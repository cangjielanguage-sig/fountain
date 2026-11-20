# Design

## Context

`f_jwt` 现状（见 `proposal.md` - Why）：

- `JWT`（`sealed abstract class`）持有 `signAlgo: SignAlgo`（默认 `NoneSignAlgo.INSTANCE`）、
  `headers: HashMap<String, String>`、`payload: HashMap<String, Any>`；
- 算法入口共 **13 个**，且都是「配算法 + 写 alg 头」两步：
  - HMAC 6 个：`hmacMD5` / `hmacSHA1` / `hmacSHA224` / `hmacSHA256` / `hmacSHA384` / `hmacSHA512`
    （各自的私有 `HM5()` / `HS1()` / … 直接 `header("alg", name)`）；
  - ECDSA 4 个：`ecdsa224` / `ecdsa256` / `ecdsa384` / `ecdsa512`（私有 `ES224()` … `ES512()`）；
  - RSA 3 个：`rsa256` / `rsa384` / `rsa512`（私有 `RS256()` / `RS384()` / `RS512()`）。
- `SM2SignAlgo` 类存在，但 `JWT` **没有** `sm2()` 入口，故 SM2 不在本次校验链路上（类本身保持不动）；
- `JWTVerifier.verifySign()` 直接 `signAlgo.verify(...)`，全类无任何 `signAlgo` 赋值；
- `HMACDigest.init(key, algorithm)` 直接 `HMAC(key, algorithm)`。

约束：公开 API 签名不变；不删除任何签名算法；`f_security` / `fdemo` 现有用法（`verifier` 上链式配 key）必须继续可用。

## Goals / Non-Goals

**Goals:**

- 13 个算法入口**统一**走同一套「登记算法名 + 配算法」路径，不存在漏登记的入口。
- 让「编码器写 alg 头」与「验签器配算法」互不干扰：`JWTVerifier.getHeader("alg")` 永远返回 token 自带的算法名。
- 验签前两道判定对**所有算法族**生效：未配置算法 → 明确异常；token 算法与配置算法不一致 → 明确异常（含两侧算法名）。
- HMAC 摘要映射逐条对上算法名；空密钥给出模块自己的 `JWTException`。

**Non-Goals:**

- 不做常量时间签名比较（`DigestSignAlgo.verify` 仍用数组相等）。理由：`stdx.crypto.digest.HMAC.equal`
  只对 HMAC 有效，非对称路径（RSA/ECDSA/SM2）已在 stdx 内部处理；为 HMAC 单独分流会把 `SignAlgo` 的
  抽象弄脏，留作后续变更。
- 不改 JWT 头 `alg` 的取值（`HM5` / `HS1` / `HS224` 这些非标准名保持原样，避免破坏已签发 token 的兼容性）。
- 不新增/删除公开 API；不新增 `sm2()` 入口；不实现「按 token 头自动选算法」（没有密钥无法自动选，见 D1）。
- 不处理 `JWTVerifier` 解析畸形 token 时的 `RangeException`（超出本次缺陷范围）。
- 不改 `SignAlgo.doDigest`。**实测结论**：`std.crypto.digest.digest()` 内部已对摘要对象做 `reset`，
  同一算法实例连续签名本来就成立（先写了用例发现直接通过，按「严格 RED」的要求没有保留该用例，也没有改生产代码）。

## Decisions

### D1. 验签继续用现有链式 API 配算法与密钥（用户拍板）

`JWTVerifier` 继承 `JWT`，因此 `JWT.verifier(token).hmacSHA256(key).verifySign()`、
`JWT.verifier(token).rsa256(publicKeyPem: pub).verifySign()` 天然可用，
与 `f_security/src/JWTSecurityContext.cj:39` 的 `keySetter(verifier, principal).verify()` 完全一致。

**替代**：新增 `verifySign(key)` 重载。否决——会引入「key 传给哪个算法」的歧义（HMAC 要密钥、RSA/ECDSA 要公钥 PEM），
且与生产代码现有写法分叉。

### D2. 算法名与 `headers` map 解耦，只在编码时写进 JSON

```cangjie
sealed abstract class JWT {
    var algoName: String = ""          // 包内可见（与 signAlgo 同级），13 个入口统一登记
    private func useAlgo(name: String, algo: SignAlgo): This {
        signAlgo = algo
        algoName = name
        this
    }
    public func hmacMD5(key: Array<Byte>): This {
        useAlgo("HM5", DigestSignAlgo(HMACDigest(key, HashType.MD5)))
    }
    // 其余 12 个入口同构；原先的 HM5()/HS1()/…/RS512() 私有 helper 全部删掉
}

public class JWTEncoder <: JWT {
    public func sign(): String {
        var json = JsonObject()
        for ((k, v) in headers) { json.add(k, JsonString(v)) }
        if (algoName.size > 0) { json.add("alg", JsonString(algoName)) }  // 最后写，覆盖用户手设的 alg
        ...
    }
}
```

- 13 个入口共用一个 `useAlgo`，`algoName` 是唯一真源；不存在「配了算法却没登记算法名」的入口。
- 编码器：`headers` 里用户手设的 `alg` 会被真实算法名覆盖 —— 签名用的算法必须与声明一致，不允许撒谎。
- 验签器：任何算法入口只改 `algoName` + `signAlgo`，`headers`（从 token 解析）保持原样。

**替代**：给 `JWTVerifier` 单独存一份「配置的 alg」。否决——同一语义存两份（`headers["alg"]` 与 `algoName`）
必然有一处被读错，且 `sign()` 与 `verifySign()` 会各读各的。

### D3. `verifySign()` 先判一致性，再委托 `SignAlgo`（算法族无关）

```cangjie
public func verifySign(): Bool {
    if (algoName.size > 0) {
        let tokenAlg = headers.get("alg") ?? ""
        if (tokenAlg != algoName) {
            throw JWTException("sign algo mismatch: token alg is '${tokenAlg}', configured algo is '${algoName}'")
        }
    }
    // 未配置算法时 algoName 为空，落到 NoneSignAlgo 抛 "sign algo was not be specified"
    signAlgo.verify(bytesForSign(headerBytes, payloadBytes), signBytes)
}
```

- 判定只依赖 `algoName` 与 token 头，与具体算法族无关 ⟹ HMAC / ECDSA / RSA 一次覆盖，无分支。
- 不一致抛异常而不是返回 false：这是「调用方配错了算法」的配置错误，返回 false 会被误读成「token 是伪造的」。
- 校验放在实际验签之前：即使密钥/公钥与签名端不同，也先报算法不一致，不让错误定位漂移。
- `verify()` 内部已调用 `verifySign()`，自动继承该校验。

### D4. 空 HMAC 密钥的判定点只有一处：`HMACDigest.init`

```cangjie
public init(key: Array<Byte>, algorithm: HashType) {
    this(HMACDigest.create(key, algorithm))
}
private static func create(key: Array<Byte>, algorithm: HashType): HMAC {
    if (key.size == 0) { throw JWTException("HMAC key must not be empty") }
    HMAC(key, algorithm)
}
```

13 个入口里只有 6 个 HMAC 入口会构造 `HMACDigest`，因此所有 HMAC 路径天然经过这一处校验；
`JWT` 层不再重复判断。非对称入口不经过 `HMACDigest`，不受影响。

`ByHexKey` / `ByBase64Key` 空串经 `fromHex` / `fromBase64` 得到零长数组（stdx 源码实测：
`fromHexString("")` 与 `fromBase64String("")` 都返回 `Some([])`），因此复用同一判定即可。

**替代**：按 RFC 2104 用单字节 `0x00` 等价密钥支持空密钥。否决（用户拍板）——空密钥签的 token 谁都能伪造，
属配置错误，必须 fail fast。

### D5. `hmacSHA256/384/512` 摘要改回对应 HashType

```cangjie
public func hmacSHA256(key: Array<Byte>): This {
    useAlgo("HS256", DigestSignAlgo(HMACDigest(key, HashType.SHA256)))
}
public func hmacSHA384(key: Array<Byte>): This {
    useAlgo("HS384", DigestSignAlgo(HMACDigest(key, HashType.SHA384)))
}
public func hmacSHA512(key: Array<Byte>): This {
    useAlgo("HS512", DigestSignAlgo(HMACDigest(key, HashType.SHA512)))
}
```

注意：**已用旧实现签发的 HS256/384/512 token 会验签失败**——它们实际是 SHA1 签名。这是纠正缺陷的必然代价，
不提供过渡兼容（用户拍板），在 README 变更说明里写明。

### D6. 非对称算法的测试密钥

`stdx.crypto.keys` 的 RSA 侧只能生成私钥（`RSAPrivateKey(bits)`），**没有**「私钥导出公钥」的公开 API
（`getPublicKeyDer` 是 stdx 包内 `unsafe func`），因此 RSA 测试用一次性固定 PEM 密钥对，放在 `JWT_test.cj`
顶部并注释生成命令与「不得用于生产」：

```bash
openssl genrsa -out rsa_test.pem 2048
openssl rsa -in rsa_test.pem -pubout -out rsa_test_pub.pem
```

ECDSA 侧 stdx 提供 `ECDSAPublicKey(pri: ECDSAPrivateKey)`，所以测试里用 `ECDSAPrivateKey(Curve.P256)` 现生成，
公钥由 `ECDSAPublicKey(pri).encodeToPem().encode()` 得到 —— **仓库里不留 EC 私钥**。

### D7. 测试组织：同一文件内按「契约」分组，严格 RED

沿用单文件 `src/JWT_test.cj`（模块内无子测试目录惯例），新增用例名直接对应 spec 的 requirement：
`testVerifierKeepsTokenAlgHeader`、`testHmacAlgMismatchThrows`、`testAsymmetricAlgorithms`、
`testAlgNameRegisteredForAllEntryPoints`、`testHmacDigestMapping`、`testEmptyHmacKeyRejected`；
原有 11 条 ERROR 用例保持名字与覆盖点，改为显式配密钥。

**严格 RED 的取舍**：新行为与既有行为放在**同一个用例**里断言，保证用例整体先红——
例如 `testHmacAlgMismatchThrows` 同时断言「未配算法抛异常」（今天已成立）与「算法错配抛异常」（今天不成立）；
不单独拆出「今天就已经通过」的用例来凑数。仅凭现状就能通过的用例（如「同一实例连续签名两次」）不保留。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| 旧实现签发的 HS256/384/512 token 变为验签失败（实际是 SHA1） | README 中英同步写明「本版本修正摘要映射，旧 token 需重签」；不提供过渡兼容（用户拍板） |
| `alg` 不一致改为抛异常，调用方若原来「配错算法得到 false」的代码会变成异常 | 该场景原本必然返回 false（密钥不同）或误判；异常消息带两侧算法名，便于定位；`f_security` 只按 principal 选单一算法，不会触发 |
| 空密钥从 `CryptoException` 变 `JWTException` | 消息更明确；`JWTException` 是模块公开异常类型，调用方已有 `catch` 体系（`f_exception`） |
| 测试文件里嵌了固定 RSA 私钥 PEM | 仅用于单元测试的一次性密钥，注释标明「不得用于生产」；不进入任何运行时路径 |
| `algoName` 是包内可见字段，`JWTEncoder` / `JWTVerifier` 共用 | 职责清晰：编码器读取它写头，验签器读取它做一致性判定；不对外暴露（无 `public` 修饰） |
| 非对称用例会做真实 RSA/ECDSA 签名与验签 | 2048 位 RSA 与 P256 单次签名在毫秒级，整个类测试仍在 10s 内 |
