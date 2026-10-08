# f_jwt


## STDX dependency

Configure the environment variable: `export CANGJIE_STDX_DYNAMIC_PATH=/path/to/dynamic_stdx`

# JWT
This module implements the complete JWT feature set

## Signature wrapper `SignAlgo`

```cj
abstract sealed class SignAlgo {
    /**
     * The argument is the algorithm instance used for signing
     */
    protected SignAlgo(protected let digest: Digest) {}
    /**
     * Sign
     * @param data The data to sign
     * @return The signature
     */
    protected func sign(data: Array<Byte>): Array<Byte>
    /**
     * Verify a signature
     * @param data The data whose signature is to be verified
     * @param sign The signature to verify
     */
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool
}
```

### HMAC signature wrapper
```cj
public class DigestSignAlgo <: SignAlgo
```

### Asymmetric signature wrapper
```cj
abstract sealed class AsymmetricSignAlgo <: SignAlgo {
    public AsymmetricSignAlgo(digest: Digest, protected let privateKey!: ?PrivateKey = None<PrivateKey>,
        protected let publicKey!: ?PublicKey = None<PublicKey>) 
    protected static func toPrivateKey<T>(privateKey: ?T): ?PrivateKey where T <: PrivateKey 
    protected static func toPublicKey<T>(publicKey: ?T): ?PublicKey where T <: PublicKey 
}
```

#### RSA signature wrapper `RSASignAlgo`
```cj

public class RSASignAlgo <: AsymmetricSignAlgo {
    public RSASignAlgo(digest: Digest, privateKey!: ?RSAPrivateKey = None<RSAPrivateKey>,
        publicKey!: ?RSAPublicKey = None<RSAPublicKey>, private let padType!: PadOption = PKCS1) 
    protected func sign(data: Array<Byte>): Array<Byte> 
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool 
}
```

#### ECDSA signature wrapper `ECDSASignAlgo`
```cj
public class ECDSASignAlgo <: AsymmetricSignAlgo {
    public init(digest: Digest, privateKey!: ?ECDSAPrivateKey = None<ECDSAPrivateKey>,
        publicKey!: ?ECDSAPublicKey = None<ECDSAPublicKey>) 

    protected func sign(data: Array<Byte>): Array<Byte> 
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool 
}
```

#### SM2 wrapper `SM2SignAlgo`
```cj
public class SM2SignAlgo <: AsymmetricSignAlgo {
    public init(digest: Digest, privateKey!: ?SM2PrivateKey = None<SM2PrivateKey>,
        publicKey!: ?SM2PublicKey = None<SM2PublicKey>) 

    protected func sign(data: Array<Byte>): Array<Byte> 
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool 
}
```

### No signature algorithm `NoneSignAlgo`
```cj
public class NoneSignAlgo <: SignAlgo {
    private init() {
        super(NoneDigest.INSTANCE)
    }
    public static let INSTANCE = NoneSignAlgo()
    protected func sign(data: Array<Byte>): Array<Byte>
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool
}
```
- A singleton (`NoneSignAlgo.INSTANCE`) with a private constructor; both `sign` and `verify` throw `JWTException("sign algo was not be specified")` right away.
- It is the default value of `signAlgo` in `JWT` (see `src/JWT.cj`): when no signature algorithm is specified explicitly, signing and verification fail immediately with a clear reason instead of silently passing.

### HMAC signature `HMACDigest`
```cj
public class HMACDigest <: Digest {
    /**
     * @param hmac stdx.crypto.digest.HMAC
     */
    public HMACDigest(private let hmac: HMAC) {}
    /**
     * @param key Signing key
     * @param algorithm HMAC algorithm type stdx.crypto.digest.HashType
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
     * Write the argument into the signature algorithm
     */
    public func write(buffer: Array<Byte>): Unit 
    /**
     * Sign; returns the signature result
     */
    public func finish(): Array<Byte> 
    /**
     * Perform the signing; the signature data is copied into the argument to
     */
    public func finish(to!: Array<Byte>): Unit 
    /**
     * Reset the algorithm data
     */
    public func reset(): Unit 
    /**
     * Name of the signature algorithm
     */
    public prop algorithm: String 
}

```


## `JWT`

```cj
sealed abstract class JWT {
    protected init() {}
    /**
     * Add a JWT header
     */
    public func header(name: String, value: String): This 
    /**
     * Specify HMAC-MD5 as the signature algorithm
     * @param key Signing key
     */
    public func hmacMD5(key: Array<Byte>): This 
    /**
     * Specify HMAC-MD5 as the signature algorithm
     * @param key Signing key represented in BASE64
     */
    public func hmacMD5ByBase64Key(key: String): This 
    /**
     * Specify HMAC-MD5 as the signature algorithm
     * @param key Signing key represented in HEX
     */
    public func hmacMD5ByHexKey(key: String): This
    /**
     * Specify HMAC-SHA1 as the signature algorithm
     * @param key Signing key
     */ 
    public func hmacSHA1(key: Array<Byte>): This 
    /**
     * Specify HMAC-SHA1 as the signature algorithm
     * @param key BASE64 signing key
     */ 
    public func hmacSHA1ByBase64Key(key: String): This 
    /**
     * Specify HMAC-SHA1 as the signature algorithm
     * @param key HEX signing key
     */
    public func hmacSHA1ByHexKey(key: String): This 
    /**
     * Specify HMAC-SHA224 as the signature algorithm
     * @param key Signing key
     */
    public func hmacSHA224(key: Array<Byte>): This 
    /**
     * Specify HMAC-SHA224 as the signature algorithm
     * @param key Signing key represented in BASE64
     */
    public func hmacSHA224ByBase64Key(key: String): This 
    /**
     * Specify HMAC-SHA224 as the signature algorithm
     * @param key Signing key represented in HEX
     */
    public func hmacSHA224ByHexKey(key: String): This 
    /**
     * Specify HMAC-SHA256 as the signature algorithm
     * @param key Signing key
     */
    public func hmacSHA256(key: Array<Byte>): This 
    /**
     * Specify HMAC-SHA256 as the signature algorithm
     * @param key Signing key represented in BASE64
     */
    public func hmacSHA256ByBase64Key(key: String): This 
    /**
     * Specify HMAC-SHA256 as the signature algorithm
     * @param key Signing key represented in HEX
     */
    public func hmacSHA256ByHexKey(key: String): This 
    /**
     * Specify HMAC-SHA384 as the signature algorithm
     * @param key Signing key
     */
    public func hmacSHA384(key: Array<Byte>): This 
    /**
     * Specify HMAC-SHA384 as the signature algorithm
     * @param key Signing key represented in BASE64
     */
    public func hmacSHA384ByBase64Key(key: String): This 
    /**
     * Specify HMAC-SHA384 as the signature algorithm
     * @param key Signing key represented in HEX
     */
    public func hmacSHA384ByHexKey(key: String): This 
    /**
     * Specify HMAC-SHA512 as the signature algorithm
     * @param key Signing key
     */
    public func hmacSHA512(key: Array<Byte>): This 
    /**
     * Specify HMAC-SHA512 as the signature algorithm
     * @param key Signing key represented in BASE64
     */
    public func hmacSHA512ByBase64Key(key: String): This 
    /**
     * Specify HMAC-SHA512 as the signature algorithm
     * @param key Signing key represented in HEX
     */
    public func hmacSHA512ByHexKey(key: String): This 
    /**
     * Specify ECDSA224 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     */
    public func ecdsa224(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * Specify ECDSA256 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     */
    public func ecdsa256(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * Specify ECDSA384 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     */
    public func ecdsa384(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * Specify ECDSA512 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     */
    public func ecdsa512(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>): This 
    /**
     * Specify RSA256 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     * @param padType Padding type
     */
    public func rsa256(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>,
        padType!: PadOption = PKCS1): This 
    /**
     * Specify RSA384 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     * @param padType Padding type
     */
    public func rsa384(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>,
        padType!: PadOption = PKCS1): This 
    /**
     * Specify RSA512 as the signature algorithm
     * @param privateKey Private key
     * @param publicKey Private key
     * @param padType Padding type
     */
    public func rsa512(privateKeyPem!: ?String = None<String>, publicKeyPem!: ?String = None<String>,
        padType!: PadOption = PKCS1): This 
    /**
     * Specify the keyId header
     */
    public func keyId(keyId: String): This 
    /**
     * Specify the iss payload
     */
    public func issuer(iss: String): This 
    /**
     * Specify the sub payload
     */
    public func subject(sub: String): This
    /**
     * Specify the aud payload
     */
    public func audience(aud: String): This 
    /**
     * Specify the exp payload
     * @param expire Number of seconds until expiry
     */
    public func expire(expire: Int64): This 
    /**
     * Specify the exp payload
     * @param expire Expiry as a Duration
     */
    public func expire(duration: Duration): This 
    /**
     * Specify the exp payload
     * @param expireAt Expiry time
     */
    public func expireAt(expireAt: DateTime): This 
    /**
     * Specify the exp payload
     * @param expireAt Expiry time, as a Duration since DateTime.UnixEpoch
     */
    public func expireAt(duration: Duration): This 
    /**
     * Specify the exp payload
     * @param expireAt Expiry time, as seconds since DateTime.UnixEpoch
     */
    public func expireAt(expireAt: Int64): This 
    /**
     * Specify the nbf payload
     * @param nbf Takes effect after this time, as seconds since DateTime.UnixEpoch
     */
    public func notBeforeAt(nbf: Int64): This 
    /**
     * Specify the nbf payload
     * @param nbf Takes effect after this time, as a Duration since DateTime.UnixEpoch
     */
    public func notBeforeAt(nbf: Duration): This 
    /**
     * Specify the nbf payload
     * @param nbf Takes effect after this time
     */
    public func notBeforeAt(nbf: DateTime): This 
    /**
     * Specify the iat payload
     * @param iat Seconds since DateTime.UnixEpoch
     */
    public func issuedAt(iat: Int64): This 
    /**
     * Specify the iat payload
     * @param iat Duration since DateTime.UnixEpoch
     */
    public func issuedAt(iat: Duration): This 
    /**
     * Specify the iat payload
     * @param iat 
     */
    public func issuedAt(iat: DateTime): This 
    /**
     * Specify the jti payload
     * @param jti 
     * @param expire Lifetime of the jti cache
     * @param cache jti cache 
     */
    public func jwtId<T>(jti: T, expire: Duration, cache: JwtIdCache<T>): This where T <: Equatable<T> & ToString 
    /**
     * Specify the jti payload
     * @param jti 
     * @param expireAt Expiry time of the jti cache
     * @param cache jti cache 
     */
    public func jwtId<T>(jti: T, expireAt: DateTime, cache: JwtIdCache<T>): This where T <: Equatable<T> & ToString 
    /**
     * Add a payload
     * @param name Payload name
     * @param value Payload value 
     */
    public func addPayload<T>(name: String, value: T): This where T <: ToString 
    /**
     * Add payloads
     * @param map Use the KEY of map as the payload name and the value of map as the payload value
     */
    public func addPayload<V, M>(map: M): This where V <: ToString, M <: Map<String, V> 
    /**
     * Add payloads
     * @param data Use the public member properties or public member variables of the object as payloads: the member name is
     * the payload name and the member value is the payload value
     */
    public func addPayload<T>(data: T): This where T <: Object & ObjectData<T> 
    /**
     * JWT signing object
     */
    public static func encoder(): JWTEncoder 
    /**
     * JWT decoding
     */
    public static func verifier(data: String): JWTVerifier 
}
```

### `JWTEncoder`
```cj
public class JWTEncoder <: JWT {
    JWTEncoder() {}
    /**
     * Sign
     */
    public func sign(): String 
}
```

### JWT decoder `JWTVerifier`
```cj
public class JWTVerifier <: JWT {
    /**
     * Get the payload value with the given name, or None if it is not specified
     */
    public func getPayload(name: String): ?Any 
    /**
     * Get the JWT header value with the given name, or None if it is not specified
     */
    public func getHeader(name: String): ?String 
    /**
     * Get the given kid, or None if it is not specified
     */
    public func getKeyId(): ?String 
    /**
     * Get exp, or None if it is not specified
     */
    public func getExpireAt(): ?DateTime 
    /**
     * Get exp as a Duration since DateTime.UnixEpoch, or None if it is not specified
     */
    public func getExpireAtDuration(): ?Duration 
    /**
     * Get exp as seconds since DateTime.UnixEpoch, or None if it is not specified
     */
    public func getExpireAtSeconds(): ?Int64 
    /**
     * Get nbf, or None if it is not specified
     */
    public func getNotBefore(): ?DateTime 
    /**
     * Get nbf as a Duration since DateTime.UnixEpoch, or None if it is not specified
     */
    public func getNotBeforeDuration(): ?Duration 
    /**
     * Get nbf as seconds since DateTime.UnixEpoch, or None if it is not specified
     */
    public func getNotBeforeSeconds(): ?Int64 
    /**
     * Get the payload value, or None if it is not specified
     */
    public func getPayloadValue<T>(name: String): ?T where T <: DataParsable<T> 
    /**
     * Get the JWT header value, or None if it is not specified
     */
    public func getHeaderValue<T>(name: String): ?T where T <: DataParsable<T> 
    /**
     * Determine whether the given time is not later than the nbf specified in the JWT
     */
    public func isNotBefore(time!: DateTime = DateTime.nowUTC()): Bool 
    /**
     * Determine whether the given time is earlier than the exp specified in the JWT
     */
    public func isExpired(time!: DateTime = DateTime.nowUTC()): Bool 
    /**
     * Verify the signature
     */
    public func verifySign(): Bool 
    /**
     * Checks exp, nbf and sign; if exp or nbf is not specified, the jwt is considered valid at the current time for that field.
     */
    public func verify(): Bool 
    /**
     * The payload with the given name really exists and equals value
     */
    public func verifyPayload<V>(name: String, value: V): Bool where V <: Equatable<V> 
    /**
     * Determine whether issuer equals the argument
     */
    public func verifyIssuer<V>(issuer: V): Bool where V <: Equatable<V> 
    /**
     * Determine whether sub equals the argument
     */
    public func verifySubject<V>(subject: V): Bool where V <: Equatable<V> 
    /**
     * Determine whether aud equals the argument
     */
    public func verifyAudience<V>(audience: V): Bool where V <: Equatable<V> 
    /**
     * Determine whether iat equals the argument
     */
    public func verifyIssueAt(issueAt: Int64): Bool 
    /**
     * Determine whether iat equals the argument
     */
    public func verifyIssueAt(issueAt: Duration): Bool 
    /**
     * Determine whether iat equals the argument
     */
    public func verifyIssueAt(issueAt: DateTime): Bool 
    /**
     * Determine whether the jti is still valid
     */
    public func verifyId<T>(cache: JwtIdCache<T>): Bool where T <: Equatable<T> 
}
```

### `JwtIdCache<T>`
```cj
/**
 * Cache of jti
 */
public interface JwtIdCache<T> where T <: Equatable<T> {
    /**
     * Add a jti cache entry; expire is the lifetime of the jti
     */
    func put(id: T, expire: Duration): Unit
    /**
     * Add a jti cache entry; expireAt is the expiry time of the jti
     */
    func put(id: T, expireAt: DateTime): Unit
    /**
     * Determine whether the cache entry exists
     */
    func contains(id: T): Bool
    /**
     * Remove the cache entry
     */
    func remove(id: T): Bool
}
```

#### Implementations of `JwtIdCache<T>`
- `NoneJwtIdCache<T>`
    - Stores no data at all
- `HeapJwtIdCache<T>`
    - `public class HeapJwtIdCache<T> <: JwtIdCache<T> where T <: ToString & Equatable<T>`
    - Based on `fountain::f_cache.HeapCache`

## Exceptions

`JWTException` (`fountain::f_jwt.exception`, `<: fountain::f_exception.BaseException`) is the exception type of this module;
its constructors match the base class: `()`, `(message: String)`, `(caused: Exception)` and `(message: String, caused: Exception)`.
`NoneSignAlgo.sign` / `NoneSignAlgo.verify` throw it.
