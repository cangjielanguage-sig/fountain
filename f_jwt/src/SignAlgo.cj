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

import std.crypto.digest.{Digest, digest as stdDigest}
import crypto.digest.*
import crypto.keys.*
import crypto.x509.{PrivateKey, PublicKey}
import f_jwt.exception.*

sealed abstract class SignAlgo{
    protected SignAlgo(protected let digest: Digest){}
    protected func sign(data: Array<Byte>): Array<Byte>
    func sign(data: String): Array<Byte>{
        sign(data.toArray())
    }
    func signToBase64(data: Array<Byte>): String{
        let sign = sign(data)
        toBase64(sign)
    }
    func signToBase64(data: String): String{
        signToBase64(data.toArray())
    }
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool
    func verifyFromBase64(data: Array<Byte>, base64: String): Bool{
        let sign = fromBase64(base64)
        verify(data, sign)
    }
    func verifyFromBase64(data: String, base64: String): Bool {
        verifyFromBase64(data.toArray(), base64)
    }
    func doDigest(data: Array<Byte>): Array<Byte>{
        stdDigest(digest, data)
    }
}
public class DigestSignAlgo <: SignAlgo {
    public init(digest: Digest){
        super(digest)
    }
    protected func sign(data: Array<Byte>): Array<Byte>{
        doDigest(data)
    }
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool {
        this.sign(data) == sign
    }
}
abstract sealed class AsymmetricSignAlgo <: SignAlgo {
    public AsymmetricSignAlgo(
        digest: Digest,
        protected let privateKey!: ?PrivateKey = None<PrivateKey>,
        protected let publicKey!: ?PublicKey = None<PublicKey>){
            super(digest)
        }
    protected static func toPrivateKey<T>(privateKey: ?T): ?PrivateKey where T <: PrivateKey {
        match(privateKey){
            case Some(x) => x as PrivateKey
            case _ => None<PrivateKey>
        }
    }
    protected static func toPublicKey<T>(publicKey: ?T): ?PublicKey where T <: PublicKey {
        match(publicKey){
            case Some(x) => x as PublicKey
            case _ => None<PublicKey>
        }
    }
}
public class RSASignAlgo <: AsymmetricSignAlgo {
    public RSASignAlgo(
        digest: Digest,
        privateKey!: ?RSAPrivateKey = None<RSAPrivateKey>,
        publicKey!: ?RSAPublicKey = None<RSAPublicKey>,
        private let padType!: PadOption = PKCS1){
        super(digest, privateKey: toPrivateKey(privateKey), publicKey: toPublicKey(publicKey))
    }

    protected func sign(data: Array<Byte>): Array<Byte>{
        match(privateKey){
            case Some(key) =>
                let digest = doDigest(data)
                (key as RSAPrivateKey)?.sign(this.digest, digest, padType: padType) ?? []
            case _ => throw JWTException("PrivateKey does not exist")
        }
    }
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool {
        match(publicKey){
            case Some(key) =>
                let digest = doDigest(data)
                (key as RSAPublicKey)?.verify(this.digest, digest, sign, padType: padType) ?? false
            case _ => throw JWTException("PublicKey does not exist")
        }
    }
}
public class ECDSASignAlgo <: AsymmetricSignAlgo {
    public init(
        digest: Digest,
        privateKey!: ?ECDSAPrivateKey = None<ECDSAPrivateKey>,
        publicKey!: ?ECDSAPublicKey = None<ECDSAPublicKey>){
        super(digest, privateKey: toPrivateKey(privateKey), publicKey: toPublicKey(publicKey))
    }

    protected func sign(data: Array<Byte>): Array<Byte>{
        match(privateKey){
            case Some(key) => 
                (key as ECDSAPrivateKey)?.sign(doDigest(data)) ?? []
            case _ => throw JWTException("PrivateKey does not exist")
        }
    }
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool {
        match(publicKey){
            case Some(key) => (key as ECDSAPublicKey)?.verify(doDigest(data), sign) ?? false
            case _ => throw JWTException("PublicKey does not exist")
        }
    }
}
public class SM2SignAlgo <: AsymmetricSignAlgo {
    public init(
        digest: Digest,
        privateKey!: ?SM2PrivateKey = None<SM2PrivateKey>,
        publicKey!: ?SM2PublicKey = None<SM2PublicKey>){
        super(digest, privateKey: toPrivateKey(privateKey), publicKey: toPublicKey(publicKey))
    }

    protected func sign(data: Array<Byte>): Array<Byte>{
        match(privateKey){
            case Some(key) => 
                (key as SM2PrivateKey)?.sign(doDigest(data)) ?? []
            case _ => throw JWTException("PrivateKey does not exist")
        }
    }
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool {
        match(publicKey){
            case Some(key) => (key as SM2PublicKey)?.verify(doDigest(data), sign) ?? false
            case _ => throw JWTException("PublicKey does not exist")
        }
    }
}
private class NoneDigest <: Digest {
    static let INSTANCE = NoneDigest()
    private init(){}
    public prop blockSize: Int64{
        get(){
            0
        }
    }
    public prop size: Int64 {
        get(){
            0
        }
    }
    public func finish(): Array<Byte>{
        []
    }
    public func reset(): Unit {}
    public func write(buffer: Array<Byte>): Unit {}
}
public class NoneSignAlgo <: SignAlgo{
    private init(){
        super(NoneDigest.INSTANCE)
    }
    public static let INSTANCE = NoneSignAlgo()

    protected func sign(data: Array<Byte>): Array<Byte>{
        throw JWTException("sign algo was not be specified")
    }
    protected func verify(data: Array<Byte>, sign: Array<Byte>): Bool {
        throw JWTException("sign algo was not be specified")
    }
}
