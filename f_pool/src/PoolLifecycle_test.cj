// SPDX-License-Identifier: Apache-2.0
package fountain::f_pool

import std.sync.{AtomicBool, AtomicInt64}
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PoolLifecycleTest {
    private func waitFlag(flag: AtomicBool): Unit {
        let start = MonoTime.now()
        while (!flag.load() && MonoTime.now() - start < Duration.second * 3) {
            sleep(Duration.millisecond)
        }
        if (!flag.load()) {
            throw Exception('pool test callback did not reach the barrier')
        }
    }

    @TestCase
    public func testZeroIdleTimeoutDoesNotExpire(): Unit {
        let zero = Ref<Object>(Some(Object()), Duration.Zero, {_ => ()})
        let positive = Ref<Object>(Some(Object()), Duration.millisecond, {_ => ()})
        sleep(Duration.millisecond * 5)
        @Assert(false, zero.isIdleTimeout())
        @Assert(true, positive.isIdleTimeout())
        zero.take()
        positive.take()
    }

    private func returnedWhileCreating(unbounded: Bool): Unit {
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let creations = AtomicInt64(0)
        let destroyed = AtomicInt64(0)
        let first = Object()
        let pool = Pool<Object>(initSize: 0, maxSize: 2,
            checkOnBorrowing: false, checkOnReturning: false, checkInterval: Duration.Zero,
            maxWaiting: Duration.Max,
            creator: {=>
                if (creations.fetchAdd(1) == 0) {
                    first
                } else {
                    entered.store(true)
                    waitFlag(release)
                    Object()
                }
            }, checker: {_ => true}, destroier: {_ => destroyed.fetchAdd(1); ()})
        let held = pool.get(timeout: Duration.second * 2).getOrThrow()
        let borrower = spawn {=>
            pool.get(timeout: if (unbounded) { Duration.Max } else { Duration.second * 2 })
        }
        var heldReturned = false
        var borrowedReturned = false
        try {
            waitFlag(entered)
            pool.giveBack(held)
            heldReturned = true
            let value = borrower.get(Duration.second).getOrThrow()
            let same = refEq(value, first)
            pool.giveBack(value)
            borrowedReturned = true
            @Assert(same)
            @Assert(false, release.load())
        } finally {
            pool.close()
            release.store(true)
            if (!heldReturned) {
                pool.giveBack(held)
            }
            if (!borrowedReturned) {
                if (let Some(value) <- borrower.get(Duration.second * 2)) {
                    pool.giveBack(value)
                }
            }
            @Assert(pool.awaitTermination(timeout: Duration.second * 2))
        }
        @Assert(2, destroyed.load())
    }

    @TestCase
    public func testFiniteBorrowerReceivesReturnedObjectWhileCreatorIsBlocked(): Unit {
        returnedWhileCreating(false)
    }

    @TestCase
    public func testInfiniteBorrowerReceivesReturnedObjectWhileCreatorIsBlocked(): Unit {
        returnedWhileCreating(true)
    }

    @TestCase
    public func testFailedCreationBacksOffAndCloseWakesRetry(): Unit {
        let calls = AtomicInt64(0)
        let pool = Pool<Object>(initSize: 0, maxSize: 1,
            checkOnBorrowing: false, checkOnReturning: false, checkInterval: Duration.Zero,
            creator: {=> calls.fetchAdd(1); throw Exception('expected creation failure')},
            checker: {_ => true}, destroier: {_ => ()})
        try {
            @Assert(pool.get(timeout: Duration.millisecond * 250).isNone())
            @Assert(calls.load() >= 1 && calls.load() <= 4)
        } finally {
            pool.close()
            @Assert(pool.awaitTermination(timeout: Duration.second))
        }
    }

    @TestCase
    public func testTerminationTimeoutCanBeRetriedAfterCreatorReturns(): Unit {
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let destroyed = AtomicInt64(0)
        let pool = Pool<Object>(initSize: 1, maxSize: 1,
            checkOnBorrowing: false, checkOnReturning: false, checkInterval: Duration.hour,
            creator: {=> entered.store(true); waitFlag(release); Object()},
            checker: {_ => true}, destroier: {_ => destroyed.fetchAdd(1); ()})
        try {
            waitFlag(entered)
            pool.close()
            @Assert(false, pool.awaitTermination(timeout: Duration.millisecond * 30))
            @Assert(0, destroyed.load())
        } finally {
            release.store(true)
            pool.close()
            @Assert(pool.awaitTermination(timeout: Duration.second * 2))
        }
        @Assert(1, destroyed.load())
        pool.close()
        @Assert(pool.awaitTermination(timeout: Duration.second))
        @Assert(1, destroyed.load())
    }
}
