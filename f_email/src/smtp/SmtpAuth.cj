/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_email.smtp

import stdx.crypto.digest.{HMAC, HashType}
import stdx.encoding.hex.toHexString
import fountain::f_email.model.{Base64Codec, Secret}

/** SMTP AUTH 机制。 */
public enum SmtpAuthMechanism <: ToString {
    | Plain
    | Login
    | CramMd5
    | XOAuth2

    public func toString(): String {
        match (this) {
            case Plain => "PLAIN"
            case Login => "LOGIN"
            case CramMd5 => "CRAM-MD5"
            case XOAuth2 => "XOAUTH2"
        }
    }
}

/**
 * 各机制的编码。
 *
 * 这些函数只产出"要写出的字节"，不碰 socket；调用方负责在 TLS 之后调用它们。
 * `Secret` 只在函数内部展开，任何返回值都不含明文密码。
 */
public class SmtpAuth {
    private static let NUL = String([Rune(0)])
    private static let SOH = String([Rune(1)])

    /** `AUTH PLAIN` 的初始响应：`base64("\0user\0pass")`。 */
    public static func plainToken(user: String, secret: Secret): String {
        secret.use { password =>
            Base64Codec.encodeUnwrapped((NUL + user + NUL + password).toArray())
        }
    }

    /** `AUTH LOGIN` 的用户名与密码两段 base64。 */
    public static func loginUser(user: String): String {
        Base64Codec.encodeUnwrapped(user.toArray())
    }

    public static func loginPassword(secret: Secret): String {
        secret.use { password =>
            Base64Codec.encodeUnwrapped(password.toArray())
        }
    }

    /**
     * CRAM-MD5：`base64(user + " " + hex(HMAC-MD5(pass, challenge)))`。
     *
     * challenge 是服务器 `334` 之后那段 base64 解码后的原文。
     */
    public static func cramMd5Response(user: String, secret: Secret, challenge: String): String {
        secret.use { password =>
            let hmac = HMAC(password.toArray(), HashType.MD5)
            hmac.write(challenge.toArray())
            let digest = toHexString(hmac.finish())
            Base64Codec.encodeUnwrapped("${user} ${digest}".toArray())
        }
    }

    /** `AUTH XOAUTH2` 的初始响应。 */
    public static func xoauth2Token(user: String, token: Secret): String {
        token.use { accessToken =>
            let payload = "user=${user}" + SOH + "auth=Bearer " + accessToken + SOH + SOH
            Base64Codec.encodeUnwrapped(payload.toArray())
        }
    }
}
