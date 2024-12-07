/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_net

public interface Encoder<EN> where EN <: ProtocolData<EN> {
    func encode(data: EN): Array<Byte>
    /**
     * 每次调用务必返回一个新实例
     */
    func newEncoder(): Encoder<EN>
}
public interface Decoder<DE> where DE <: ProtocolData<DE> {
    /**
     * 当调用本函数若干次后，传入的字节数组可完成解析完成的DE时返回Some，否则返回None。
     */
    func decode(bytes: Array<Byte>): ?DE
    /**
     * 每次调用务必返回一个新实例
     */
    func newDecoder(): Decoder<DE>
}
public interface Codec<EN, DE> <: Encoder<EN> & Decoder<DE> where EN <: ProtocolData<EN>, DE <: ProtocolData<DE> {
}