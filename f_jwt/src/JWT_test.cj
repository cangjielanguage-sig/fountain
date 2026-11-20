/*
Copyright (c) 2025 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 */
package fountain::f_jwt

import std.unittest.*
import std.unittest.testmacro.*
import std.time.DateTime
import std.collection.HashMap
import stdx.encoding.hex.*
import stdx.encoding.base64.*
import std.crypto.digest.digest as stdDigest
import stdx.crypto.digest.HashType
import stdx.crypto.keys.{Curve, ECDSAPrivateKey, ECDSAPublicKey}
import fountain::f_jwt.exception.JWTException

// 仅用于单元测试的一次性 RSA 密钥对，不得用于生产。
// 生成命令：
//   openssl genrsa -out rsa_test.pem 2048
//   openssl rsa -in rsa_test.pem -pubout -out rsa_test_pub.pem
private let RSA_PRIVATE_PEM = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCde/ePFWkPYJ8J
+T6pzVRC91pCbZA+yrJAHTE/Gi0Mbw5sV7L1uMH50WDg6KhofyGYFejBdj3p21dX
dfl0QVzQUiVma58lsckGzeuWulI6bGEMx4b4T7npwDKsKhf2u1xGZ5cgdIS931qi
7u58PdzeXLd7blD2qSJiBpndqbhAa2scktwAeyP0tV4hynB/DxoEe8Zaure1A+gE
GkLuTEAY+VzCHlRmckLkTYd2qXhH4B4uEgvYhq20bATgov2eQscf6SZYO+gy4SNR
x/UfHGjabzQPOWuu9Jj5lebLg97J9qMr/LegcTTMRmHBtVvksUyqQSvhPwUkYcS7
pC2QDTNhAgMBAAECggEAKZLxXpeDXajfM03WKhNnfCo6bLDp1HnEJsLOHl91pwOm
Zhmcx9uXcbDBh35D/xoYr0KRaIkjfRoHa7JcQUGEFAarkuc0Y0oUzLQNzoOvc3br
A+mkiubZKIkxl1uhaeQ6TufH8Kxx4oIVNlAnKytVpGoLkg0kWIl75y7g7bCBUJfg
oK0XbupNHyF5uolGDanbIS/+HEQ2VG3EQrmD2kGfeycPZr4wylRwJzrMVYrJP6Zi
ABTDq9C/L0evpvhBPWhGTLPJ/W+A80d9t5FxkrCtE65/L0tlstFWQ9Gqpw4A4Mzq
cFSuSjprqEzwBWZbrmYPHS1dGgcOeO2pHP3sjE36pQKBgQDZAS4ESFeIAgV+F6fp
x+eJKNOmYOEobdYoo0ebAghnhBZPx/kUMlTeWxOiPQ1oFMo1yQ8lPZwBaE5EAQQf
7YpRzp9gGzjK8YP+OFkSIJA800RQFuAmINsLPt/nirX8oxPMurg1toJEh6uUw4jZ
vqHJBX7jll9U9bmLm7Gq+ms/2wKBgQC5yK8MEgTcXfSI13hxVb+Tp2wPZlIV+pqJ
2c4a0t3a95p2ys07OWENLjJeynByAAq9yaIeTn/p9JC2BIpAOjhK3aKD+YvNPL2e
zWtgtMvj/eGl7hnHUfM+T/t9ptzylEwCkB4DALH2ZeOFvbphFNN9nicHp3SJdYv5
sid9VAfMcwKBgQDFE/Q1wXl1NNjGJjfB8mINx/1Hyg5SSEZJy9gZJ6R4VpZoyGUm
eXtoIXDYU/gcAV2PsVTG7ogDIzaJPh7/3BxVpYBKqQ5QCT1loMkL1HUKOJh+3/eb
yRUFxolUYD5c/cHamez4IxN1p30lctuTXTTTOuF9UbCsmSl0Z+bYL+s9JwKBgHw0
JILnUQSac69Aji8G6qsmFOI+v8Yd4k8io93e9586RbQBZS+g7rdHGTmyEXbFfGjh
clbcmDuq20w0wNCrm5LBlbKxlLtDTmnqX00p0d28j6zE/8r3iK0x/6pDchdi+WYF
P2s2fcOC3pc8/muE5tdmciV12D1FrqziY/Avy37tAoGBALpS0w4VPgjbQAHngaeW
ayCzPLJeGPtWQapSTOcBHKYACma0lZK9nROIn8YonyoGfRemzZuOMk+KAqE1ZAZS
ndWWVdqiRTCemhUHUWbSlMe9DxZqu/OPUVMSqZH/QHNPJwtXc/wGqysajZQcq+bR
V4xfMzuL02K3/pn1gtg87CWd
-----END PRIVATE KEY-----'''

private let RSA_PUBLIC_PEM = '''
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnXv3jxVpD2CfCfk+qc1U
QvdaQm2QPsqyQB0xPxotDG8ObFey9bjB+dFg4OioaH8hmBXowXY96dtXV3X5dEFc
0FIlZmufJbHJBs3rlrpSOmxhDMeG+E+56cAyrCoX9rtcRmeXIHSEvd9aou7ufD3c
3ly3e25Q9qkiYgaZ3am4QGtrHJLcAHsj9LVeIcpwfw8aBHvGWrq3tQPoBBpC7kxA
GPlcwh5UZnJC5E2Hdql4R+AeLhIL2IattGwE4KL9nkLHH+kmWDvoMuEjUcf1Hxxo
2m80DzlrrvSY+ZXmy4PeyfajK/y3oHE0zEZhwbVb5LFMqkEr4T8FJGHEu6QtkA0z
YQIDAQAB
-----END PUBLIC KEY-----'''

// ECDSA 测试密钥对在用例里用 stdx 现生成（ECDSAPublicKey(pri) 可直接由私钥导出公钥），
// 不在仓库里留私钥。
private func ecKeyPair(): (String, String) {
    let pri = ECDSAPrivateKey(Curve.P256)
    (pri.encodeToPem().encode(), ECDSAPublicKey(pri).encodeToPem().encode())
}

@Test
public class JWTTest {
    
    /**
     * 测试基本的HMAC SHA1签名和验证功能
     * 验证JWT的基本工作流程：创建、签名、验证
     */
    @TestCase
    public func testBasicHmacSHA1(): Unit {
        let key = '1234567890'.toArray()
        let jwt = JWT.encoder().hmacSHA1(key)
        let sign = jwt.keyId('1234567890').expire(Duration.minute).addPayload('name', 'Bob').sign()
        @Expect(JWT.verifier(sign).hmacSHA1(key).verify(), true)
    }

    /**
     * 测试hmacMD5ByHexKey方法
     * 验证使用十六进制密钥的MD5 HMAC签名功能
     */
    @TestCase
    public func testHmacMD5ByHexKey(): Unit {
        let hexKey = "48656c6c6f576f726c64" // "HelloWorld" in hex
        let jwt = JWT.encoder().hmacMD5ByHexKey(hexKey)
        let token = jwt.addPayload("user", "testUser").sign()
        
        // 验证token可以被正确验证
        let verifier = JWT.verifier(token).hmacMD5ByHexKey(hexKey)
        @Expect(verifier.verifySign(), true)
        
        // 验证header中包含正确的算法
        @Expect(verifier.getHeader("alg"), Some("HM5"))
        
        // 验证payload中包含正确的数据
        @Expect(verifier.getPayloadValue<String>("user"), Some("testUser"))
    }

    /**
     * 测试hmacMD5ByHexKey方法的边界情况
     * 验证空密钥被拒绝、单字符与长密钥可用
     */
    @TestCase
    public func testHmacMD5ByHexKeyEdgeCases(): Unit {
        // 空十六进制密钥：必须抛 JWTException，而不是让 stdx 的 CryptoException 漏出
        let emptyKey = @ExpectThrows[JWTException](JWT.encoder().hmacMD5ByHexKey(""))
        @Expect(emptyKey.isSome(), true)
        if (let Some(e) <- emptyKey) {
            @Expect(e.message.contains("HMAC key must not be empty"), true)
        }
        
        // 测试单个字符的十六进制
        let jwt2 = JWT.encoder().hmacMD5ByHexKey("41") // "A" in hex
        let token2 = jwt2.addPayload("test", "value").sign()
        @Expect(JWT.verifier(token2).hmacMD5ByHexKey("41").verifySign(), true)
        
        // 测试长十六进制密钥
        let longHexKey = "0123456789abcdef" * 8 // 128个字符
        let jwt3 = JWT.encoder().hmacMD5ByHexKey(longHexKey)
        let token3 = jwt3.addPayload("test", "value").sign()
        @Expect(JWT.verifier(token3).hmacMD5ByHexKey(longHexKey).verifySign(), true)
    }

    /**
     * 测试hmacMD5ByBase64Key方法
     * 验证使用Base64编码密钥的MD5 HMAC签名功能
     */
    @TestCase
    public func testHmacMD5ByBase64Key(): Unit {
        let base64Key = toBase64String("HelloWorld".toArray())
        let jwt = JWT.encoder().hmacMD5ByBase64Key(base64Key)
        let token = jwt.addPayload("user", "testUser").sign()
        
        // 验证token可以被正确验证
        let verifier = JWT.verifier(token).hmacMD5ByBase64Key(base64Key)
        @Expect(verifier.verifySign(), true)
        
        // 验证header中包含正确的算法
        @Expect(verifier.getHeader("alg"), Some("HM5"))
    }

    /**
     * 测试所有HMAC算法的一致性
     * 验证不同HMAC算法都能正确工作
     */
    @TestCase
    public func testAllHmacAlgorithms(): Unit {
        let key = "testKey123".toArray()
        let payload = HashMap<String, String>()
        payload["user"] = "testUser"
        payload["role"] = "admin"
        
        // 测试HMAC MD5
        let jwtMD5 = JWT.encoder().hmacMD5(key)
        jwtMD5.addPayload(payload)
        let tokenMD5 = jwtMD5.sign()
        @Expect(JWT.verifier(tokenMD5).hmacMD5(key).verifySign(), true)
        @Expect(JWT.verifier(tokenMD5).getHeader("alg"), Some("HM5"))
        
        // 测试HMAC SHA1
        let jwtSHA1 = JWT.encoder().hmacSHA1(key)
        jwtSHA1.addPayload(payload)
        let tokenSHA1 = jwtSHA1.sign()
        @Expect(JWT.verifier(tokenSHA1).hmacSHA1(key).verifySign(), true)
        @Expect(JWT.verifier(tokenSHA1).getHeader("alg"), Some("HS1"))
        
        // 测试HMAC SHA224
        let jwtSHA224 = JWT.encoder().hmacSHA224(key)
        jwtSHA224.addPayload(payload)
        let tokenSHA224 = jwtSHA224.sign()
        @Expect(JWT.verifier(tokenSHA224).hmacSHA224(key).verifySign(), true)
        @Expect(JWT.verifier(tokenSHA224).getHeader("alg"), Some("HS224"))
        
        // 测试HMAC SHA256
        let jwtSHA256 = JWT.encoder().hmacSHA256(key)
        jwtSHA256.addPayload(payload)
        let tokenSHA256 = jwtSHA256.sign()
        @Expect(JWT.verifier(tokenSHA256).hmacSHA256(key).verifySign(), true)
        @Expect(JWT.verifier(tokenSHA256).getHeader("alg"), Some("HS256"))
        
        // 测试HMAC SHA384
        let jwtSHA384 = JWT.encoder().hmacSHA384(key)
        jwtSHA384.addPayload(payload)
        let tokenSHA384 = jwtSHA384.sign()
        @Expect(JWT.verifier(tokenSHA384).hmacSHA384(key).verifySign(), true)
        @Expect(JWT.verifier(tokenSHA384).getHeader("alg"), Some("HS384"))
        
        // 测试HMAC SHA512
        let jwtSHA512 = JWT.encoder().hmacSHA512(key)
        jwtSHA512.addPayload(payload)
        let tokenSHA512 = jwtSHA512.sign()
        @Expect(JWT.verifier(tokenSHA512).hmacSHA512(key).verifySign(), true)
        @Expect(JWT.verifier(tokenSHA512).getHeader("alg"), Some("HS512"))
    }

    /**
     * 测试JWT头部设置功能
     * 验证自定义头部字段的设置和获取
     */
    @TestCase
    public func testHeaderFunctionality(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        jwt.header("typ", "JWT")
        jwt.header("custom", "value")
        jwt.keyId("key123")
        
        let token = jwt.addPayload("test", "data").sign()
        let verifier = JWT.verifier(token)
        
        @Expect(verifier.getHeader("typ"), Some("JWT"))
        @Expect(verifier.getHeader("custom"), Some("value"))
        @Expect(verifier.getHeader("kid"), Some("key123"))
        @Expect(verifier.getHeader("alg"), Some("HS256"))
        @Expect(verifier.getHeader("nonexistent"), None<String>)
    }

    /**
     * 测试JWT载荷设置功能
     * 验证各种类型的载荷数据设置和获取
     */
    @TestCase
    public func testPayloadFunctionality(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        
        // 测试标准声明
        jwt.issuer("testIssuer")
        jwt.subject("testSubject")
        jwt.audience("testAudience")
        jwt.issuedAt(DateTime.now())
        jwt.expireAt(DateTime.now() + Duration.hour)
        jwt.notBeforeAt(DateTime.now())
        
        // 测试自定义载荷
        jwt.addPayload("stringValue", "test")
        jwt.addPayload("intValue", 123)
        jwt.addPayload("boolValue", true)
        
        let token = jwt.sign()
        let verifier = JWT.verifier(token)
        
        @Expect(verifier.getPayloadValue<String>("iss"), Some("testIssuer"))
        @Expect(verifier.getPayloadValue<String>("sub"), Some("testSubject"))
        @Expect(verifier.getPayloadValue<String>("aud"), Some("testAudience"))
        @Expect(verifier.getPayloadValue<String>("stringValue"), Some("test"))
        @Expect(verifier.getPayloadValue<Int64>("intValue"), Some(123))
        @Expect(verifier.getPayloadValue<Bool>("boolValue"), Some(true))
        @Expect(verifier.getPayloadValue<String>("nonexistent"), None<String>)
    }

    /**
     * 测试JWT时间相关功能
     * 验证过期时间、生效时间等时间相关功能
     */
    @TestCase
    public func testTimeFunctionality(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        let now = DateTime.now()
        let futureTime = now + Duration.hour
        let pastTime = now - Duration.hour
        
        // 测试过期时间设置
        jwt.expireAt(futureTime)
        jwt.notBeforeAt(pastTime)
        jwt.issuedAt(now)
        
        let token = jwt.addPayload("test", "data").sign()
        let verifier = JWT.verifier(token)
        
        // 验证时间相关方法
        @Expect(verifier.isExpired(time: now), false) // 未过期
        @Expect(verifier.isNotBefore(time: now), true) // 已生效
        
        // 测试过期时间获取
        let expireAt = verifier.getExpireAt()
        @Expect(expireAt.isSome(), true)
        
        // 测试生效时间获取
        let notBefore = verifier.getNotBefore()
        @Expect(notBefore.isSome(), true)
    }

    /**
     * 测试JWT验证功能
     * 验证各种验证场景，包括签名验证、载荷验证等
     */
    @TestCase
    public func testVerificationFunctionality(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        jwt.issuer("testIssuer")
        jwt.subject("testSubject")
        jwt.audience("testAudience")
        jwt.expireAt(DateTime.now() + Duration.hour)
        
        let token = jwt.sign()
        let verifier = JWT.verifier(token).hmacSHA256("secret".toArray())
        
        // 测试整体验证
        @Expect(verifier.verify(), true)
        
        // 测试签名验证
        @Expect(verifier.verifySign(), true)
        
        // 测试载荷验证
        @Expect(verifier.verifyIssuer("testIssuer"), true)
        @Expect(verifier.verifyIssuer("wrongIssuer"), false)
        @Expect(verifier.verifySubject("testSubject"), true)
        @Expect(verifier.verifySubject("wrongSubject"), false)
        @Expect(verifier.verifyAudience("testAudience"), true)
        @Expect(verifier.verifyAudience("wrongAudience"), false)
        
        // 测试自定义载荷验证
        @Expect(verifier.verifyPayload("iss", "testIssuer"), true)
        @Expect(verifier.verifyPayload("iss", "wrongIssuer"), false)
    }

    /**
     * 测试错误情况处理
     * 验证各种错误情况的处理，如无效token、错误密钥等
     */
    @TestCase
    public func testErrorHandling(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        let token = jwt.addPayload("test", "data").sign()
        
        // 测试错误密钥验证：算法一致但密钥不同，返回 false 而不是抛异常
        @Expect(JWT.verifier(token).hmacSHA256("wrongSecret".toArray()).verifySign(), false)
        
        // 测试过期token
        let expiredJwt = JWT.encoder().hmacSHA256("secret".toArray())
        expiredJwt.expireAt(DateTime.now() - Duration.hour) // 已过期
        let expiredToken = expiredJwt.addPayload("test", "data").sign()
        let expiredVerifier = JWT.verifier(expiredToken)
        @Expect(expiredVerifier.isExpired(), true)
        
        // 测试未生效token
        let notYetValidJwt = JWT.encoder().hmacSHA256("secret".toArray())
        notYetValidJwt.notBeforeAt(DateTime.now() + Duration.hour) // 未来时间
        let notYetValidToken = notYetValidJwt.addPayload("test", "data").sign()
        let notYetValidVerifier = JWT.verifier(notYetValidToken)
        @Expect(notYetValidVerifier.isNotBefore(), false)
    }

    /**
     * 测试链式调用功能
     * 验证JWT构建器模式的链式调用
     */
    @TestCase
    public func testChainedCalls(): Unit {
        let jwt = JWT.encoder()
            .hmacSHA256("secret".toArray())
            .header("typ", "JWT")
            .keyId("key123")
            .issuer("testIssuer")
            .subject("testSubject")
            .audience("testAudience")
            .expire(Duration.hour)
            .addPayload("custom", "value")
        
        let token = jwt.sign()
        let verifier = JWT.verifier(token).hmacSHA256("secret".toArray())
        
        @Expect(verifier.verifySign(), true)
        @Expect(verifier.getHeader("typ"), Some("JWT"))
        @Expect(verifier.getHeader("kid"), Some("key123"))
        @Expect(verifier.getPayloadValue<String>("iss"), Some("testIssuer"))
        @Expect(verifier.getPayloadValue<String>("sub"), Some("testSubject"))
        @Expect(verifier.getPayloadValue<String>("aud"), Some("testAudience"))
        @Expect(verifier.getPayloadValue<String>("custom"), Some("value"))
    }

    /**
     * 测试不同密钥格式的兼容性
     * 验证十六进制和Base64密钥格式的正确处理
     */
    @TestCase
    public func testKeyFormatCompatibility(): Unit {
        let originalKey = "HelloWorld123"
        let hexKey = toHexString(originalKey.toArray())
        let base64Key = toBase64String(originalKey.toArray())
        
        // 使用原始字节数组
        let jwt1 = JWT.encoder().hmacSHA256(originalKey.toArray())
        let token1 = jwt1.addPayload("test", "value").sign()
        
        // 使用十六进制密钥
        let jwt2 = JWT.encoder().hmacSHA256ByHexKey(hexKey)
        let token2 = jwt2.addPayload("test", "value").sign()
        
        // 使用Base64密钥
        let jwt3 = JWT.encoder().hmacSHA256ByBase64Key(base64Key)
        let token3 = jwt3.addPayload("test", "value").sign()
        
        // 所有三种方式应该产生相同的结果
        @Expect(JWT.verifier(token1).hmacSHA256(originalKey.toArray()).verifySign(), true)
        @Expect(JWT.verifier(token2).hmacSHA256ByHexKey(hexKey).verifySign(), true)
        @Expect(JWT.verifier(token3).hmacSHA256ByBase64Key(base64Key).verifySign(), true)
        
        // 交叉验证应该成功：三种密钥形式等价，可以互相验签
        @Expect(JWT.verifier(token2).hmacSHA256(originalKey.toArray()).verifySign(), true)
        @Expect(JWT.verifier(token3).hmacSHA256ByHexKey(hexKey).verifySign(), true)
        @Expect(JWT.verifier(token1).hmacSHA256ByBase64Key(base64Key).verifySign(), true)
    }

    /**
     * 测试大量数据处理
     * 验证JWT在处理大量载荷数据时的性能和正确性
     */
    @TestCase
    public func testLargePayload(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        
        // 添加大量载荷数据
        for (i in 0..100) {
            jwt.addPayload("key${i}", "value${i}")
        }
        
        let token = jwt.sign()
        let verifier = JWT.verifier(token).hmacSHA256("secret".toArray())
        
        @Expect(verifier.verifySign(), true)
        
        // 验证所有数据都正确存储
        for (i in 0..100) {
            @Expect(verifier.getPayloadValue<String>("key${i}"), Some("value${i}"))
        }
    }

    /**
     * 测试空值和边界值处理
     * 验证各种边界情况的处理
     */
    @TestCase
    public func testBoundaryValues(): Unit {
        let jwt = JWT.encoder().hmacSHA256("secret".toArray())
        
        // 测试空字符串
        jwt.addPayload("empty", "")
        jwt.addPayload("space", " ")
        jwt.addPayload("newline", "\n")
        jwt.addPayload("tab", "\t")
        
        // 测试特殊字符
        jwt.addPayload("special", "!@#$%^&*()_+-=[]{}|;':\",./<>?")
        jwt.addPayload("unicode", "你好世界🌍")
        
        let token = jwt.sign()
        let verifier = JWT.verifier(token).hmacSHA256("secret".toArray())
        
        @Expect(verifier.verifySign(), true)
        @Expect(verifier.getPayloadValue<String>("empty"), Some(""))
        @Expect(verifier.getPayloadValue<String>("space"), Some(" "))
        @Expect(verifier.getPayloadValue<String>("newline"), Some("\n"))
        @Expect(verifier.getPayloadValue<String>("tab"), Some("\t"))
        @Expect(verifier.getPayloadValue<String>("special"), Some("!@#$%^&*()_+-=[]{}|;':\",./<>?"))
        @Expect(verifier.getPayloadValue<String>("unicode"), Some("你好世界🌍"))
    }

    /**
     * 测试验签配置契约：未配算法必须抛异常、算法不一致必须抛异常、配对了才返回 true
     * 对应 spec：验签必须显式配置算法与密钥 / token 算法与配置算法必须一致
     */
    @TestCase
    public func testHmacAlgMismatchThrows(): Unit {
        let key = "secret".toArray()
        let token = JWT.encoder().hmacSHA1(key).addPayload("user", "bob").sign()

        // (a) 未配置算法：沿用既有语义，立刻失败并说明原因
        let unconfigured = @ExpectThrows[JWTException](JWT.verifier(token).verifySign())
        @Expect(unconfigured.isSome(), true)
        if (let Some(e) <- unconfigured) {
            @Expect(e.message.contains("sign algo was not be specified"), true)
        }

        // (b) token 算法 HS1，配置 HS256：必须抛异常并给出两侧算法名
        let mismatch = @ExpectThrows[JWTException](JWT.verifier(token).hmacSHA256(key).verifySign())
        @Expect(mismatch.isSome(), true)
        if (let Some(e) <- mismatch) {
            @Expect(e.message.contains("HS1"), true)
            @Expect(e.message.contains("HS256"), true)
        }

        // (c) 配置正确算法：返回 true
        @Expect(JWT.verifier(token).hmacSHA1(key).verifySign(), true)
    }

    /**
     * 测试在 verifier 上配置算法不会覆盖 token 解析出来的 alg 头
     * 对应 spec：验签器保留 token 解析出的头
     */
    @TestCase
    public func testVerifierKeepsTokenAlgHeader(): Unit {
        let key = "secret".toArray()
        let token = JWT.encoder().hmacSHA1(key).addPayload("user", "bob").sign()
        let verifier = JWT.verifier(token)
        verifier.hmacSHA256(key)
        @Expect(verifier.getHeader("alg"), Some("HS1"))
    }

    /**
     * 测试非对称算法契约：正例可验签、算法不一致必须抛异常、配置算法不覆盖 token 头
     * 对应 spec：token 算法与配置算法必须一致（对 ECDSA / RSA 同样生效）
     */
    @TestCase
    public func testAsymmetricAlgorithms(): Unit {
        // RSA：RS256 正例
        let rsaToken = JWT.encoder().rsa256(privateKeyPem: RSA_PRIVATE_PEM).addPayload("user", "bob").sign()
        @Expect(JWT.verifier(rsaToken).getHeader("alg"), Some("RS256"))
        @Expect(JWT.verifier(rsaToken).rsa256(publicKeyPem: RSA_PUBLIC_PEM).verifySign(), true)

        // RSA：RS256 token 用 RS384 配置验签必须抛异常
        let rsaMismatch = @ExpectThrows[JWTException](
            JWT.verifier(rsaToken).rsa384(publicKeyPem: RSA_PUBLIC_PEM).verifySign()
        )
        @Expect(rsaMismatch.isSome(), true)
        if (let Some(e) <- rsaMismatch) {
            @Expect(e.message.contains("RS256"), true)
            @Expect(e.message.contains("RS384"), true)
        }
        let rsaVerifier = JWT.verifier(rsaToken)
        rsaVerifier.rsa384(publicKeyPem: RSA_PUBLIC_PEM)
        @Expect(rsaVerifier.getHeader("alg"), Some("RS256"))

        // ECDSA：ES256 正例
        let (ecPriPem, ecPubPem) = ecKeyPair()
        let ecToken = JWT.encoder().ecdsa256(privateKeyPem: ecPriPem).addPayload("user", "bob").sign()
        @Expect(JWT.verifier(ecToken).getHeader("alg"), Some("ES256"))
        @Expect(JWT.verifier(ecToken).ecdsa256(publicKeyPem: ecPubPem).verifySign(), true)

        // ECDSA：ES256 token 用 ES384 配置验签必须抛异常
        let ecMismatch = @ExpectThrows[JWTException](
            JWT.verifier(ecToken).ecdsa384(publicKeyPem: ecPubPem).verifySign()
        )
        @Expect(ecMismatch.isSome(), true)
        if (let Some(e) <- ecMismatch) {
            @Expect(e.message.contains("ES256"), true)
            @Expect(e.message.contains("ES384"), true)
        }
        let ecVerifier = JWT.verifier(ecToken)
        ecVerifier.ecdsa384(publicKeyPem: ecPubPem)
        @Expect(ecVerifier.getHeader("alg"), Some("ES256"))
    }

    /**
     * 测试 13 个算法入口都登记了算法名，且配置算法不会覆盖 token 解析出来的 alg 头
     * 对应 spec：每个签名入口都登记算法名 / 验签器保留 token 解析出的头
     */
    @TestCase
    public func testAlgNameRegisteredForAllEntryPoints(): Unit {
        let key = "testKey123".toArray()
        let hmacCases = [
            ("HM5", JWT.encoder().hmacMD5(key).addPayload("k", "v").sign()),
            ("HS1", JWT.encoder().hmacSHA1(key).addPayload("k", "v").sign()),
            ("HS224", JWT.encoder().hmacSHA224(key).addPayload("k", "v").sign()),
            ("HS256", JWT.encoder().hmacSHA256(key).addPayload("k", "v").sign()),
            ("HS384", JWT.encoder().hmacSHA384(key).addPayload("k", "v").sign()),
            ("HS512", JWT.encoder().hmacSHA512(key).addPayload("k", "v").sign())
        ]
        for ((name, token) in hmacCases) {
            @Expect(JWT.verifier(token).getHeader("alg"), Some(name))
            let verifier = JWT.verifier(token)
            verifier.hmacSHA512(key)
            @Expect(verifier.getHeader("alg"), Some(name))
        }

        let (ecPriPem, ecPubPem) = ecKeyPair()
        let ecCases = [
            ("ES224", JWT.encoder().ecdsa224(privateKeyPem: ecPriPem).addPayload("k", "v").sign()),
            ("ES256", JWT.encoder().ecdsa256(privateKeyPem: ecPriPem).addPayload("k", "v").sign()),
            ("ES384", JWT.encoder().ecdsa384(privateKeyPem: ecPriPem).addPayload("k", "v").sign()),
            ("ES512", JWT.encoder().ecdsa512(privateKeyPem: ecPriPem).addPayload("k", "v").sign())
        ]
        for ((name, token) in ecCases) {
            @Expect(JWT.verifier(token).getHeader("alg"), Some(name))
            let verifier = JWT.verifier(token)
            verifier.ecdsa512(publicKeyPem: ecPubPem)
            @Expect(verifier.getHeader("alg"), Some(name))
        }

        let rsaCases = [
            ("RS256", JWT.encoder().rsa256(privateKeyPem: RSA_PRIVATE_PEM).addPayload("k", "v").sign()),
            ("RS384", JWT.encoder().rsa384(privateKeyPem: RSA_PRIVATE_PEM).addPayload("k", "v").sign()),
            ("RS512", JWT.encoder().rsa512(privateKeyPem: RSA_PRIVATE_PEM).addPayload("k", "v").sign())
        ]
        for ((name, token) in rsaCases) {
            @Expect(JWT.verifier(token).getHeader("alg"), Some(name))
            let verifier = JWT.verifier(token)
            verifier.rsa512(publicKeyPem: RSA_PUBLIC_PEM)
            @Expect(verifier.getHeader("alg"), Some(name))
        }
    }

    /**
     * 测试 HS256 真正使用 SHA256 摘要，而不是复用 SHA1
     * 对应 spec：HMAC 算法名与摘要一致
     */
    @TestCase
    public func testHmacDigestMapping(): Unit {
        let key = "secret-key".toArray()
        let token = JWT.encoder().hmacSHA256(key).addPayload("user", "bob").sign()
        let firstDot = token.indexOf(".") ?? -1
        let lastDot = token.lastIndexOf(".", firstDot + 1) ?? -1
        let header = fromBase64(token[0..firstDot])
        let payload = fromBase64(token[firstDot + 1..lastDot])
        let actual = fromBase64(token[lastDot + 1..])
        let data = bytesForSign(header, payload)

        @Expect(actual, stdDigest(HMACDigest(key, HashType.SHA256), data))
        @Expect(actual == stdDigest(HMACDigest(key, HashType.SHA1), data), false)
    }

    /**
     * 测试空 HMAC 密钥被拒绝：抛模块自己的 JWTException，而不是 stdx 的 CryptoException
     * 对应 spec：拒绝空 HMAC 密钥
     */
    @TestCase
    public func testEmptyHmacKeyRejected(): Unit {
        let emptyBytes = @ExpectThrows[JWTException](JWT.encoder().hmacMD5(Array<Byte>()))
        @Expect(emptyBytes.isSome(), true)
        if (let Some(e) <- emptyBytes) {
            @Expect(e.message.contains("HMAC key must not be empty"), true)
        }

        let emptyHex = @ExpectThrows[JWTException](JWT.encoder().hmacMD5ByHexKey(""))
        @Expect(emptyHex.isSome(), true)
        if (let Some(e) <- emptyHex) {
            @Expect(e.message.contains("HMAC key must not be empty"), true)
        }

        let emptyBase64 = @ExpectThrows[JWTException](JWT.encoder().hmacSHA256ByBase64Key(""))
        @Expect(emptyBase64.isSome(), true)
        if (let Some(e) <- emptyBase64) {
            @Expect(e.message.contains("HMAC key must not be empty"), true)
        }
    }

}
