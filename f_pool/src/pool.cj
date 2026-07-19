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

import fountain::f_pool.exception.PoolException

public interface ObjectManager<V> {
    func create(): V
    func check(value: V): Bool
    func destroy(value: V): Unit
    func clear(value: V): Unit {}
}
public class PoolBuilder<V> {
    private var mode: Mode = Mode.Fifo
    private var initSize: Int64 = 0
    private var minSize: Int64 = 0
    private var maxSize: Int64 = 10
    private var idleTimeout: Duration = Duration.hour
    private var checkOnCreation: Bool = false
    private var checkOnBorrowing: Bool = true
    private var checkOnReturning: Bool = true
    private var clearOnReturning: Bool = false
    private var checkInterval: Duration = Duration.minute
    private var creator: ?() -> V = None
    private var checker: ?(V) -> Bool = None
    private var destroier: ?(V) -> Unit = None
    private var clear: (V) -> Unit = {_ =>}

    init(){}
    public func setMode(mode: Mode): This {
        this.mode = mode
        this
    }
    public func setInitSize(initSize: Int64): This {
        this.initSize = initSize
        this
    }
    public func setMinSize(minSize: Int64): This {
        this.minSize = minSize
        this
    }
    public func setMaxSize(maxSize: Int64): This {
        this.maxSize = maxSize
        this
    }
    public func setIdleTimeout(idleTimeout: Duration): This {
        this.idleTimeout = idleTimeout
        this
    }
    public func setCheckOnCreation(checkOnCreation: Bool): This {
        this.checkOnCreation = checkOnCreation
        this
    }
    public func setCheckOnBorrowing(checkOnBorrowing: Bool): This {
        this.checkOnBorrowing = checkOnBorrowing
        this
    }
    public func setCheckOnReturning(checkOnReturning: Bool): This {
        this.checkOnReturning = checkOnReturning
        this
    }
    public func setClearOnReturning(clearOnReturning: Bool): This {
        this.clearOnReturning = clearOnReturning
        this
    }
    public func setCheckInterval(checkInterval: Duration): This {
        this.checkInterval = checkInterval
        this
    }
    public func setCreator(creator: () -> V): This {
        this.creator = creator
        this
    }
    public func setChecker(checker: (V) -> Bool): This {
        this.checker = checker
        this
    }
    public func setDestroier(destroier: (V) -> Unit): This {
        this.destroier = destroier
        this
    }
    public func setClear(clear: (V) -> Unit): This {
        this.clear = clear
        this
    }
    public func setManager(manager: ObjectManager<V>): This {
        setCreator(manager.create)
        setChecker(manager.check)
        setDestroier(manager.destroy)
        setClear(manager.clear)
        this
    }
    public func build(): Pool<V> {
        func toThrow(){
            throw PoolException('creator, checker and destroier must be set.')
        }
        Pool<V>(
            mode: mode,
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            idleTimeout: idleTimeout,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            clearOnReturning: clearOnReturning,
            checkInterval: checkInterval,
            creator: creator ?? toThrow(),
            checker: checker ?? toThrow(),
            destroier: destroier ?? toThrow(),
            clear: clear)
    }
}
public struct Pool<V> <: Resource {
    private let pool: KeyPool<Unit, V>

    public init(
        mode!: Mode = Mode.Fifo,
        initSize!: Int64,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        clearOnReturning!: Bool = false,
        checkInterval!: Duration = Duration.minute,
        creator!: () -> V,
        checker!: (V) -> Bool,
        destroier!: (V) -> Unit,
        clear!: (V) -> Unit = {_ =>}
    ) {
        pool = KeyPool<Unit, V>(
            mode: mode,
            initKeys: InitKeyIterator(initSize).next,
            minSize: minSize,
            maxSize: maxSize,
            totalSize: maxSize,
            idleTimeout: idleTimeout,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            clearOnReturning: clearOnReturning,
            checkInterval: checkInterval,
            creator: {_ => creator()},
            checker: {_, v => checker(v)},
            destroier: {_, v => destroier(v)}
        )
    }
    public init(
        mode!: Mode = Mode.Fifo,
        initSize!: Int64,
        minSize!: Int64 = 0,
        maxSize!: Int64 = 10,
        idleTimeout!: Duration = Duration.hour,
        checkOnCreation!: Bool = false,
        checkOnBorrowing!: Bool = true,
        checkOnReturning!: Bool = true,
        clearOnReturning!: Bool = false,
        checkInterval!: Duration = Duration.minute,
        manager!: ObjectManager<V>
    ){
        this(
            mode: mode,
            initSize: initSize,
            minSize: minSize,
            maxSize: maxSize,
            idleTimeout: idleTimeout,
            checkOnCreation: checkOnCreation,
            checkOnBorrowing: checkOnBorrowing,
            checkOnReturning: checkOnReturning,
            clearOnReturning: clearOnReturning,
            checkInterval: checkInterval,
            creator: manager.create,
            checker: manager.check,
            destroier: manager.destroy,
            clear: manager.clear
        )
    }
    public static func builder(): PoolBuilder<V> {
        PoolBuilder<V>()
    }
    public func isClosed(): Bool {
        pool.isClosed()
    }
    public func close(): Unit {
        pool.close()
    }
    public func get(timeout!: Duration = Duration.Max): ?V {
        pool.get((), timeout: timeout)
    }
    public func giveBack(value: V): Unit {
        pool.giveBack((), value)
    }
}
private class InitKeyIterator <: Iterator<Unit> {
    private var i = 0
    InitKeyIterator(private let initSize: Int64){}
    public func next(): ?Unit {
        if(i < initSize){
            i++
            ()
        }else{
            None
        }
    }
}