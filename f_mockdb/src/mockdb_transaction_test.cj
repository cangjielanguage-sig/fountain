package fountain::f_mockdb

import std.unittest.*
import std.unittest.testmacro.*

/**
 * Tests for MOCKDB transaction and savepoint functionality:
 * begin/commit/rollback, exception simulation, savepoint operations
 */
@Test
public class MockDBTransactionTest {
    @TestCase
    public func testTransactionBeginCommit(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnBeginning = false
        MOCKDB.toThrowOnCommitting = false
        let tx = MockTransaction()
        tx.begin()
        tx.commit()
        @Assert(true)
    }

    @TestCase
    public func testTransactionRollback(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnRollbacking = false
        let tx = MockTransaction()
        tx.begin()
        tx.rollback()
        @Assert(true)
    }

    @TestCase
    public func testBeginThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnBeginning = true
        let tx = MockTransaction()
        try {
            tx.begin()
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testCommitThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnCommitting = true
        let tx = MockTransaction()
        try {
            tx.commit()
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testRollbackThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnRollbacking = true
        let tx = MockTransaction()
        tx.begin()
        try {
            tx.rollback()
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testSavepointOperations(): Unit {
        MOCKDB.clear()
        let tx = MockTransaction()
        tx.save('sp1')
        @Assert(true)
    }

    @TestCase
    public func testSavepointSaveThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnSavingSavePoint('sp1', true)
        let tx = MockTransaction()
        try {
            tx.save('sp1')
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testSavepointReleaseThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnReleasing('sp1', true)
        let tx = MockTransaction()
        tx.save('sp1')
        try {
            tx.release('sp1')
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testSavepointRollbackThrows(): Unit {
        MOCKDB.clear()
        MOCKDB.toThrowOnRollbackingSavePoint('sp1', true)
        let tx = MockTransaction()
        tx.save('sp1')
        try {
            tx.rollback('sp1')
            @Assert(false)
        } catch (e: MockDbException) {
            @Assert(true)
        }
    }

    @TestCase
    public func testTransactionAccessMode(): Unit {
        MOCKDB.clear()
        let tx = MockTransaction()
        @Assert(TransactionAccessMode.Unspecified, tx.accessMode)
        tx.accessMode = TransactionAccessMode.ReadWrite
        @Assert(TransactionAccessMode.ReadWrite, tx.accessMode)
    }

    @TestCase
    public func testTransactionDeferrableMode(): Unit {
        MOCKDB.clear()
        let tx = MockTransaction()
        @Assert(TransactionDeferrableMode.Unspecified, tx.deferrableMode)
        tx.deferrableMode = TransactionDeferrableMode.Deferrable
        @Assert(TransactionDeferrableMode.Deferrable, tx.deferrableMode)
    }

    @TestCase
    public func testTransactionIsoLevel(): Unit {
        MOCKDB.clear()
        let tx = MockTransaction()
        @Assert(TransactionIsoLevel.Unspecified, tx.isoLevel)
        tx.isoLevel = TransactionIsoLevel.ReadCommitted
        @Assert(TransactionIsoLevel.ReadCommitted, tx.isoLevel)
    }

    @TestCase
    public func testSavepointCheckGetters(): Unit {
        MOCKDB.clear()
        @Assert(false, MOCKDB.toThrowOnSavingSavePoint('unknown'))
        @Assert(false, MOCKDB.toThrowOnReleasing('unknown'))
        @Assert(false, MOCKDB.toThrowOnRollbackingSavePoint('unknown'))
        MOCKDB.toThrowOnSavingSavePoint('sp', true)
        @Assert(true, MOCKDB.toThrowOnSavingSavePoint('sp'))
        MOCKDB.toThrowOnReleasing('sp', true)
        @Assert(true, MOCKDB.toThrowOnReleasing('sp'))
        MOCKDB.toThrowOnRollbackingSavePoint('sp', true)
        @Assert(true, MOCKDB.toThrowOnRollbackingSavePoint('sp'))
    }
}
