/*
Copyright (c) 2026 WuJingrun（吴京润）

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
package fountain::f_concurrent
// import std.unittest.*
// import std.unittest.testmacro.*
// import std.random.Random
// import std.sync.*
// import std.collection.*

// @Test
// public class ConcurrentSkipListMap_bug_test{
//     @TestCase
//     public func test_concurrent_add_all_and_operations(): Unit {
//         println('test_concurrent_add_all_and_operations')
//         // 测试 add(all) 与其他操作的并发
//         let map = ConcurrentSkipListMap<Int64, Int64>()
//         let threads = 100
//         let c = SyncCounter(threads)

//         // 线程使用 add(all)
//         spawn {
//             for (t in 0..threads) {
//                 let entries = ArrayList<(Int64, Int64)>()
//                 for (i in t * 100 .. (t + 1) * 100) {
//                     entries.add((i, i))
//                 }
//                 map.add(all: entries)
//             }
//             c.dec()
//             println('[MAIN] DEC')
//         }

//         // 其他线程同时进行单 add/get/remove
//         for (t in 1..threads) {
//              spawn {
//                 let rand = Random()
//                 for (_ in 0..500) {
//                     let key = rand.nextInt64(10000)
//                     let op = rand.nextInt64(3)
//                     match (op) {
//                         case 0 => map.add(key, key)
//                         case 1 => map.get(key)
//                         case 2 => map.remove(key)
//                         case _ => ()
//                     }
//                 }
//                 c.dec()
//                 println('[THREAD ${t}] DEC')
//             }
//         }

//         c.waitUntilZero()
//         println('Counter Zero')
//         // 验证 add(all) 插入的数据存在
//         for (i in 0..threads * 100) {
//             if (map.contains(i)) {
//                 @Assert(map.get(i).getOrThrow() == i)
//             }
//         }
//     }
    
//     @TestCase
//     public func test_size_consistency_under_concurrent_modifications1(): Unit {
//         println('test_size_consistency_under_concurrent_modifications1')
//         // 暴露 size 不一致 bug（用例44）
//         let map = ConcurrentSkipListMap<Int64, Int64>()
//         let threads = 200
//         let iterations = 1000
//         let c = SyncCounter(threads)

//         for (t in 0..threads) {
//             spawn {
//                 for (i in 0..iterations) {
//                     if (i % 2 == 0) {
//                         map.add(i, i)
//                     } else {
//                         map.remove(i - 1)
//                     }
//                 }
//                 c.dec()
//                 println('[THREAD ${t}] DEC')
//             }
//         }
//         c.waitUntilZero()
//         println('Counter Zero')

//         // 最终实际节点数（通过遍历统计）
//         var actualSize = 0
//         for ((_, _) in map.iterator()) {
//             actualSize += 1
//         }
//         // 由于并发删除/插入，实际大小可能不等于 size_.load() 的瞬时值，
//         // 但最终应一致（无其他修改时）。这里简单检查 size 非负且遍历计数与 size 最终相等
//         @Assert(actualSize, map.size)
//     }

//     @TestCase
//     public func test_size_consistency_under_concurrent_modifications2(): Unit {
//         println('test_size_consistency_under_concurrent_modifications2')
//         // 暴露 size 不一致 bug（用例44）
//         let map = ConcurrentSkipListMap<Int64, Int64>()
//         let threads = 200
//         let iterations = 1000
//         let c = SyncCounter(threads)

//         for (t in 0..threads) {
//             spawn {
//                 for (i in 0..iterations) {
//                     map.add(i,i)
//                     map.remove(i - 1)
//                 }
//                 c.dec()
//                 println('[THREAD ${t}] DEC')
//             }
//         }
//         c.waitUntilZero()
//         println('Counter Zero')

//         // 最终实际节点数（通过遍历统计）
//         var actualSize = 0
//         for ((_, _) in map.iterator()) {
//             actualSize += 1
//         }
//         // 由于并发删除/插入，实际大小可能不等于 size_.load() 的瞬时值，
//         // 但最终应一致（无其他修改时）。这里简单检查 size 非负且遍历计数与 size 最终相等
//         @Assert(actualSize, map.size)
//     }

//     @TestCase
//     public func test_size_consistency_under_concurrent_modifications3(): Unit {
//         println('test_size_consistency_under_concurrent_modifications3')
//         // 暴露 size 不一致 bug（用例44）
//         let map = ConcurrentSkipListMap<Int64, Int64>()
//         let threads = 200
//         let iterations = 500
//         let c = SyncCounter(threads)

//         for (t in 0..threads) {
//             spawn {
//                 for (i in 0..iterations) {
//                     map.add(i,i)
//                     map.remove(i)
//                 }
//                 c.dec()
//                 println('[THREAD ${t}] DEC')
//             }
//         }
//         c.waitUntilZero()
//         println('Counter Zero')

//         // 最终实际节点数（通过遍历统计）
//         var actualSize = 0
//         for ((_, _) in map.iterator()) {
//             actualSize += 1
//         }
//         // 由于并发删除/插入，实际大小可能不等于 size_.load() 的瞬时值，
//         // 但最终应一致（无其他修改时）。这里简单检查 size 非负且遍历计数与 size 最终相等
//         @Assert(actualSize, map.size)
//     }

// }