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

internal class IndexPathNode <: DataPathNode {
    IndexPathNode(private let index: Int64) {}
    public func get(data: Data): Iterator<Data> {
        match (data) {
            case x: Collection<Data> =>
                let positiveIdx = if (index < 0) {
                    x.size + index
                } else {
                    index
                }
                if (positiveIdx < 0 || positiveIdx >= x.size) {
                    OptionIterator<Data>()
                } else {
                    x.iterator().skip(positiveIdx).take(1)
                }
            case x: Iterable<Data> =>
                if (index >= 0) {
                    x.iterator().skip(index).take(1)
                } else {
                    OptionIterator<Data>()
                }
            case _ => OptionIterator<Data>()
        }
    }
}
