/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package fountain::f_data.path

internal class RecursiveDescentIterator <: Iterator<Data> {
    private let list = LinkedList<Iterator<Data>>()
    private var itr: Iterator<Data> = EmptyIterator<Data>.instance()
    private let rootData: Data
    init(data: Data) {
        rootData = data
        append(data)
    }
    private func append(data: Data) {
        list.addFirst(AnySubPathNode.instance.get(data))
    }
    public func next(): ?Data {
        while (true) {
            if (let Some(x) <- itr.next()) {
                // Only descend into containers (lists, objects), not scalars
                match (x) {
                    case _: Iterable<Data> => append(x)
                    case _: Iterable<(String, Data)> => append(x)
                    case _: Iterable<(Data, Data)> => append(x)
                    case _ => ()
                }
                return x
            } else if (let Some(i) <- list.removeFirst()) {
                itr = i.iterator()
            } else {
                return None<Data>
            }
        }
        None<Data>
    }
}
