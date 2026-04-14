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
