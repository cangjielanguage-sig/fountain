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
package fountain::f_dbd.driver

import std.collection.ArrayList
import std.convert.*
import fountain::f_base.toHex
import fountain::f_base.UnsafeBytes
import fountain::f_dbd.common.{DbdErrorCode, DEFAULT_PORT}
import fountain::f_dbd.exception.DbdException

/** URL 的 scheme（与驱动名一致）；其它 scheme 一律 `CONFIG`。 */
private const SCHEME: String = 'fdbm'
private const SCHEME_PREFIX: String = 'fdbm://'

/**
 * 单节点连接串解析（设计 §5.1）。
 *
 * 形如 `fdbm://username:password@host:port/database_name`：用户名/密码支持 % 编码（`%40` → `@`、
 * `%3A` → `:`），省略端口时取 `DEFAULT_PORT`（8112）；反向重建见 [toUrl] / [toUrlMasked]。
 */
public class DbdUrl {
    public let user: String
    public let password: String
    public let host: String
    public let port: UInt16
    public let database: String

    init(user: String, password: String, host: String, port: UInt16, database: String) {
        this.user = user
        this.password = password
        this.host = host
        this.port = port
        this.database = database
    }

    /**
     * 解析连接串；非法一律抛 `DbdException(CONFIG)` —— scheme 不是 `fdbm`、缺 host、端口非数字、
     * database 为空都算非法。
     */
    public static func parse(url: String): DbdUrl {
        match (url.indexOf(SCHEME_PREFIX)) {
            case Some(i) =>
                if (i != 0) {
                    throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': scheme must be ${SCHEME}')
                }
            case None => throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': scheme must be ${SCHEME}')
        }
        let rest = url[SCHEME_PREFIX.size..url.size]
        let slash = match (rest.indexOf('/')) {
            case Some(i) => i
            case None => throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': database is missing')
        }
        let database = percentDecode(firstSegmentOf(rest[slash + 1..rest.size]), url)
        if (database.isEmpty()) {
            throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': database is empty')
        }
        let authority = rest[0..slash]
        var user = ''
        var password = ''
        var hostPort = authority
        match (authority.lastIndexOf('@')) {
            case Some(at) =>
                hostPort = authority[at + 1..authority.size]
                // 密码里的字面 `:` 必须写成 `%3A`，故按**第一个** `:` 切 user / password
                match (authority[0..at].indexOf(':')) {
                    case Some(colon) =>
                        user = percentDecode(authority[0..colon], url)
                        password = percentDecode(authority[colon + 1..at], url)
                    case None => user = percentDecode(authority[0..at], url)
                }
            case None => ()
        }
        var host = hostPort
        var port = DEFAULT_PORT
        if (hostPort.startsWith('[')) {
            // IPv6 字面量：`[::1]:8112`
            match (hostPort.indexOf(']')) {
                case Some(bracket) =>
                    host = hostPort[0..bracket + 1]
                    let tail = hostPort[bracket + 1..hostPort.size]
                    if (tail.startsWith(':')) {
                        port = parsePort(tail.removePrefix(':'), url)
                    }
                case None => throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': unbalanced \'[\' in host')
            }
        } else {
            match (hostPort.indexOf(':')) {
                case Some(colon) =>
                    host = hostPort[0..colon]
                    port = parsePort(hostPort[colon + 1..hostPort.size], url)
                case None => ()
            }
        }
        if (host.isEmpty()) {
            throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': host is missing')
        }
        DbdUrl(user, password, host, port, database)
    }

    /** 非法 URL → `None`（不抛）。 */
    public static func tryParse(url: String): ?DbdUrl {
        try {
            parse(url)
        } catch (_: DbdException) {
            None<DbdUrl>
        }
    }

    /** 重建连接串（用户名/密码/database 一律 % 编码；端口总是显式写出）。 */
    public func toUrl(): String {
        let userInfo = if (user.isEmpty() && password.isEmpty()) {
            ''
        } else {
            '${percentEncode(user)}:${percentEncode(password)}@'
        }
        '${SCHEME_PREFIX}${userInfo}${host}:${port}/${percentEncode(database)}'
    }

    /**
     * 用 opts 的凭据覆盖 URL 里的凭据，返回一个新实例（设计 §5.1：URL 中的值可被 opts 覆盖或替代）。
     *
     * 当前协议没有独立的鉴权步骤，凭据只进入 `getMetaData`；先留好这条通路，鉴权上线时不必改调用方。
     */
    func withCredentials(user: String, password: String): DbdUrl {
        DbdUrl(user, password, host, port, database)
    }

    /** 重建连接串，密码整体替换成 `***`：用于 `getMetaData` 与日志，避免明文密码外泄。 */
    public func toUrlMasked(): String {
        let userInfo = if (user.isEmpty() && password.isEmpty()) {
            ''
        } else {
            '${percentEncode(user)}:***@'
        }
        '${SCHEME_PREFIX}${userInfo}${host}:${port}/${percentEncode(database)}'
    }

    private static func parsePort(value: String, url: String): UInt16 {
        let n = match (Int64.tryParse(value)) {
            case Some(x) => x
            case None => throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': port \'${value}\' is not a number')
        }
        if (n < 0 || n > Int64(UInt16.Max)) {
            throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': port ${value} is out of range')
        }
        UInt16(n)
    }
}

/** `database` 取路径首段：`/db?x=1` 与 `/db/` 都得到 `db`。 */
private func firstSegmentOf(value: String): String {
    var end = value.size
    for (sep in ['?', '/']) {
        match (value.indexOf(sep)) {
            case Some(i) =>
                if (i < end) {
                    end = i
                }
            case None => ()
        }
    }
    value[0..end]
}

/** 两位十六进制 → 字节；非十六进制 → `None`。 */
private func hexByte(high: Byte, low: Byte): ?Byte {
    let h = nibbleOf(high)
    let l = nibbleOf(low)
    match ((h, l)) {
        case (Some(hi), Some(lo)) => Some(UInt8((hi << 4) | lo))
        case _ => None<Byte>
    }
}

private func nibbleOf(c: Byte): ?UInt8 {
    if (c >= UInt8(UInt32(r'0')) && c <= UInt8(UInt32(r'9'))) {
        return Some(UInt8(c - UInt8(UInt32(r'0'))))
    }
    if (c >= UInt8(UInt32(r'a')) && c <= UInt8(UInt32(r'f'))) {
        return Some(UInt8(c - UInt8(UInt32(r'a')) + 10u8))
    }
    if (c >= UInt8(UInt32(r'A')) && c <= UInt8(UInt32(r'F'))) {
        return Some(UInt8(c - UInt8(UInt32(r'A')) + 10u8))
    }
    None<UInt8>
}

/**
 * `%XX` 按**字节**解码：每个转义写回一个字节，其它字符按其 UTF-8 字节原样写入，
 * 最后整体按 UTF-8 还原。非法 UTF-8 或残缺 `%` → `DbdException(CONFIG)`（D12）。
 */
private func percentDecode(value: String, url: String): String {
    let bytes = value.unsafeBytes()
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    while (i < bytes.size) {
        let b = bytes[i]
        if (b == UInt8(UInt32(r'%'))) {
            if (i + 2 >= bytes.size) {
                throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': truncated percent escape in \'${value}\'')
            }
            match (hexByte(bytes[i + 1], bytes[i + 2])) {
                case Some(decoded) =>
                    out.add(decoded)
                    i += 3
                case None =>
                    throw DbdException(CONFIG,
                        'illegal fdbm url \'${url}\': bad percent escape in \'${value}\'')
            }
        } else {
            out.add(b)
            i += 1
        }
    }
    try {
        String.fromUtf8(out.toArray())
    } catch (_: Exception) {
        throw DbdException(CONFIG, 'illegal fdbm url \'${url}\': credentials are not valid UTF-8')
    }
}

/**
 * 非 unreserved 字符（RFC 3986）逐 **UTF-8 字节** `%XX` 化：`@` → `%40`、`:` → `%3A`。
 *
 * 按字节而非按 `Rune` 编码，非 ASCII 口令才能在线上还原（`decode` 侧同样是字节级）。
 */
private func percentEncode(value: String): String {
    let out = ArrayList<Byte>()
    for (b in value.toRuneArray()) {
        let bytes = if (UInt32(b) <= 0x7f) {
            [UInt8(UInt32(b))]
        } else {
            String([b]).unsafeBytes()
        }
        for (byte in bytes) {
            if (isUnreserved(byte)) {
                out.add(byte)
            } else {
                // '%' + 两位十六进制（大写）；逐字节写入，避免按 Rune 拼串时重复分配
                out.add(UInt8(UInt32(r'%')))
                let upper = toHex(byte).toAsciiUpper()
                for (c in upper) {
                    out.add(UInt8(UInt32(c)))
                }
            }
        }
    }
    // percent-encode 的产物只有 `%` 与十六进制字符 + 原样 unreserved 字符，必是合法 UTF-8
    unsafe {
        String.withRawData(out.toArray())
    }
}

/** RFC 3986 unreserved：`ALPHA / DIGIT / '-' / '.' / '_' / '~'`。 */
private func isUnreserved(byte: Byte): Bool {
    (byte >= UInt8(UInt32(r'a')) && byte <= UInt8(UInt32(r'z'))) ||
        (byte >= UInt8(UInt32(r'A')) && byte <= UInt8(UInt32(r'Z'))) ||
        (byte >= UInt8(UInt32(r'0')) && byte <= UInt8(UInt32(r'9'))) || byte == UInt8(UInt32(r'-')) ||
        byte == UInt8(UInt32(r'.')) || byte == UInt8(UInt32(r'_')) || byte == UInt8(UInt32(r'~'))
}
