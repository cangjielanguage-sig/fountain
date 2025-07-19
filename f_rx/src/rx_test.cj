/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_rx

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class RxTest{
    private let mutex = Mutex()
    @TestCase
    public func testFutureIterableAndImmediately(): Unit {
        let i = AtomicInt64(1)
        Observable<Int64>.iterable({=> spawn{[1,2,3]}})
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(i.load(), v)
                i.fetchAdd(1)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testFutureIterableAndImmediately")
            }
        }).immediately()
    }
    @TestCase
    public func testFutureIterableAndDefer(): Unit {
        let i = AtomicInt64(2)
        Observable<Int64>.iterable({=> spawn{[2,4,6]}})
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(i.load(), v)
                i.fetchAdd(2)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testFutureIterableAndDefer")
            }
        }).defer()
    }
    @TestCase
    public func testIterableAndDefer(): Unit {
        let i = AtomicInt64(1)
        Observable<Int64>.iterable({=> spawn{[1,3,5]}})
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(i.load(), v)
                i.fetchAdd(2)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testIterableAndDefer")
            }
        }).defer()
    }
    @TestCase
    public func testIterableAndImmediately(): Unit {
        let i = AtomicInt64(11)
        Observable<Int64>.iterable({=> spawn{[11,13,15]}})
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(i.load(), v)
                i.fetchAdd(2)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testIterableAndImmediately")
            }
        }).immediately()
    }
    @TestCase
    public func testEmptyAndImmediately(): Unit {
        Observable<Int64>.empty()
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            throw Exception('unreachable')
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testEmptyAndImmediately")
            }
        }).immediately()
    }
    @TestCase
    public func testEmptyAndDefer(): Unit {
        Observable<Int64>.empty()
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            throw Exception('unreachable')
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testEmptyAndDefer")
            }
        }).defer()
    }
    @TestCase
    public func testSingleAndDefer(): Unit {
        Observable<Int64>.single(100)
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(100, v)
                println(100)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testSingleAndDefer")
            }
        }).defer()
    }
    @TestCase
    public func testSingleAndImmediately(): Unit {
        Observable<Int64>.single(101)
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(101, v)
                println(101)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testSingleAndImmediately")
            }
        }).immediately()
    }
    @TestCase
    public func testMaybeAndImmediately(): Unit {
        Observable<Int64>.maybe(200)
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(200, v)
                println(200)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testMaybeAndImmediately")
            }
        }).immediately()
    }
    @TestCase
    public func testConcatAndImmediately(): Unit {
        let n = AtomicInt64(10)
        Observable<Int64>.concat([[10, 20, 30], [40, 50, 60], [70, 80, 90]])
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(n.load(), v)
                n.fetchAdd(10)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testConcatAndImmediately")
            }
        }).immediately()
    }
    @TestCase
    public func testEmitterAndImmediately(): Unit {
        let m = AtomicInt64(1000)
        let n = AtomicInt64(1000)
        Observable<Int64>.emitter({emitter =>
            while(let v <- m.fetchAdd(1000) && v <= 3000){
                emitter.onNext(v)
            }
            emitter.onComplete()
        })
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(n.load(), v)
                n.fetchAdd(1000)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testConcatAndImmediately")
            }
        }).immediately()
        // sleep(Duration.second * 5)
    }
    @TestCase
    public func testEmitterErrorAndImmediately(): Unit {
        let m = AtomicInt64(4000)
        let n = AtomicInt64(4000)
        Observable<Int64>.emitter({emitter =>
            while(let v <- m.fetchAdd(1000) && v <= 3000){
                emitter.onNext(v)
            }
            emitter.onError(Exception('too large'))
        })
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                @Assert(n.load(), v)
                n.fetchAdd(1000)
                println(v)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                throw Exception('unreachable')
            }
        }.setErrorFunc{e => 
            synchronized(mutex){
                @Assert("too large", e.message)
                println('emitter error too large')
            }
        }).immediately()
    }
    @TestCase
    public func testAlwaysNewAndImmediately(): Unit {
        let threads = ArrayBlockingQueue<Thread>(3)
        Observable<Int64>.iterable([10000, 20000, 30000])
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                println(v)
                threads.add(Thread.currentThread)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testAlwaysNewAndImmediately")
            }
        }).withAlwaysNew().immediately()
        sleep(Duration.second * 5)
        var t = None<Thread>
        let i = AtomicInt64(0)
        while(let someqt <- threads.tryRemove() && let Some(qt) <- someqt && i.fetchAdd(1) < 3){
            threads.add(qt)
            if(let Some(tt) <- t && refEq(tt, qt)){
                throw Exception('same threads')
            }
            t = qt
        }
    }
    @TestCase
    public func testFixedAndImmediately(): Unit {
        let threads = ArrayBlockingQueue<Thread>(3)
        Observable<Int64>.iterable([40000, 50000, 60000])
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                println(v)
                threads.add(Thread.currentThread)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testFixedAndImmediately")
            }
        }).withFixed(2).immediately()
        sleep(Duration.second * 5)
        var t = None<Thread>
        let i = AtomicInt64(0)
        var c = 0
        while(let someqt <- threads.tryRemove() && let Some(qt) <- someqt && i.fetchAdd(1) < 3){
            threads.add(qt)
            if(let Some(tt) <- t && refEq(tt, qt)){
                c++
            }
            t = qt
        }
        println('same threads: ${c}')
        if(c != 1){
            throw Exception('There must be two threads are same')
        }
    }
    @TestCase
    public func testMultiSyncObserver(): Unit {
        let i = AtomicInt64(4000)
        let onet = AtomicOptionReference<Thread>(None<Thread>)
        let twot = AtomicOptionReference<Thread>(None<Thread>)
        Observable<Int64>.iterable([4000,5000,6000], asyncCombined: false)
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                onet.store(Thread.currentThread)
                @Assert(i.load(), v)
                i.fetchAdd(1000)
                println('${v} one')
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testMultiObserver one")
            }
        }).subscribe(FuncObserver<Int64>().setNextFunc{v => 
            twot.store(Thread.currentThread)
            println('${v} two')
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testMultiObserver two")
            }
        }).immediately()
        sleep(Duration.second * 5)
        let sameThread = refEq(onet.load().getOrThrow(), twot.load().getOrThrow())
        @Assert(sameThread, true)
    }
    @TestCase
    public func testMultiAsyncObserver(): Unit {
        let i = AtomicInt64(4000)
        let onet = AtomicOptionReference<Thread>(None<Thread>)
        let twot = AtomicOptionReference<Thread>(None<Thread>)
        Observable<Int64>.iterable([4000,5000,6000], asyncCombined: true)
        .subscribe(FuncObserver<Int64>().setNextFunc{v => 
            synchronized(mutex){
                println('${v} one')
                onet.store(Thread.currentThread)
                @Assert(i.load(), v)
                i.fetchAdd(1000)
            }
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testMultiObserver one")
            }
        }).subscribe(FuncObserver<Int64>().setNextFunc{v => 
            twot.store(Thread.currentThread)
            println('${v} two')
        }.setCompleteFunc{
            synchronized(mutex){
                println("complete testMultiObserver two")
            }
        }).immediately()
        sleep(Duration.second * 5)
        let sameThread = refEq(onet.load().getOrThrow(), twot.load().getOrThrow())
        @Assert(sameThread, false)
    }
    @TestCase
    public func testSleep(){
        sleep(Duration.second * 5)
    }
}