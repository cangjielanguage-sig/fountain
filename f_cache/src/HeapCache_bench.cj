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
package fountain::f_cache

import std.unittest.*
import std.unittest.testmacro.*

/**
 * `f_cache` 基准（`cjpm bench`）。值类型用 `Box<Int64>`（不引入测试辅助类，避免与本文件的 `Test` 宏同名冲突）：
 * - `benchGetHit`：命中路径（分段读锁 → `Priority.load` 含 `p.lock`）—— 覆盖 `CACHE-8` ① 新增的锁
 * - `benchSetSameKey` / `benchSetDistinctKeys`：写入路径（段写锁 + 新建 `Priority` + size 记账）—— 覆盖 `CACHE-2`/`CACHE-3` 的记账
 * - `benchSetUnderEvictionPressure`：`maxSize=1` 两键交替写，定时淘汰持续与写入竞争 —— 覆盖 `CACHE-8` ②（`compare` 重写）
 */
@Test
public class HeapCacheBench {
    private let hitCache = HeapCache<Box<Int64>>(maxSize: 1000, maxLife: Duration.second * 60,
        checkDuration: Duration.second)
    private let setCache = HeapCache<Box<Int64>>(maxSize: 1000, maxLife: Duration.second * 60,
        checkDuration: Duration.second)
    private let evictCache = HeapCache<Box<Int64>>(maxSize: 1, maxLife: Duration.second * 60,
        checkDuration: Duration.millisecond * 100)
    private var i = 0

    public init() {
        let _ = hitCache.set('hot', Box<Int64>(1))
    }

    @Bench
    public func benchGetHit(): Unit {
        let _ = hitCache.get('hot')
    }

    @Bench
    public func benchSetSameKey(): Unit {
        let _ = setCache.set('k', Box<Int64>(1))
    }

    @Bench
    public func benchSetDistinctKeys(): Unit {
        //键空间有界（2×maxSize）：既持续触发淘汰，又不会让基准把内存灌爆而 OOM
        i++
        let n = i % 2000
        let _ = setCache.set('k${n}', Box<Int64>(n))
    }

    @Bench
    public func benchSetUnderEvictionPressure(): Unit {
        i++
        let _ = evictCache.set('p${i % 2}', Box<Int64>(i))
    }
}
