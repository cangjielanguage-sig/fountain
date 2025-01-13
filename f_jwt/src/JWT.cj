/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    utility is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_jwt

import std.collection.{HashMap, Map}
import std.convert.Parsable
import std.time.DateTime
import crypto.digest.*
import crypto.keys.PadOption
import encoding.json.*
import encoding.hex.*
import encoding.base64.*
import crypto.keys.*
import f_data.{ObjectData, DataObject}
import f_exception.UnreadableException
import f_jwt.exception.JWTException

public class JWT {
    let headers = HashMap<String, String>()
    let payload = HashMap<String, Any>()
    var signAlgo: SignAlgo = NoneSignAlgo.INSTANCE

    public init() {}

    public func header(name: String, value: String): JWT {
        headers[name] = value
        this
    }
    private prop HM5: JWT {
        get() {
            header("alg", "HS5")
            this
        }
    }
    public func hmacMD5(key: Array<Byte>) {
        signAlgo = DigestSignAlgo(HMACDigest(key, HashType.MD5))
        HM5
    }
    public func hmacMD5ByBase64Key(key: String) {
        hmacMD5(fromBase64(key))
    }
    public func hmacMD5ByHexKey(key: String) {
        hmacMD5(fromHex(key))
    }
    private prop HS1: JWT {
        get() {
            header("alg", "HS1")
            this
        }
    }
    public func hmacSHA1(key: Array<Byte>) {
        signAlgo = DigestSignAlgo(HMACDigest(key, HashType.SHA1))
        HS1
    }
    public func hmacSHA1ByBase64Key(key: String) {
        hmacSHA1(fromBase64(key))
    }
    public func hmacSHA1ByHexKey(key: String) {
        hmacSHA1(fromHex(key))
    }
    private prop HS224: JWT {
        get() {
            header("alg", "HS224")
            this
        }
    }
    public func hmacSHA224(key: Array<Byte>) {
        signAlgo = DigestSignAlgo(HMACDigest(key, HashType.SHA224))
        HS224
    }
    public func hmacSHA224ByBase64Key(key: String) {
        hmacSHA224(fromBase64(key))
    }
    public func hmacSHA224ByHexKey(key: String) {
        hmacSHA224(fromHex(key))
    }
    private prop HS256: JWT {
        get() {
            header("alg", "HS256")
            this
        }
    }
    public func hmacSHA256(key: Array<Byte>) {
        signAlgo = DigestSignAlgo(HMACDigest(key, HashType.SHA1))
        HS256
    }
    public func hmacSHA256ByBase64Key(key: String) {
        hmacSHA256(fromBase64(key))
    }
    public func hmacSHA256ByHexKey(key: String) {
        hmacSHA256(fromHex(key))
    }
    private prop HS384: JWT {
        get() {
            header("alg", "HS384")
            this
        }
    }
    public func hmacSHA384(key: Array<Byte>) {
        signAlgo = DigestSignAlgo(HMACDigest(key, HashType.SHA1))
        HS384
    }
    public func hmacSHA384ByBase64Key(key: String) {
        hmacSHA384(fromBase64(key))
    }
    public func hmacSHA384ByHexKey(key: String) {
        hmacSHA384(fromHex(key))
    }
    private prop HS512: JWT {
        get() {
            header("alg", "HS512")
            this
        }
    }
    public func hmacSHA512(key: Array<Byte>) {
        signAlgo = DigestSignAlgo(HMACDigest(key, HashType.SHA1))
        HS512
    }
    public func hmacSHA512ByBase64Key(key: String) {
        hmacSHA512(fromBase64(key))
    }
    public func hmacSHA512ByHexKey(key: String) {
        hmacSHA512(fromHex(key))
    }
    private prop ES224: JWT {
        get() {
            header("alg", "ES224")
        }
    }
    public func ecdsa224(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => ECDSASignAlgo(SHA224(), privateKey: ECDSAPrivateKey.decodeFromPem(pri),
                publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case (Some(pri), None) => ECDSASignAlgo(SHA224(), privateKey: ECDSAPrivateKey.decodeFromPem(pri))
            case (None, Some(pub)) => ECDSASignAlgo(SHA224(), publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case _ => throw JWTException("no key of ECDSA is been specified")
        }
        ES224
    }
    private prop ES256: JWT {
        get() {
            header("alg", "ES256")
        }
    }

    public func ecdsa256(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => ECDSASignAlgo(SHA256(), privateKey: ECDSAPrivateKey.decodeFromPem(pri),
                publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case (Some(pri), None) => ECDSASignAlgo(SHA256(), privateKey: ECDSAPrivateKey.decodeFromPem(pri))
            case (None, Some(pub)) => ECDSASignAlgo(SHA256(), publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case _ => throw JWTException("no key of ECDSA is been specified")
        }
        ES256
    }
    private prop ES384: JWT {
        get() {
            header("alg", "ES384")
        }
    }
    public func ecdsa384(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => ECDSASignAlgo(SHA384(), privateKey: ECDSAPrivateKey.decodeFromPem(pri),
                publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case (Some(pri), None) => ECDSASignAlgo(SHA384(), privateKey: ECDSAPrivateKey.decodeFromPem(pri))
            case (None, Some(pub)) => ECDSASignAlgo(SHA384(), publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case _ => throw JWTException("no key of ECDSA is been specified")
        }
        ES384
    }
    private prop ES512: JWT {
        get() {
            header("alg", "ES512")
        }
    }
    public func ecdsa512(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => ECDSASignAlgo(SHA512(), privateKey: ECDSAPrivateKey.decodeFromPem(pri),
                publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case (Some(pri), None) => ECDSASignAlgo(SHA512(), privateKey: ECDSAPrivateKey.decodeFromPem(pri))
            case (None, Some(pub)) => ECDSASignAlgo(SHA512(), publicKey: ECDSAPublicKey.decodeFromPem(pub))
            case _ => throw JWTException("no key of ECDSA is been specified")
        }
        ES512
    }
    private prop RS256: JWT {
        get() {
            header("alg", "RS256")
        }
    }
    public func rsa256(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None, padType!: PadOption = PKCS1) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => RSASignAlgo(SHA256(), privateKey: RSAPrivateKey.decodeFromPem(pri),
                publicKey: RSAPublicKey.decodeFromPem(pub), padType: padType)
            case (Some(pri), None) => RSASignAlgo(SHA256(), privateKey: RSAPrivateKey.decodeFromPem(pri),
                padType: padType)
            case (None, Some(pub)) => RSASignAlgo(SHA256(), publicKey: RSAPublicKey.decodeFromPem(pub), padType: padType
            )
            case _ => throw JWTException("no key of RSA is been specified")
        }
        RS256
    }
    private prop RS384: JWT {
        get() {
            header("alg", "RS384")
        }
    }
    public func rsa384(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None, padType!: PadOption = PKCS1) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => RSASignAlgo(SHA384(), privateKey: RSAPrivateKey.decodeFromPem(pri),
                publicKey: RSAPublicKey.decodeFromPem(pub), padType: padType)
            case (Some(pri), None) => RSASignAlgo(SHA384(), privateKey: RSAPrivateKey.decodeFromPem(pri),
                padType: padType)
            case (None, Some(pub)) => RSASignAlgo(SHA384(), publicKey: RSAPublicKey.decodeFromPem(pub), padType: padType
            )
            case _ => throw JWTException("no key of RSA is been specified")
        }
        RS384
    }
    private prop RS512: JWT {
        get() {
            header("alg", "RS512")
        }
    }
    public func rsa512(privateKeyPem!: ?String = None, publicKeyPem!: ?String = None, padType!: PadOption = PKCS1) {
        signAlgo = match ((privateKeyPem, publicKeyPem)) {
            case (Some(pri), Some(pub)) => RSASignAlgo(SHA512(), privateKey: RSAPrivateKey.decodeFromPem(pri),
                publicKey: RSAPublicKey.decodeFromPem(pub), padType: padType)
            case (Some(pri), None) => RSASignAlgo(SHA512(), privateKey: RSAPrivateKey.decodeFromPem(pri),
                padType: padType)
            case (None, Some(pub)) => RSASignAlgo(SHA512(), publicKey: RSAPublicKey.decodeFromPem(pub), padType: padType
            )
            case _ => throw JWTException("no key of RSA is been specified")
        }
        RS512
    }
    public func keyId(keyId: String): JWT {
        header("kid", keyId)
    }
    public func issuer(iss: String): JWT {
        addPayload('iss', iss)
    }
    public func subject(sub: String): JWT {
        addPayload('sub', sub)
    }
    public func audience(aud: String): JWT {
        addPayload('aud', aud)
    }
    public func expire(expire: Int64): JWT {
        this.expire(Duration.millisecond * expire)
    }
    public func expire(duration: Duration): JWT {
        expireAt(DateTime.now() + duration)
    }
    public func expireAt(expireAt: DateTime): JWT {
        this.expireAt(expireAt - DateTime.UnixEpoch)
    }
    public func expireAt(duration: Duration): JWT {
        this.expireAt(duration.toMilliseconds())
    }
    public func expireAt(expireAt: Int64): JWT {
        addPayload("exp", expireAt)
    }
    public func notBefore(nbf: Int64): JWT {
        addPayload("nbf", nbf)
    }
    public func notBefore(nbf: Duration): JWT {
        notBefore(nbf.toMilliseconds())
    }
    public func notBeforeAt(nbf: DateTime): JWT {
        notBefore(nbf.toUnixTimeStamp())
    }
    public func issuedAt(iat: Int64): JWT {
        addPayload("iat", iat)
    }
    public func issuedAt(iat: Duration): JWT {
        addPayload("iat", iat.toMilliseconds())
    }
    public func issuedAt(iat: DateTime): JWT {
        addPayload("iat", iat.toUnixTimeStamp().toMilliseconds())
    }
    public func jwtId(jti: String): JWT {
        addPayload("jti", jti)
    }

    public func addPayload<T>(name: String, value: T): JWT where T <: ToString {
        payload[name] = value
        this
    }
    public func addPayload<V, M>(map: M): JWT where V <: ToString, M <: Map<String, V> {
        for ((k, v) in map) {
            addPayload<V>(k, v)
        }
        this
    }
    public func addPayload<T>(data: T): JWT where T <: Object & ObjectData<T> {
        match (data.toData()) {
            case x: DataObject<T> => for ((k, v) in x) {
                addPayload(k, v)
            }
            case _ => throw UnreadableException()
        }
        this
    }

    public func encoder(): JWTEncoder {
        JWTEncoder(this)
    }
    public func verifier(data: String): JWTVerifier {
        JWTVerifier(data, this)
    }
}

public class JWTEncoder {
    JWTEncoder(private let jwt: JWT) {}
    public func sign(): String {
        var json = JsonObject()
        for ((k, v) in jwt.headers) {
            json.put(k, JsonString(v))
        }
        let headerJson = json.toString()
        let headerBase64 = toBase64(headerJson)
        json = JsonObject()
        for ((k, v) in jwt.payload) {
            match (v) {
                case x: Bool => json.put(k, JsonBool(x))
                case x: Int64 => json.put(k, JsonInt(x))
                case x: UInt64 => json.put(k, JsonInt(Int64(x)))
                case x: Int32 => json.put(k, JsonInt(Int64(x)))
                case x: UInt32 => json.put(k, JsonInt(Int64(x)))
                case x: Int16 => json.put(k, JsonInt(Int64(x)))
                case x: UInt16 => json.put(k, JsonInt(Int64(x)))
                case x: Int8 => json.put(k, JsonInt(Int64(x)))
                case x: UInt8 => json.put(k, JsonInt(Int64(x)))
                case x: Float64 => json.put(k, JsonFloat(x))
                case x: Float32 => json.put(k, JsonFloat(Float64(x)))
                case x: Float16 => json.put(k, JsonFloat(Float64(x)))
                case x: String => json.put(k, JsonString(x))
                case x: Rune => json.put(k, JsonString(x.toString()))
                case x: JsonValue => json.put(k, x)
                case x: ToString => json.put(k, JsonString(x.toString()))
                case _ => throw JWTException("current value of key as ${k} does not support for payload")
            }
        }
        let payloadJson = json.toString()
        let payloadBase64 = toBase64(payloadJson)
        "${headerBase64}.${payloadBase64}.${jwt.signAlgo.signToBase64(bytesForSign(headerJson, payloadJson))}"
    }
}

public class JWTVerifier {
    private let headerBytes: Array<Byte>
    private let payloadBytes: Array<Byte>
    private let signBytes: Array<Byte>
    JWTVerifier(private let data: String, private let jwt: JWT) {
        let firstDot = data.indexOf(".") ?? -1
        let lastDot = data.lastIndexOf(".", firstDot + 1) ?? -1
        headerBytes = fromBase64(data[0..firstDot])
        payloadBytes = fromBase64(data[firstDot + 1..lastDot])
        signBytes = fromBase64(data[lastDot + 1..])
        let headerJson = JsonValue.fromStr(String.fromUtf8(headerBytes))
        let payloadJson = JsonValue.fromStr(String.fromUtf8(payloadBytes))
        populate<String>(headerJson, jwt.headers)
        populate<Any>(payloadJson, jwt.payload)
    }
    private static func populate<T>(json: JsonValue, map: HashMap<String, T>) {
        match (json) {
            case x: JsonObject => for ((k, v) in x.getFields()) {
                map[k] = getJsonValue<T>(v)
            }
            case _ => ()
        }
    }
    private static func getJsonValue<T>(v: JsonValue): T {
        let r: Any = match (v) {
            case x: JsonBool => x.getValue()
            case x: JsonInt => x.getValue()
            case x: JsonString => x.getValue()
            case x: JsonFloat => x.getValue()
            case x: JsonArray => Array<Any>(x.size()) {
                i => if (let Some(jv) <- x.get(i)) {
                    getJsonValue<T>(jv)
                } else {
                    None<Any>
                }
            }
            case x: JsonObject =>
                let vm = HashMap<String, T>()
                populate<T>(x, vm)
                vm
            case _ => ()
        }
        (r as T).getOrThrow()
    }
    public func getPayload(name: String): ?Any {
        jwt.payload.get(name)
    }
    public func getHeader(name: String): ?String {
        jwt.headers.get(name)
    }

    public func getExpireAt(): ?DateTime {
        if (let Some(d) <- getExpireAtDuration()) {
            DateTime.now() + d
        } else {
            None
        }
    }
    public func getExpireAtDuration(): ?Duration {
        if (let Some(d) <- getExpireAtMillis()) {
            Duration.millisecond * d
        } else {
            None
        }
    }
    public func getExpireAtMillis(): ?Int64 {
        getPayloadValue<Int64>('exp')
    }
    public func getPayloadValue<T>(name: String): ?T where T <: Parsable<T> {
        if (let Some(x) <- getPayload(name)) {
            match (x) {
                case v: T => v
                case v: String => tryParse<T>(v)
                case v: ToString => tryParse<T>(v.toString())
                case _ => None
            }
        } else {
            None
        }
    }
    public func getHeaderValue<T>(name: String): ?T where T <: Parsable<T> {
        tryParse<T>(getHeader(name))
    }
    private func tryParse<T>(value: ?String): ?T where T <: Parsable<T> {
        if (let Some(x) <- value) {
            T.tryParse(x)
        } else {
            None
        }
    }
    public func verify(): Bool {
        jwt.signAlgo.verify(bytesForSign(headerBytes, payloadBytes), signBytes)
    }
}
