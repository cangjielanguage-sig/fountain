/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_log.output

protected class DummyOutputStream <: OutputStream & Resource {
    protected static const instance = DummyOutputStream()
    private const init(){}

    public func isClosed(): Unit {
        false
    }
    public func close(): Unit {}

    public func flush(): Unit {
        throw LogException("DummyOutputStream is not writable")
    }

    public func write(buffer: Array<Byte>): Unit {
        throw LogException("DummyOutputStream is not writable")
    }
}