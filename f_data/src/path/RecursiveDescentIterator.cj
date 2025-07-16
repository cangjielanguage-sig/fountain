/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.path

internal class RecursiveDescentIterator <: Iterator<Data> {
    private let list = LinkedList<Iterator<Data>>()
    private var itr: Iterator<Data> = EmptyIterator<Data>.INSTANCE()
    init(data: Data) {
        append(data)
    }
    private func append(data: Data) {
        list.addLast(AnySubPathNode.instance.get(data))
    }
    public func next(): ?Data {
        if (let Some(x) <- itr.next()) {
            if (!(itr is SingleIterable<Data>)) {
                append(x)
            }
            x
        } else if (let Some(i) <- list.removeFirst()) {
            itr = i.iterator()
            next()
        } else {
            None<Data>
        }
    }
}
