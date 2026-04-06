## STDX依赖
配置环境变量：`export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

# JWT
本模块实现了完整的JWT特性
---

## 签名包装器 `SignAlgo`
```cj
abstract sealed class SignAlgo {
    /**
     * 参数是用来签名的算法实例
     */
    protected SignAlgo(protected let digest: Digest) {}
    /**
     * 签名
     * @param data 待签名数据
     * @return 签名
     */
    protected func sign(data: Array<Byte>): Array<Byte>
    /**
     * 验签
     * @param data 待验签的数据
     * @param sign 待验证的签名
     */
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool
}
```

### HMAC签名包装器
```cj
public class DigestSignAlgo <: SignAlgo
```

### 不对称签名包装器
```cj
abstract sealed class AsymmetricSignAlgo <: SignAlgo {
    public AsymmetricSignAlgo(digest: Digest, protected let privateKey!: ?PrivateKey = None<PrivateKey>,
        protected let publicKey!: ?PublicKey = None<PublicKey>) 
    protected static func toPrivateKey<T>(privateKey: ?T): ?PrivateKey where T <: PrivateKey 
    protected static func toPublicKey<T>(publicKey: ?T): ?PublicKey where T <: PublicKey 
}
```

#### RSA签名包装器`RSASignAlgo`
```cj

public class RSASignAlgo <: AsymmetricSignAlgo {
    public RSASignAlgo(digest: Digest, privateKey!: ?RSAPrivateKey = None<RSAPrivateKey>,
        publicKey!: ?RSAPublicKey = None<RSAPublicKey>, private let padType!: PadOption = PKCS1) 
    protected func sign(data: Array<Byte>): Array<Byte> 
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool 
}
```

#### ECDSA签名包装器`ECDSASignAlgo`
```cj
public class ECDSASignAlgo <: AsymmetricSignAlgo {
    public init(digest: Digest, privateKey!: ?ECDSAPrivateKey = None<ECDSAPrivateKey>,
        publicKey!: ?ECDSAPublicKey = None<ECDSAPublicKey>) 

    protected func sign(data: Array<Byte>): Array<Byte> 
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool 
}
```

#### SM2包装器`SM2SignAlgo`
```cj
public class SM2SignAlgo <: AsymmetricSignAlgo {
    public init(digest: Digest, privateKey!: ?SM2PrivateKey = None<SM2PrivateKey>,
        publicKey!: ?SM2PublicKey = None<SM2PublicKey>) 

    protected func sign(data: Array<Byte>): Array<Byte> 
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool 
}
```

### HMAC签名`HMACDigest`
```cj
public class HMACDigest <: Digest {
    /**
     * @param hmac stdx.crypto.digest.HMAC
     */
    public HMACDigest(private let hmac: HMAC) {}
    /**
     * @param key 签名密钥
     * @param algorithm HMAC算法类型 stdx.crypto.digest.HashType
     */
    public init(key: Array<Byte>, algorithm: HashType) {
        this(HMAC(key, algorithm))
    }
    public prop size: Int64 {
        get() {
            hmac.size
        }
    }
    public prop blockSize: Int64 {
        get() {
            hmac.blockSize
        }
    }
    /**
     * 将参数写到签名算法
     */
    public func write(buffer: Array<Byte>): Unit 
    /**
     * 签名，返回的是签名的结果
     */
    public func finish(): Array<Byte> 
    /**
     * 执行签名，签名数据会复制到参数to
     */
    public func finish(to!: Array<Byte>): Unit 
    /**
     * 重置算法数据
     */
    public func reset(): Unit 
    /**
     * 签名算法的名称
     */
    public prop algorithm: String 
}

```

## `JWT`
```cj
sealed abstract class JWT {
    protected init() {}
    /**
     * 添加JWT header
     */
    public func header(name: String, value: String): This 
    /**
     * 指定HMAC-MD5为签名算法
     * @param key 签名密钥
     */
    public func hmacMD5(key: Array<Byte>): This 
    /**
     * 指定HMAC-MD5为签名算法
     * @param key BASE64表示的签名密钥
     */
    public func hmacMD5ByBase64Key(key: String): This 
    /**
     * 指定HMAC-MD5为签名算法
     * @param key HEX表示的签名密钥
     */
    public func hmacMD5ByHexKey(key: String): This
    /**
     * 指定HMAC-SHA1为签名算法
     * @param key 签名密钥
     */ 
    public func hmacSHA1(key: Array<Byte>): This 
    /**
     * 指定HMAC-SHA1为签名算法
     * @param key BASE64签名密钥
     */ 
    public func hmacSHA1ByBase64Key(key: String): This 
    /**
     * 指定HMAC-SHA1为签名算法
     * @param key HEX签名密钥
     */
    public func hmacSHA1ByHexKey(key: String): This 
    /**
     * 指定HMAC-SHA224为签名算法
     * @param key 签名密钥
     */
    public func hmacSHA224(key: Array<Byte>): This 
    /**
     * 指定HMAC-SHA224为签名算法
     * @param key BASE64表示的签名密钥
     */
    public func hmacSHA224ByBase64Key(key: String): This 
    /**
     * 指定HMAC-SHA224为签名算法
     * @param key HEX表示的签名密钥
     */
    public func hmacSHA224ByHexKey(key: String): This 
    /**
     * 指定HMAC-SHA256为签名算法
     * @param key 签名密钥
     */
    public func hmacSHA256(key: Array<Byte>): This 
    /**
     * 指定HMAC-SHA256为签名算法
     * @param key BASE64表示的签名密钥
     */
    public func hmacSHA256ByBase64Key(key: String): This 
    /**
     * 指定HMAC-SHA256为签名算法
     * @param key HEX表示的签名密钥
     */
    public func hmacSHA256ByHexKey(key: String): This 
    /**
     * 指定HMAC-SHA384为签名算法
     * @param key 签名密钥
     */
    public func hmacSHA384(key: Array<Byte>): This 
    /**
     * 指定HMAC-SHA384为签名算法
     * @param key BASE64表示的签名密钥
     */
    public func hmacSHA384ByBase64Key(key: String): This 
    /**
     * 指定HMAC-SHA384为签名算法
     * @param key HEX表示的签名密钥
     */
    public func hmacSHA384ByHexKey(key: String): This 
    /**
     * 指定HMAC-SHA512为签名算法
     * @param key 签名密钥
     */
    public func hmacSHA512(key: Array<Byte>): This 
    /**
     * 指定HMAC-SHA512为签名算法
     * @param key BASE64表示的签名密钥
     */
    public func hmacSHA512ByBase64Key(key: String): This 
    /**
     * 指定HMAC-SHA512为签名算法
     * @param key HEX表示的签名密钥
     */
    public func hmacSHA512ByHexKey(key: String): This 
    /**
     * 指定ECDSA224为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     */
    public func ecdsa224(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * 指定ECDSA256为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     */
    public func ecdsa256(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * 指定ECDSA384为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     */
    public func ecdsa384(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * 指定ECDSA512为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     */
    public func ecdsa512(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * 指定RSA256为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     * @param padType 填充类型
     */
    public func rsa256(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>,
        padType!: PadOption = PKCS1): This 
    /**
     * 指定RSA384为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     * @param padType 填充类型
     */
    public func rsa384(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>,
        padType!: PadOption = PKCS1): This 
    /**
     * 指定RSA512为签名算法
     * @param privateKey 私钥
     * @param publicKey 私钥
     * @param padType 填充类型
     */
    public func rsa512(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>,
        padType!: PadOption = PKCS1): This 
    /**
     * 指定keyId 头
     */
    public func keyId(keyId: String): This 
    /**
     * 指定iss 负载
     */
    public func issuer(iss: String): This 
    /**
     * 指定sub 负载
     */
    public func subject(sub: String): This
    /**
     * 指定aud 负载
     */
    public func audience(aud: String): This 
    /**
     * 指定exp 负载
     * @param expire 过期时间的秒数
     */
    public func expire(expire: Int64): This 
    /**
     * 指定exp 负载
     * @param expire 过期时间的Duration
     */
    public func expire(duration: Duration): This 
    /**
     * 指定exp 负载
     * @param expireAt 过期时间
     */
    public func expireAt(expireAt: DateTime): This 
    /**
     * 指定exp 负载
     * @param expireAt 过期时间，从DateTime.UnixEpoch开始的Duration
     */
    public func expireAt(duration: Duration): This 
    /**
     * 指定exp 负载
     * @param expireAt 过期时间，从DateTime.UnixEpoch开始的秒数
     */
    public func expireAt(expireAt: Int64): This 
    /**
     * 指定nbf 负载
     * @param nbf 此时间之后生效，从DateTime.UnixEpoch开始的秒数
     */
    public func notBeforeAt(nbf: Int64): This 
    /**
     * 指定nbf 负载
     * @param nbf 此时间之后生效，从DateTime.UnixEpoch开始的Duration
     */
    public func notBeforeAt(nbf: Duration): This 
    /**
     * 指定nbf 负载
     * @param nbf 此时间之后生效
     */
    public func notBeforeAt(nbf: DateTime): This 
    /**
     * 指定iat 负载
     * @param iat 从DateTime.UnixEpoch开始的秒数
     */
    public func issuedAt(iat: Int64): This 
    /**
     * 指定iat 负载
     * @param iat 从DateTime.UnixEpoch开始的Dration
     */
    public func issuedAt(iat: Duration): This 
    /**
     * 指定iat 负载
     * @param iat 
     */
    public func issuedAt(iat: DateTime): This 
    /**
     * 指定jti 负载
     * @param jti 
     * @param expire jti缓存存续时长
     * @param cache jti缓存 
     */
    public func jwtId<T>(jti: T, expire: Duration, cache: JwtIdCache<T>): This where T <: Equatable<T> & ToString 
    /**
     * 指定jti 负载
     * @param jti 
     * @param expire jti缓存过期时间
     * @param cache jti缓存 
     */
    public func jwtId<T>(jti: T, expireAt: DateTime, cache: JwtIdCache<T>): This where T <: Equatable<T> & ToString 
    /**
     * 添加负载
     * @param name 负载名
     * @param value 负载值 
     */
    public func addPayload<T>(name: String, value: T): This where T <: ToString 
    /**
     * 添加负载
     * @param map 把map的KEY作为负载的名，map的值作为负载的值
     */
    public func addPayload<V, M>(map: M): This where V <: ToString, M <: Map<String, V> 
    /**
     * 添加负载
     * @param data 把对象的公共成员属性或公共成员变量作为负载，成员名是负载负，成员的值是负载的值
     */
    public func addPayload<T>(data: T): This where T <: Object & ObjectData<T> 
    /**
     * JWT签名对象
     */
    public static func encoder(): JWTEncoder 
    /**
     * JWT解码
     */
    public static func verifier(data: String): JWTVerifier 
}
```

### `JWTEncoder`
```cj
public class JWTEncoder <: JWT {
    JWTEncoder() {}
    /**
     * 签名
     */
    public func sign(): String 
}
```

### JWT解码器 `JWTDecoder`
```cj
public class JWTVerifier <: JWT {
    /**
     * 得到指定名称的负载值，如果未指定则返回None
     */
    public func getPayload(name: String): ?Any 
    /**
     * 得到指定名称的JWT头值，如果未指定则返回None
     */
    public func getHeader(name: String): ?String 
    /**
     * 得到指定kid，如果未指定则返回None
     */
    public func getKeyId(): ?String 
    /**
     * 得到exp，如果未指定则返回None
     */
    public func getExpireAt(): ?DateTime 
    /**
     * 得到exp，返回的是从DateTime.UnixEpoch的Duration，如果未指定则返回None
     */
    public func getExpireAtDuration(): ?Duration 
    /**
     * 得到exp，返回的是从DateTime.UnixEpoch的秒数，如果未指定则返回None
     */
    public func getExpireAtSeconds(): ?Int64 
    /**
     * 得到nbf，如果未指定则返回None
     */
    public func getNotBefore(): ?DateTime 
    /**
     * 得到nbf，返回的是从DateTime.UnixEpoch的Duration，如果未指定则返回None
     */
    public func getNotBeforeDuration(): ?Duration 
    /**
     * 得到nbf，返回的是从DateTime.UnixEpoch的秒数，如果未指定则返回None
     */
    public func getNotBeforeSeconds(): ?Int64 
    /**
     * 得到负载值，如果未指定则返回None
     */
    public func getPayloadValue<T>(name: String): ?T where T <: DataParsable<T> 
    /**
     * 得到JWT头值，如果未指定则返回None
     */
    public func getHeaderValue<T>(name: String): ?T where T <: DataParsable<T> 
    /**
     * 判定指定时间是否不晚于JWT指定的nbf
     */
    public func isNotBefore(time!: DateTime = DateTime.nowUTC()): Bool 
    /**
     * 判定指定时间是早于JWT指定的exp
     */
    public func isExpired(time!: DateTime = DateTime.nowUTC()): Bool 
    /**
     * 验签
     */
    public func verifySign(): Bool 
    /**
     * 检查了exp nbf sign，如果没有指定exp 或nbf 就认为jwt在相应时间字段当前时间有效。
     */
    public func verify(): Bool 
    /**
     * 指定名称的负载确实存在，且等于value
     */
    public func verifyPayload<V>(name: String, value: V): Bool where V <: Equatable<V> 
    /**
     * 确定issuer 与参数是否相同
     */
    public func verifyIssuer<V>(issuer: V): Bool where V <: Equatable<V> 
    /**
     * 确定sub 与参数是否相同
     */
    public func verifySubject<V>(subject: V): Bool where V <: Equatable<V> 
    /**
     * 确定sud 与参数是否相同
     */
    public func verifyAudience<V>(audience: V): Bool where V <: Equatable<V> 
    /**
     * 确定iss 与参数是否相同
     */
    public func verifyIssueAt(issueAt: Int64): Bool 
    /**
     * 确定iss 与参数是否相同
     */
    public func verifyIssueAt(issueAt: Duration): Bool 
    /**
     * 确定iss 与参数是否相同
     */
    public func verifyIssueAt(issueAt: DateTime): Bool 
    /**
     * 确定jti 是否仍然有效
     */
    public func verifyId<T>(cache: JwtIdCache<T>): Bool where T <: Equatable<T> 
}
```

### `JwtIdCache<T>`
```cj
/**
 * jti的缓存
 */
public interface JwtIdCache<T> where T <: Equatable<T> {
    /**
     * 添加jti的缓存，expire是jti的存续时长
     */
    func put(id: T, expire: Duration): Unit
    /**
     * 添加jti的缓存，expire是jti的过期时间
     */
    func put(id: T, expireAt: DateTime): Unit
    /**
     * 确定缓存是否存在
     */
    func contains(id: T): Bool
    /**
     * 删除缓存
     */
    func remove(id: T): Bool
}
```

#### `JwtIdCache<T>`的实现
- `NoneJwtIdCache<T>`
    - 不保存任何数据
- `HeapJwtIdCache<T>`
    - `public class HeapJwtIdCache<T> <: JwtIdCache<T> where T <: ToString & Equatable<T>`
    - 基于`fountain::f_cache.HeapCache`