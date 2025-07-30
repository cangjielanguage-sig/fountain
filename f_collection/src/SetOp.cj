/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_collection

internal import std.collection.{ReadOnlySet, Set, HashSet, TreeSet}

public interface SetOp<T> {
    func intersection<C>(collection: C): Set<T> where C <: Collection<T>
    func union<C>(collection: C): Set<T> where C <: Collection<T>
    func difference<C>(collection: C): Set<T> where C <: Collection<T>
    func overlaps<C>(collection: C): Bool where C <: Collection<T>{
        !intersection(collection).isEmpty()
    }
}
extend<T> HashSet<T> <: SetOp<T> where T <: Hashable & Equatable<T> {
    public func intersection<C>(collection: C): Set<T> where C <: Collection<T>{
        IntersectionSetView<T, C>(this, HashSet<T>(collection))
    }
    public func union<C>(collection: C): Set<T> where C <: Collection<T>{
        UnionSetView<T, C>(this, HashSet<T>(collection))
    }
    public func difference<C>(collection: C): Set<T> where C <: Collection<T>{
        DifferenceSetView<T, C>(this, HashSet<T>(collection))
    }
}
extend<T> LinkedHashSet<T> <: SetOp<T> where T <: Hashable & Equatable<T> {
    public func intersection<C>(collection: C): Set<T> where C <: Collection<T>{
        IntersectionSetView<T, C>(this, LinkedHashSet<T>(collection))
    }
    public func union<C>(collection: C): Set<T> where C <: Collection<T>{
        UnionSetView<T, C>(this, LinkedHashSet<T>(collection))
    }
    public func difference<C>(collection: C): Set<T> where C <: Collection<T>{
        DifferenceSetView<T, C>(this, LinkedHashSet<T>(collection))
    }
}
extend<T> TreeSet<T> <: SetOp<T> where T <: Comparable<T> {
    public func intersection<C>(collection: C): Set<T> where C <: Collection<T>{
        IntersectionSetView<T, C>(this, TreeSet<T>(collection))
    }
    public func union<C>(collection: C): Set<T> where C <: Collection<T>{
        UnionSetView<T, C>(this, TreeSet<T>(collection))
    }
    public func difference<C>(collection: C): Set<T> where C <: Collection<T>{
        DifferenceSetView<T, C>(this, TreeSet<T>(collection))
    }
}