/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_net

public interface ProtocolData<T> where T <: ProtocolData<T> {
    /**
     * 返回true时关闭连接
     */
    prop isToClose: Bool {
        get() {
            false
        }
    }
    prop isOverload: Bool {
        get() {
            false
        }
    }
}

public interface KeyedData<K, T> <: ProtocolData<T> where K <: Hashable & Equatable<K>, T <: KeyedData<K, T> {
    prop key: K
}
