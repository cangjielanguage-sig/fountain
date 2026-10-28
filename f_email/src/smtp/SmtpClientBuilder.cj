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

import std.env.getVariable
import stdx.net.tls.TlsClientConfig
import fountain::f_email.model.*
import fountain::f_email.transport.*

/**
 * `SmtpClient` 的构造器。
 *
 * 配置校验全部在 [build] 阶段完成：`requireEncryption` 与 `allowPlaintextAuth` 的默认值
 * 让"明文发密码"必须显式开启，而不是靠调用方记得关掉某个开关。
 */
public class SmtpClientBuilder {
    private let host: String
    private let port: UInt16
    private var tlsMode: TlsMode = TlsMode.None
    private var tlsConfigValue: ?TlsClientConfig = None
    private var mechanism: ?SmtpAuthMechanism = None
    private var userValue: ?String = None
    private var secretValue: ?Secret = None
    private var helloValue: ?String = None
    private var timeoutsValue: MailTimeouts = MailTimeouts()
    private var requireEncryptionValue = true
    private var allowPlaintextAuthValue = false
    private var policyValue: SendPolicy = SendPolicy.BestEffort
    private var maxMessageBytesValue: Int64 = 0
    private var precomputeValue = false
    private var dsnReturnValue: ?DsnReturn = None
    private var dsnNotifyValue: Array<DsnNotify> = []
    private var factory: ?TransportFactory = None

    init(host: String, port: UInt16) {
        this.host = host
        this.port = port
    }

    public func tls(mode: TlsMode): This {
        tlsMode = mode
        this
    }

    public func tlsConfig(config: TlsClientConfig): This {
        tlsConfigValue = Some(config)
        this
    }

    public func auth(mechanism: SmtpAuthMechanism, user: String, secret: Secret): This {
        this.mechanism = Some(mechanism)
        userValue = Some(user)
        secretValue = Some(secret)
        this
    }

    public func oauth2(user: String, token: Secret): This {
        mechanism = Some(SmtpAuthMechanism.XOAuth2)
        userValue = Some(user)
        secretValue = Some(token)
        this
    }

    public func helloName(name: String): This {
        helloValue = Some(name)
        this
    }

    public func timeouts(timeouts: MailTimeouts): This {
        timeoutsValue = timeouts
        this
    }

    public func requireEncryption(required: Bool): This {
        requireEncryptionValue = required
        this
    }

    public func allowPlaintextAuth(allow: Bool): This {
        allowPlaintextAuthValue = allow
        this
    }

    public func sendPolicy(policy: SendPolicy): This {
        policyValue = policy
        this
    }

    public func maxMessageBytes(limit: Int64): This {
        maxMessageBytesValue = limit
        this
    }

    public func precomputeSize(enabled: Bool): This {
        precomputeValue = enabled
        this
    }

    public func dsn(ret: DsnReturn, notify: Array<DsnNotify>): This {
        dsnReturnValue = Some(ret)
        dsnNotifyValue = notify
        this
    }

    /** 注入传输实现（测试与未来代理）。 */
    public func transport(factory: TransportFactory): This {
        this.factory = Some(factory)
        this
    }

    public func build(): SmtpClient {
        if (requireEncryptionValue && tlsMode.toString() == "None") {
            throw IllegalArgumentException("requireEncryption=true 时必须配置 TLS")
        }
        if (mechanism.isSome() && tlsMode.toString() == "None" && !allowPlaintextAuthValue) {
            throw IllegalArgumentException("明文连接上发送凭据必须显式 allowPlaintextAuth(true)")
        }
        let timeouts = timeoutsValue
        let transport = match (factory) {
            case Some(value) => value
            case None => SocketTransportFactory(timeouts: timeouts, tlsConfig: tlsConfigValue)
        }
        let connection = transport.connect(host, port, tlsMode)
        var channel = connection.channel()
        try {
            channel.withDeadline(timeouts.greeting)
            let greeting = SmtpReply.read(channel)
            if (!greeting.isSuccess()) {
                throw MailProtocolException("SMTP 问候失败：${greeting.code}")
            }
            let hello = resolveHelloName()
            channel.withDeadline(timeouts.command)
            var capabilities = ehlo(channel, hello)
            if (tlsMode.toString() == "StartTls") {
                if (!capabilities.supportsStartTls) {
                    throw MailProtocolException("服务器未广告 STARTTLS，拒绝明文继续")
                }
                channel.writeLine("STARTTLS")
                let reply = SmtpReply.read(channel)
                if (reply.code != 220) {
                    throw MailProtocolException("STARTTLS 被拒绝：${reply.code}")
                }
                connection.startTls(config: tlsConfigValue)
                channel = connection.channel()
                channel.withDeadline(timeouts.greeting)
                capabilities = ehlo(channel, hello)
            }
            if (mechanism.isSome() && !capabilities.authMechanisms.isEmpty()) {
                authenticate(channel, capabilities, timeouts)
            }
            SmtpClient(
                connection,
                channel,
                timeouts,
                hello,
                capabilities,
                mechanism,
                userValue,
                secretValue,
                policyValue,
                maxMessageBytesValue,
                precomputeValue,
                dsnReturnValue,
                dsnNotifyValue
            )
        } catch (e: Exception) {
            connection.close()
            throw e
        }
    }

    // ---------- 内部 ----------

    private func resolveHelloName(): String {
        if (let Some(name) <- helloValue) {
            if (name.trimAscii().size > 0) {
                return name.trimAscii()
            }
        }
        if (let Some(name) <- getVariable("HOSTNAME")) {
            if (name.trimAscii().size > 0) {
                return name.trimAscii()
            }
        }
        "localhost"
    }

    private func ehlo(channel: LineChannel, hello: String): SmtpCapabilities {
        channel.writeLine("EHLO ${hello}")
        var reply = SmtpReply.read(channel)
        if (reply.code == 500 || reply.code == 502 || reply.code == 504) {
            channel.writeLine("HELO ${hello}")
            reply = SmtpReply.read(channel)
            if (!reply.isSuccess()) {
                throw MailProtocolException("HELO 失败：${reply.code}")
            }
            let empty = SmtpCapabilities()
            if (tlsMode.toString() != "None" || mechanism.isSome()) {
                throw MailProtocolException("服务器不支持 EHLO，无法协商 TLS/AUTH")
            }
            return empty
        }
        if (!reply.isSuccess()) {
            throw MailProtocolException("EHLO 失败：${reply.code}")
        }
        SmtpCapabilities.fromEhlo(reply.lines)
    }

    private func authenticate(channel: LineChannel, capabilities: SmtpCapabilities, timeouts: MailTimeouts): Unit {
        let used = mechanism ?? selectMechanism(capabilities)
        let user = userValue.getOrThrow()
        let secret = secretValue.getOrThrow()
        if (!allowPlaintextAuthValue && tlsMode.toString() == "None") {
            throw MailAuthException(used.toString(), None<Int64>, "明文连接上拒绝发送凭据")
        }
        channel.withDeadline(timeouts.command)
        channel.beginSensitive()
        try {
            match (used) {
                case SmtpAuthMechanism.Plain => authPlain(channel, user, secret)
                case SmtpAuthMechanism.Login => authLogin(channel, user, secret)
                case SmtpAuthMechanism.CramMd5 => authCramMd5(channel, user, secret)
                case SmtpAuthMechanism.XOAuth2 => authXOAuth2(channel, user, secret)
            }
        } finally {
            channel.endSensitive()
        }
    }

    private func selectMechanism(capabilities: SmtpCapabilities): SmtpAuthMechanism {
        let advertised = capabilities.authMechanisms
        for (name in ["XOAUTH2", "CRAM-MD5", "PLAIN", "LOGIN"]) {
            if (advertised.contains(name)) {
                match (name) {
                    case "XOAUTH2" => return SmtpAuthMechanism.XOAuth2
                    case "CRAM-MD5" => return SmtpAuthMechanism.CramMd5
                    case "PLAIN" => return SmtpAuthMechanism.Plain
                    case _ => return SmtpAuthMechanism.Login
                }
            }
        }
        throw MailAuthException("AUTO", None<Int64>, "服务器未广告任何可用的 AUTH 机制")
    }

    private func authPlain(channel: LineChannel, user: String, secret: Secret): Unit {
        channel.writeLine("AUTH PLAIN ${SmtpAuth.plainToken(user, secret)}")
        let reply = SmtpReply.read(channel)
        if (reply.code == 334) {
            channel.writeLine(SmtpAuth.plainToken(user, secret))
            let final = SmtpReply.read(channel)
            expectAuthOk(final, "PLAIN")
        } else {
            expectAuthOk(reply, "PLAIN")
        }
    }

    private func authLogin(channel: LineChannel, user: String, secret: Secret): Unit {
        channel.writeLine("AUTH LOGIN")
        var reply = SmtpReply.read(channel)
        if (reply.code != 334) {
            expectAuthOk(reply, "LOGIN")
        }
        channel.writeLine(SmtpAuth.loginUser(user))
        reply = SmtpReply.read(channel)
        if (reply.code != 334) {
            expectAuthOk(reply, "LOGIN")
        }
        channel.writeLine(SmtpAuth.loginPassword(secret))
        expectAuthOk(SmtpReply.read(channel), "LOGIN")
    }

    private func authCramMd5(channel: LineChannel, user: String, secret: Secret): Unit {
        channel.writeLine("AUTH CRAM-MD5")
        let challengeReply = SmtpReply.read(channel)
        if (challengeReply.code != 334) {
            expectAuthOk(challengeReply, "CRAM-MD5")
        }
        let challenge = String.fromUtf8(
            Base64Codec.decode(challengeReply.lines[challengeReply.lines.size - 1].trimAscii())
        )
        channel.writeLine(SmtpAuth.cramMd5Response(user, secret, challenge))
        expectAuthOk(SmtpReply.read(channel), "CRAM-MD5")
    }

    private func authXOAuth2(channel: LineChannel, user: String, secret: Secret): Unit {
        channel.writeLine("AUTH XOAUTH2 ${SmtpAuth.xoauth2Token(user, secret)}")
        var reply = SmtpReply.read(channel)
        if (reply.code == 334) {
            // 挑战必须用空行结束，再读最终回复；不能把 334 当成功
            channel.writeLine("")
            reply = SmtpReply.read(channel)
        }
        expectAuthOk(reply, "XOAUTH2")
    }

    private func expectAuthOk(reply: SmtpReply, mechanism: String): Unit {
        if (!reply.isSuccess()) {
            throw MailAuthException(mechanism, Some(reply.code), "认证失败：${reply.code}")
        }
    }
}
