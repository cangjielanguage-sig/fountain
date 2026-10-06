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
package fountain::f_pool

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PoolInvariantTest {
    private func newKeyPool(items: Int64): KeyPool<String, Object> {
        KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: items,
            totalSize: items,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker: {_,_=>true},
            destroier: {_,_=>}
        )
    }

    /** 借空后：size 必须与实际可借数一致（长跑/并发之后再验也成立）。 */
    @TestCase
    public func sizeMatchesBorrowableCount(): Unit {
        let pool = newKeyPool(3)
        sleep(Duration.second * 2) // 初始池项由后台创建调度异步创建
        @Assert(pool.size == 3)
        let held = ArrayList<Object>()
        while(let Some(v) <- pool.get('a', timeout: Duration.Zero)){
            held.add(v)
        }
        @Assert(held.size == 3)
        @Assert(pool.size == 3)
        @Assert(pool.checkSize())
        for(v in held){
            pool.giveBack('a', v)
        }
        var again = 0
        while(let Some(_) <- pool.get('a', timeout: Duration.Zero)){
            again += 1
        }
        @Assert(again == 3)
        @Assert(pool.size == 3)
    }

    /** 并发借还：借到的缓冲必须是空的 —— 若两个借用者拿到同一底层 list（double-lend）或归还未清空，这里会失败。 */
    @TestCase
    public func concurrentBorrowNeverSharesBuffer(): Unit {
        let builder = BytesListOutputStream.builder(initSize: 4, minSize: 4, maxSize: 4, clearOnReturning: true)
        let tasks = 8
        let iters = 2000
        let futures = Array<Future<Unit>>(tasks, repeat: unsafe{zeroValue<Future<Unit>>()})
        for(i in 0..tasks){
            futures[i] = spawn{
                for(_ in 0..iters){
                    let b = builder.build(timeout: Duration.second * 5).getOrThrow()
                    @Assert(b.isEmpty)
                    b.write([1u8, 2u8, 3u8])
                    b.release()
                }
            }
        }
        for(f in futures){
            f.get()
        }
    }
}
