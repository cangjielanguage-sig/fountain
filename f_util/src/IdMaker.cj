/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_util

import std.time.DateTime
import std.sync.AtomicInt64
import f_config.*
import f_util.exception.IdException

public class IdMaker {
    public static const HOST_SERIAL = "host.serial"
    private static let genesis = DateTime.of(
        year: 2023,
        month: 8,
        dayOfMonth: 6,
        hour: 14,
        minute: 30,
        second: 0,
        nanosecond: 0
    )
    private let startMillis: Int64 = (DateTime.now() - DateTime.UnixEpoch).toMilliseconds()
    private let current: AtomicInt64
    public IdMaker(private let hostSerial!: Int64) {
        if (hostSerial > 1023 || hostSerial < 0) {
            throw IdException("host serial is too large, ${hostSerial} must be between 0 and 1023.")
        }
        current = AtomicInt64((hostSerial << (62 - 9)) | (startMillis << (62 - 41 - 9)))
    }
    public init() {
        this(hostSerial: getSerial())
    }
    private static func getSerial(): Int64 {
        Config.getValue<Int64>(HOST_SERIAL).getOrThrow()
    }
    public func nextInt64(): Int64 {
        current.fetchAdd(1)
    }
}
