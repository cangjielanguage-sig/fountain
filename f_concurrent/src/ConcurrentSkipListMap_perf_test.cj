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

import std.unittest.*
import std.unittest.testmacro.*
import std.random.Random
import std.sync.*
import std.collection.*

@Test
public class ConcurrentSkipListMap_perf_test {
    @TestCase
    public func test_perf_single_thread_add(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 10000
        let start = MonoTime.now()
        for (i in 0..n) {
            map.add(i, i)
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let opsPerSec = n * 1000000000 / (elapsed + 1)
        println("perf_single_thread_add: ${n} ops in ${elapsed}ns, ${opsPerSec} ops/s")
    }

    @TestCase
    public func test_perf_single_thread_get(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 10000
        for (i in 0..n) {
            map.add(i, i)
        }
        let start = MonoTime.now()
        for (i in 0..n) {
            let _ = map.get(i)
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let opsPerSec = n * 1000000000 / (elapsed + 1)
        println("perf_single_thread_get: ${n} ops in ${elapsed}ns, ${opsPerSec} ops/s")
    }

    @TestCase
    public func test_perf_single_thread_remove(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let n = 10000
        for (i in 0..n) {
            map.add(i, i)
        }
        let start = MonoTime.now()
        for (i in 0..n) {
            map.remove(i)
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let opsPerSec = n * 1000000000 / (elapsed + 1)
        println("perf_single_thread_remove: ${n} ops in ${elapsed}ns, ${opsPerSec} ops/s")
    }

    @TestCase
    public func test_perf_concurrent_add(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        let threads = 8
        let opsPerThread = 10000
        let futures = ArrayList<Future<Unit>>(threads)
        let start = MonoTime.now()
        for (_ in 0..threads) {
            let fut = spawn {
                for (j in 0..opsPerThread) {
                    map.add(j, j)
                }
            }
            futures.add(fut)
        }
        for (fut in futures) {
            fut.get()
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let totalOps = threads * opsPerThread
        let opsPerSec = totalOps * 1000000000 / (elapsed + 1)
        println("perf_concurrent_add: ${totalOps} ops in ${elapsed}ns, ${opsPerSec} ops/s, threads=${threads}")
    }

    @TestCase
    public func test_perf_concurrent_mixed(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        // 预填充
        for (i in 0..5000) {
            map.add(i, i)
        }
        let threads = 8
        let opsPerThread = 5000
        let futures = ArrayList<Future<Unit>>(threads)
        let start = MonoTime.now()
        for (t in 0..threads) {
            let fut = spawn {
                let rand = Random()
                for (_ in 0..opsPerThread) {
                    let op = rand.nextInt64(4)
                    let key = rand.nextInt64(5000)
                    match (op) {
                        case 0 => let _ = map.get(key)
                        case 1 => map.add(key, rand.nextInt64())
                        case 2 => let _ = map.remove(key)
                        case 3 => map.entryView(key) { view =>
                            let cur = view.value
                            match (cur) {
                                case Some(v) => view.value = Some(v + 1)
                                case None => view.value = Some(0)
                            }
                        }
                        case _ => ()
                    }
                }
            }
            futures.add(fut)
        }
        for (fut in futures) {
            fut.get()
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let totalOps = threads * opsPerThread
        let opsPerSec = totalOps * 1000000000 / (elapsed + 1)
        println("perf_concurrent_mixed: ${totalOps} ops in ${elapsed}ns, ${opsPerSec} ops/s, threads=${threads}")
    }

    @TestCase
    public func test_perf_concurrent_entryView(): Unit {
        let map = ConcurrentSkipListMap<Int64, Int64>()
        map.add(1, 0)
        let threads = 8
        let opsPerThread = 10000
        let futures = ArrayList<Future<Unit>>(threads)
        let start = MonoTime.now()
        for (_ in 0..threads) {
            let fut = spawn {
                for (_ in 0..opsPerThread) {
                    map.entryView(1) { view =>
                        let cur = view.value.getOrThrow()
                        view.value = Some(cur + 1)
                    }
                }
            }
            futures.add(fut)
        }
        for (fut in futures) {
            fut.get()
        }
        let elapsed = (MonoTime.now() - start).toNanoseconds()
        let totalOps = threads * opsPerThread
        let opsPerSec = totalOps * 1000000000 / (elapsed + 1)
        @Assert(map.get(1).getOrThrow(), threads * opsPerThread)
        println("perf_concurrent_entryView: ${totalOps} ops in ${elapsed}ns, ${opsPerSec} ops/s, threads=${threads}")
    }
}
