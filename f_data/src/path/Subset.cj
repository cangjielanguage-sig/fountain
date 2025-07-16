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

internal abstract class Subset<T> where T <: ToString & DataFields<T> {
    protected let left: DataPath
    private let right = HashSet<String>()
    init(left: DataPath, right: ArrayList<T>) {
        for (v in right) {
            this.right.add(v.toData().toString())
        }
        this.left = left
    }
    func subset(data: Data): Int64 {
        var subsetSize = 0
        let d = match (left.get(data).next()) {
            case Some(x) => x
            case _ => return subsetSize
        }
        match (d) {
            case x: Iterable<Data> => for (v in x where right.contains(v.toString())) {
                subsetSize++
            }
            case x: Iterable<(String, Data)> => for ((k, v) in x where right.contains(k)) {
                subsetSize++
            }
            case x: Iterable<(Data, Data)> => for ((k, _) in x where right.contains(k.toString())) {
                subsetSize++
            }
            case _ => ()
        }
        subsetSize
    }
}
