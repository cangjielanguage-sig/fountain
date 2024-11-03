package f_base

import std.collection.Map

public interface Bucket<K, V> <: Map<K, V> & Iterable<(K, V)> where K <: Equatable<K> {}
