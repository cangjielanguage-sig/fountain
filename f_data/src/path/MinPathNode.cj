/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_data.path

internal class MinPathNode <: DataPathNode {
    static let instance = MinPathNode()
    private init() {}
    public func get(data: Data): Iterator<Data> {
        match (data) {
            case x: Iterable<Data> =>
                var r = None<Data>
                for (v in x) {
                    if (r.isNone()) {
                        r = v
                        continue
                    }
                    r = match ((v, r)) {
                        case (x: DataDateTime, y: DataDateTime) where x < y => x
                        case (x: DataDuration, y: DataDuration) where x < y => x
                        case (x: DataReal, y: DataReal) where x < y => x
                        case (x: DataString, y: DataString) where x < y => x
                        case _ => continue
                    }
                }
                OptionIterator<Data>(r)
            case _ => OptionIterator<Data>()
        }
    }
}
