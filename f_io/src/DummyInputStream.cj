/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_io

public class DummyInputStream <: InputStream & Resource {
    public static const THROW_ON_ACCESSING = DummyInputStream(true)
    public static const SILENCE = DummyInputStream(false)
    private const DummyInputStream(private let throwing: Bool) {}

    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {}

    public func read(buffer: Array<Byte>): Int64 {
        if (throwing) {
            throw Exception("DummyInputStream is not readable")
        } else {
            0
        }
    }
}
