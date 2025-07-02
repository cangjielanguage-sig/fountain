/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_io

public class DummyOutputStream <: OutputStream & Resource {
    public static const THROW_ON_ACCESSING = DummyOutputStream(true)
    public static const SILENCE = DummyOutputStream(false)
    private const DummyOutputStream(private let throwing: Bool) {}

    public func isClosed(): Bool {
        false
    }
    public func close(): Unit {}

    private func throwIfNeed() {
        if (throwing) {
            throw Exception("DummyOutputStream is not writable")
        }
    }
    public func flush(): Unit {
        throwIfNeed()
    }

    public func write(buffer: Array<Byte>): Unit {
        throwIfNeed()
    }
}
