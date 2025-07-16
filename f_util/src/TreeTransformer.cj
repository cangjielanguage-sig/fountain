/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_util

import std.collection.ArrayList
import std.collection.HashMap

public interface TreeNode<ID, T> where ID <: Hashable & Equatable<ID>, T <: Object & TreeNode<ID, T> {
    prop children: ArrayList<T>
    func addChild(child: T): Unit {
        children.add(child)
    }

    func addChildren(children: Iterable<T>) {
        for (ch in children) {
            addChild(ch)
        }
    }
    func addChildren(children: Array<T>) {
        let itr: Iterable<T> = children
        addChildren(itr)
    }
    prop id: ID
    prop parentId: ID

    static func transform<S>(iterable: Iterable<S>, emptyId: ID, ignoreDuplicate: Bool, transferFn: (S) -> ?T): ArrayList<T> {
        let map = HashMap<ID, T>()
        let root = ArrayList<T>()
        let list = ArrayList<T>()
        for (s in iterable) {
            let t = transferFn(s).getOrThrow {
                IllegalArgumentException("There is some element in arg iterable which cannot be transformed into T")
            }
            if (map.add(t.id, t).isNone()) {
                list.add(t)
            } else if (!ignoreDuplicate) {
                throw IllegalArgumentException("Some elements are duplicate which are transformed from arg iterable.")
            }
        }
        for (t in list) {
            let parentId = t.parentId
            if (parentId == emptyId) {
                root.add(t)
            } else {
                map[parentId].addChild(t)
            }
        }
        return root
    }
    static func transform<S>(iterable: Iterable<S>, emptyId: ID, transferFn: (S) -> ?T): ArrayList<T> {
        transform<S>(iterable, emptyId, false, transferFn)
    }
    static func transform<S>(iterable: Iterable<S>, emptyId: ID) {
        transform<S>(iterable, emptyId, false)
    }
    static func transform<S>(iterable: Iterable<S>, emptyId: ID, ignoreDuplicate: Bool) {
        transform<S>(iterable, emptyId, ignoreDuplicate) {s => s as T}
    }
}
