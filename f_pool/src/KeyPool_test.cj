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

@Test
public class KeyPoolTest {
    @TestCase
    public func test0(): Unit{
        println('~~~~~~~~~~~~~~~~~~')
        let start = MonoTime.now()
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','b','c','a','b','c'].iterator().next,
            minSize: 2,
            maxSize: 5,
            totalSize: 10,
            checkOnCreation: true,
            checkOnReturning: true,
            checkOnBorrowing: true,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        sleep(Duration.second * 2)
        @Assert(pool.size, 6)
        @Assert(pool.checkSize())
        let a1 = pool.get('a', timeout: Duration.second)
        @Assert(a1.isSome())
        let a2 = pool.get('a')
        @Assert(a2.isSome())
        let a3 = pool.get('a')
        @Assert(a3.isSome())
        let a4 = pool.get('a')
        @Assert(a4.isSome())
        let a5 = pool.get('a')
        @Assert(a5.isSome())
        @Assert(pool.size, 9)
        @Assert(pool.checkSize())
        let a6 = pool.get('a', timeout: Duration.second)
        @Assert(a6.isNone())
        let b1 = pool.get('b')
        let b2 = pool.get('b')
        let b3 = pool.get('b')
        @Assert(b3.isSome())
        let b4 = pool.get('b', timeout: Duration.second)
        @Assert(b4.isNone())
        let c1 = pool.get('c')
        @Assert(c1.isSome())
        let c2 = pool.get('c')
        @Assert(c2.isSome())
        pool.giveBack('a', a1.getOrThrow())
        @Assert(pool.get('a').isSome())
    }
    @TestCase
    public func testInvalidOnBorrowing(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: true,
            creator: {_=>Object()},
            checker:{_,_=>false},
            destroier:{_,_=>}
        )
        sleep(Duration.second * 2)
        @Assert(pool.checkSize())
        @Assert(pool.size, 3)
        let a = pool.get('a', timeout: Duration.Zero)
        @Assert(a.isNone())
        @Assert(pool.checkSize())
        @Assert(pool.size, 0)
    }
    @TestCase
    public func testInvalidOnReturning(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: true,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>false},
            destroier:{_,_=>}
        )
        let a1 = pool.get('a')
        pool.giveBack('a', a1.getOrThrow())
        let a2 = pool.get('a')
        pool.giveBack('a', a2.getOrThrow())
        let a3 = pool.get('a')
        pool.giveBack('a', a3.getOrThrow())
        sleep(Duration.second * 2)
        @Assert(pool.checkSize())
        @Assert(pool.size, 0)
    }
    @TestCase
    public func testFifo(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let a1 = pool.get('a').getOrThrow()
        let a2 = pool.get('a').getOrThrow()
        let a3 = pool.get('a').getOrThrow()
        pool.giveBack('a', a1)
        pool.giveBack('a', a2)
        pool.giveBack('a', a3)
        @Assert(refEq(pool.get('a').getOrThrow(), a1))
        @Assert(refEq(pool.get('a').getOrThrow(), a2))
        @Assert(refEq(pool.get('a').getOrThrow(), a3))
    }
    @TestCase
    public func testLifo(){
        let pool = KeyPool<String, Object>(
            mode: Lifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 3,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let a1 = pool.get('a').getOrThrow()
        let a2 = pool.get('a').getOrThrow()
        let a3 = pool.get('a').getOrThrow()
        pool.giveBack('a', a1)
        pool.giveBack('a', a2)
        pool.giveBack('a', a3)
        @Assert(refEq(pool.get('a').getOrThrow(), a3))
        @Assert(refEq(pool.get('a').getOrThrow(), a2))
        @Assert(refEq(pool.get('a').getOrThrow(), a1))
    }
    @TestCase
    public func testConcurrency(){
        let pool = KeyPool<String, Object>(
            mode: Fifo,
            initKeys: ['a','a','a'].iterator().next,
            minSize: 0,
            maxSize: 3,
            totalSize: 10,
            checkOnCreation: false,
            checkOnReturning: false,
            checkOnBorrowing: false,
            creator: {_=>Object()},
            checker:{_,_=>true},
            destroier:{_,_=>}
        )
        let array = Array<Future<Unit>>(10, repeat: unsafe{zeroValue<Future<Unit>>()})
        for(i in 0 .. 10){
            array[i] = spawn{
                for(_ in 0 .. 1000){
                    let a = pool.get('a', timeout: Duration.Max).getOrThrow()
                    pool.giveBack('a', a)
                }
            }
        }
        for(f in array){
            f.get()
        }
    }
}

@Test
public class KeyPoolBench{
    private let pool = KeyPool<String, Object>(
        mode: Fifo,
        initKeys: ['a','a','a'].iterator().next,
        minSize: 0,
        maxSize: 3,
        totalSize: 10,
        checkOnCreation: false,
        checkOnReturning: false,
        checkOnBorrowing: false,
        creator: {_=>Object()},
        checker:{_,_=>true},
        destroier:{_,_=>}
    )
    @Bench
    public func bench(){
        let a = pool.get('a', timeout: Duration.Max).getOrThrow()
        pool.giveBack('a', a)
    }
}