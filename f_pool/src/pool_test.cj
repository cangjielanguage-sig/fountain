package f_pool

import std.unittest.*
import std.unittest.testmacro.*

public class Test {
    var valid = true
    func destroy(): Unit {
        println('destroy ${valid}')
    }
}

@Test
public class PoolTest{
    @TestCase
    public func test0(): Unit {
        let pool = Pool<Test>(initSize:1, 
                        minSize: 1,
                        maxSize: 2,
                        elementLife: Duration.second * 10,
                        checkInterval: Duration.second,
                        creator: { => Test()},
                        checker: {x: Test => x.valid},
                        destroier:{x => x.destroy()})
        sleep(Duration.millisecond)
        let o1 = pool.borrow(timeout: Duration.Zero)
        let o2 = pool.borrow(timeout: Duration.second)
        @Assert(o1.isSome(),true)
        @Assert(o2.isSome(),true)
        let o3 = pool.borrow(timeout: Duration.millisecond)
        @Assert(o3.isNone(),true)
        pool.giveBack(o2.getOrThrow())
        let o4 = pool.borrow(timeout: Duration.second)
        @Assert(o4.isSome(),true)
        pool.giveBack(o1.getOrThrow())
        sleep(Duration.second * 10)
        let o5 = pool.borrow(timeout: Duration.Zero)
        @Assert(o5.isSome(),true)
        pool.giveBack(o5.getOrThrow())
        o5.getOrThrow().valid = false
        sleep(Duration.millisecond)

    }
}