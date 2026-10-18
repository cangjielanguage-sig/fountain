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

import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbd.common.{DbdErrorCode, DEFAULT_PORT}

/** Step 3.1 `DbdUrl`（设计 §5.1）：解析、% 编码往返、缺省端口与四类非法 URL。 */
@Test
public class DbdUrlTest {

    /** 完整 URL：user / password / host / port / database 逐个断言。 */
    @TestCase
    public func parseCompleteUrl(): Unit {
        let url = DbdUrl.parse('fdbm://scott:tiger@127.0.0.1:9000/order_db')
        @Assert(url.user, 'scott')
        @Assert(url.password, 'tiger')
        @Assert(url.host, '127.0.0.1')
        @Assert(url.port, 9000u16)
        @Assert(url.database, 'order_db')
    }

    /** 省略端口 → `DEFAULT_PORT`。
    */
    @TestCase
    public func omittedPortFallsBackToDefault(): Unit {
        @Assert(DbdUrl.parse('fdbm://u:p@localhost/order_db').port, DEFAULT_PORT)
    }

    /** 用户名/密码的 `%40` / `%3A` 解码：`@` 与 `:` 可以出现在凭据里（否则没法写在 `@` 分隔符前）。 */
    @TestCase
    public func percentEncodedCredentialsAreDecoded(): Unit {
        let url = DbdUrl.parse('fdbm://u%40x:p%3Aa@host/order_db')
        @Assert(url.user, 'u@x')
        @Assert(url.password, 'p:a')
    }

    /** 无凭据（无 `@`）：user / password 为空串，`toUrl()` 也不写 `@`。 */
    @TestCase
    public func missingUserInfoYieldsEmptyCredentials(): Unit {
        let url = DbdUrl.parse('fdbm://localhost:9000/order_db')
        @Assert(url.user, '')
        @Assert(url.password, '')
        @Assert(url.toUrl(), 'fdbm://localhost:9000/order_db')
    }

    /** IPv6 字面量：`[::1]:9000`。 */
    @TestCase
    public func ipv6LiteralIsSupported(): Unit {
        let url = DbdUrl.parse('fdbm://u:p@[::1]:9000/order_db')
        @Assert(url.host, '[::1]')
        @Assert(url.port, 9000u16)
    }

    /** database 取路径首段：`/db?x=1` 与结尾多余的 `/` 都不污染它。 */
    @TestCase
    public func databaseIsTheFirstPathSegment(): Unit {
        @Assert(DbdUrl.parse('fdbm://h/order_db?charset=utf8').database, 'order_db')
        @Assert(DbdUrl.parse('fdbm://h/order_db/').database, 'order_db')
    }

    /** 缺 database（无 `/`）→ `CONFIG`。 */
    @TestCase
    public func missingDatabaseIsConfigError(): Unit {
        @Assert(codeOf { DbdUrl.parse('fdbm://u:p@host') }, DbdErrorCode.CONFIG)
    }

    /** 空 database → `CONFIG`。 */
    @TestCase
    public func emptyDatabaseIsConfigError(): Unit {
        @Assert(codeOf { DbdUrl.parse('fdbm://u:p@host/') }, DbdErrorCode.CONFIG)
    }

    /** 缺 host → `CONFIG`。 */
    @TestCase
    public func missingHostIsConfigError(): Unit {
        @Assert(codeOf { DbdUrl.parse('fdbm://u:p@:9000/order_db') }, DbdErrorCode.CONFIG)
    }

    /** scheme 不是 `fdbm` → `CONFIG`（`multidbm://` 由 `MultiDUrl` 另行解析）。 */
    @TestCase
    public func foreignSchemeIsConfigError(): Unit {
        @Assert(codeOf { DbdUrl.parse('multidbm://u:p@host/order_db') }, DbdErrorCode.CONFIG)
        @Assert(codeOf { DbdUrl.parse('host/order_db') }, DbdErrorCode.CONFIG)
    }

    /** 端口不是数字 / 越界 → `CONFIG`。 */
    @TestCase
    public func illegalPortIsConfigError(): Unit {
        @Assert(codeOf { DbdUrl.parse('fdbm://h:abc/order_db') }, DbdErrorCode.CONFIG)
        @Assert(codeOf { DbdUrl.parse('fdbm://h:70000/order_db') }, DbdErrorCode.CONFIG)
    }

    /** `tryParse`：非法一律 `None`，合法实例可用。 */
    @TestCase
    public func tryParseReturnsNoneOnIllegalUrl(): Unit {
        @Assert(DbdUrl.tryParse('fdbm://u:p@host/').isNone(), true)
        match (DbdUrl.tryParse('fdbm://u:p@host:9000/order_db')) {
            case Some(u) => @Assert(u.database, 'order_db')
            case None => @Assert(DbdUrl.tryParse('fdbm://u:p@host:9000/order_db').isNone(), false)
        }
    }

    /** `toUrl()`：端口总是显式写出，密码一律 % 编码 ⇒ `%` 编码后的串与原串等价。 */
    @TestCase
    public func toUrlIsTheInverseOfParse(): Unit {
        @Assert(DbdUrl.parse('fdbm://scott:tiger@127.0.0.1:9000/order_db').toUrl(),
            'fdbm://scott:tiger@127.0.0.1:9000/order_db')
        // 省略端口时按默认端口写回（不再是原文，而是"等价"的另一写法）
        @Assert(DbdUrl.parse('fdbm://u:p@localhost/order_db').toUrl(), 'fdbm://u:p@localhost:8112/order_db')
        // 原始凭据里带分隔符时，重建串总能被同一个解析器解回同一份凭据
        let raw = 'fdbm://u%40x:p%3Aa@host/order_db'
        let again = DbdUrl.parse(raw).toUrl()
        @Assert(again, 'fdbm://u%40x:p%3Aa@host:8112/order_db')
        @Assert(DbdUrl.parse(again).user, 'u@x')
        @Assert(DbdUrl.parse(again).password, 'p:a')
    }

    /** `toUrlMasked()`：密码不出现在元数据/日志串里，但 user / host / database 仍可读。 */
    @TestCase
    public func maskedUrlHidesPassword(): Unit {
        let masked = DbdUrl.parse('fdbm://scott:secret%40pwd@127.0.0.1:9000/order_db').toUrlMasked()
        @Assert(masked.contains('secret'), false)
        @Assert(masked, 'fdbm://scott:***@127.0.0.1:9000/order_db')
    }
}
