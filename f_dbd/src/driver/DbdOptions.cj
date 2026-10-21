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

import std.convert.*
import std.database.sql.SqlOption
import fountain::f_log.LoggerFactory

/**
 * 驱动侧的选项表（设计 §5.3）。
 *
 * `DbdDatasource` 持有一份，每次 `connect()` 复制一份给新的连接 / 传输层；连接级可被 `Statement` 的
 * `setOption` 覆盖（覆盖发生在 Statement 自己那份副本上）。
 */
class DbdOptions {
    /** URL 里的凭据可被 `username` / `password` 选项覆盖（`DbdDriver.open` 的 opts）。 */
    var user: String = ''
    var password: String = ''
    /** 建链超时：建 TCP 之后的首个 PING 往返也按它计时（§5.3「建 TCP 连接与首次请求的超时」）。 */
    var connectionTimeout: ?Duration = None
    /** `Statement.query` 及其后续列读的单次请求超时。 */
    var queryTimeout: ?Duration = None
    /** `Statement.update` 的单次请求超时。 */
    var updateTimeout: ?Duration = None
    /** 流列分块大小（InputStream 列，请求里 `bufSize`）；0 表示取 `DEFAULT_STREAM_CHUNK`。 */
    var fetchRows: Int64 = 0

    private static let logger = LoggerFactory.getLogger('fountain::f_dbd.driver.DbdOptions')

    /**
     * 写入一个选项：未识别的 key 只记 DEBUG 并忽略（与 `f_dbpool` 的透传约定兼容，
     * 上层可能把与本驱动无关的 key 传下来）。
     */
    func apply(key: String, value: String): Unit {
        if (key == SqlOption.Username) {
            user = value
        } else if (key == SqlOption.Password) {
            password = value
        } else if (key == SqlOption.FetchRows) {
            match (Int64.tryParse(value)) {
                case Some(n) => fetchRows = n
                case None => logger.warn('illegal ${SqlOption.FetchRows}: ${value}, ignored')
            }
        } else if (key == SqlOption.ConnectionTimeout) {
            match (timeoutOf(key, value)) {
                case Some(parsed) => connectionTimeout = Some(parsed)
                case None => ()   // 保留原值：配置写错不得把已配置的超时清成"无限等待"
            }
        } else if (key == SqlOption.QueryTimeout) {
            match (timeoutOf(key, value)) {
                case Some(parsed) => queryTimeout = Some(parsed)
                case None => ()
            }
        } else if (key == SqlOption.UpdateTimeout) {
            match (timeoutOf(key, value)) {
                case Some(parsed) => updateTimeout = Some(parsed)
                case None => ()
            }
        } else {
            logger.debug{'ignored unknown dbd option ${key}'}
        }
    }

    /**
     * 毫秒数 → `Duration`；非法、`0`、负数都记 WARN 并返回 `None`。
     *
     * `None` 的语义是「本次不修改」，由 `apply` 保留原值——配置写错不该让请求无限等待。
     */
    private static func timeoutOf(key: String, value: String): ?Duration {
        match (Int64.tryParse(value)) {
            case Some(ms) =>
                if (ms <= 0) {
                    logger.warn('illegal ${key}: ${value}, keeping the current value')
                    None<Duration>
                } else {
                    Some(Duration.millisecond * ms)
                }
            case None =>
                logger.warn('illegal ${key}: ${value}, keeping the current value')
                None<Duration>
        }
    }

    /** 取一个拷贝：连接 / Statement 各自持有自己的副本，互不干扰。 */
    func copy(): DbdOptions {
        let cloned = DbdOptions()
        cloned.user = user
        cloned.password = password
        cloned.connectionTimeout = connectionTimeout
        cloned.queryTimeout = queryTimeout
        cloned.updateTimeout = updateTimeout
        cloned.fetchRows = fetchRows
        cloned
    }
}
