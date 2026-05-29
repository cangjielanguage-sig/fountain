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
package fountain::f_store

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.fs.*
import std.sync.AtomicBool
import std.time.DateTime

/** Store 性能基准测试 */
@Test
public class StoreBench {
    let testDir = "/tmp/f_store_bench"

    func setupStore(name: String): Store {
        let dir = "${testDir}/${name}"
        if (exists(dir)) { remove(dir, recursive: true) }
        Store(dir)
    }

    // ================================================================
    // 单线程基准测试
    // ================================================================

    @Bench
    public func benchAdd(): Unit {
        let store = setupStore("add")
        for (i in 0..1000) {
            store.add("bk_${i}".unsafeBytes(), "bv_${i}".unsafeBytes())
        }
        store.close()
        remove("${testDir}/add", recursive: true)
    }

    @Bench
    public func benchGet(): Unit {
        let store = setupStore("get")
        for (i in 0..1000) {
            store.add("ck_${i}".unsafeBytes(), "cv_${i}".unsafeBytes())
        }
        for (i in 0..1000) {
            let _ = store.get("ck_${i}".unsafeBytes())
        }
        store.close()
        remove("${testDir}/get", recursive: true)
    }

    @Bench
    public func benchRemove(): Unit {
        let store = setupStore("remove")
        for (i in 0..1000) {
            store.add("rk_${i}".unsafeBytes(), "rv_${i}".unsafeBytes())
        }
        for (i in 0..1000) {
            let _ = store.remove("rk_${i}".unsafeBytes())
        }
        store.close()
        remove("${testDir}/remove", recursive: true)
    }

    @Bench
    public func benchPrefix(): Unit {
        let store = setupStore("prefix")
        for (i in 0..500) {
            store.add("px:user:${i}".unsafeBytes(), "pv".unsafeBytes())
        }
        let iter = store.prefix("px:user:".unsafeBytes())
        while (let Some(_) <- iter.next()) {}
        store.close()
        remove("${testDir}/prefix", recursive: true)
    }

    @Bench
    public func benchTTL(): Unit {
        let store = setupStore("ttl")
        for (i in 0..1000) {
            store.add("tk_${i}".unsafeBytes(), "tv".unsafeBytes())
        }
        for (i in 0..1000) {
            store.ttl("tk_${i}".unsafeBytes(), Duration.second * 10)
        }
        store.close()
        remove("${testDir}/ttl", recursive: true)
    }

    @Bench
    public func benchAddWithExpire(): Unit {
        let store = setupStore("add_exp")
        for (i in 0..1000) {
            store.add("aek_${i}".unsafeBytes(), "aev".unsafeBytes(), Duration.second * 3600)
        }
        store.close()
        remove("${testDir}/add_exp", recursive: true)
    }

    // ================================================================
    // 并发基准测试
    // ================================================================

    @Bench
    public func benchConcurrentAdd(): Unit {
        let store = setupStore("conc_add")
        let N = 4
        let M: Int64 = 250
        let futures = ArrayList<Future<Unit>>()
        for (t in 0..N) {
            let fut = spawn {
                for (i in 0..M) {
                    store.add("ca_${t}_${i}".unsafeBytes(), "cv".unsafeBytes())
                }
            }
            futures.add(fut)
        }
        for (f in futures) { f.get() }
        store.close()
        remove("${testDir}/conc_add", recursive: true)
    }

    @Bench
    public func benchConcurrentGet(): Unit {
        let store = setupStore("conc_get")
        for (i in 0..1000) {
            store.add("cg_${i}".unsafeBytes(), "cv".unsafeBytes())
        }
        let N = 4
        let M: Int64 = 250
        let futures = ArrayList<Future<Unit>>()
        for (t in 0..N) {
            let fut = spawn {
                for (i in 0..M) {
                    let _ = store.get("cg_${i}".unsafeBytes())
                }
            }
            futures.add(fut)
        }
        for (f in futures) { f.get() }
        store.close()
        remove("${testDir}/conc_get", recursive: true)
    }

    @Bench
    public func benchMixed(): Unit {
        let store = setupStore("mixed")
        for (i in 0..500) {
            store.add("m_base_${i}".unsafeBytes(), "v".unsafeBytes())
        }
        let running = AtomicBool(true)
        let N = 4
        let futures = ArrayList<Future<Unit>>()

        // Writer
        futures.add(spawn {
            var idx: Int64 = 0
            while (running.load()) {
                try {
                    store.add("m_w_${idx}".unsafeBytes(), "wv".unsafeBytes())
                    idx++
                } catch (_: StoreClosedException) { break }
            }
        })
        // Getter
        futures.add(spawn {
            while (running.load()) {
                try {
                    let _ = store.get("m_base_0".unsafeBytes())
                } catch (_: StoreClosedException) { break }
            }
        })
        // Remover + adder
        futures.add(spawn {
            var idx: Int64 = 0
            while (running.load()) {
                try {
                    let _ = store.remove("m_base_${idx % 500}".unsafeBytes())
                    store.add("m_base_${idx % 500}".unsafeBytes(), "v2".unsafeBytes())
                    idx++
                } catch (_: StoreClosedException) { break }
            }
        })
        // Prefix
        futures.add(spawn {
            while (running.load()) {
                try {
                    let iter = store.prefix("m_".unsafeBytes())
                    while (let Some(_) <- iter.next()) {}
                } catch (_: StoreClosedException) { break }
            }
        })
        // TTL
        futures.add(spawn {
            var idx: Int64 = 0
            while (running.load()) {
                try {
                    store.ttl("m_base_${idx % 500}".unsafeBytes(), Duration.second * 30)
                    idx++
                } catch (_: StoreClosedException) { break }
            }
        })

        sleep(Duration.millisecond * 500)
        running.store(false)
        for (f in futures) { f.get() }
        store.close()
        remove("${testDir}/mixed", recursive: true)
    }
}
