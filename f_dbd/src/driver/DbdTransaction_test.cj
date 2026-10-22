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
package fountain::f_dbd.driver

import std.database.sql.*
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_dbd.common.{DbdErrorCode, UpdateResultPayload}

/** Step 3.9 `DbdTransaction`（设计 §5.8）：状态机、透传语句、savepoint 注入防护与结果集互斥。 */
@Test
public class DbdTransactionTest {

    /** 三个属性默认 `Unspecified`，可写，且只记录（`begin` 的 SQL 不随属性变化）。 */
    @TestCase
    public func propertiesAreRecordedNotTranslated(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let transaction = connection.createTransaction()
            @Assert(transaction.accessMode == TransactionAccessMode.Unspecified, true)
            @Assert(transaction.deferrableMode == TransactionDeferrableMode.Unspecified, true)
            @Assert(transaction.isoLevel == TransactionIsoLevel.Unspecified, true)
            transaction.accessMode = TransactionAccessMode.ReadWrite
            transaction.deferrableMode = TransactionDeferrableMode.Deferrable
            transaction.isoLevel = TransactionIsoLevel.Serializable
            @Assert(transaction.accessMode == TransactionAccessMode.ReadWrite, true)
            transaction.begin()
            match (sqlOf(stub.received(0))) {
                case Some(sql) => @Assert(sql.sql, 'begin')
                case None => @Assert(false, true)
            }
            transaction.commit()
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** `begin` 重复 → `TX_STATE`；未 `begin` 就 `commit` / `rollback` → `TX_STATE` 且不发包。 */
    @TestCase
    public func stateMachineIsEnforced(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let transaction = connection.createTransaction()
            @Assert(codeOf { transaction.commit() }, DbdErrorCode.TX_STATE)
            @Assert(codeOf { transaction.rollback() }, DbdErrorCode.TX_STATE)
            @Assert(stub.receivedCount(), 0)

            transaction.begin()
            @Assert(codeOf { transaction.begin() }, DbdErrorCode.TX_STATE)
            transaction.commit()
            transaction.begin() // commit 后可再次 begin
            transaction.rollback()
            @Assert(stub.receivedCount(), 4) // begin, commit, begin, rollback
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** T10：未 `begin` 就 save / rollback(name) / release → `TX_STATE`，且都不发包。 */
    @TestCase
    public func savepointsRequireActiveTransaction(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let transaction = connection.createTransaction()
            @Assert(codeOf { transaction.save('sp1') }, DbdErrorCode.TX_STATE)
            @Assert(codeOf { transaction.rollback('sp1') }, DbdErrorCode.TX_STATE)
            @Assert(codeOf { transaction.release('sp1') }, DbdErrorCode.TX_STATE)
            @Assert(stub.receivedCount(), 0)
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** savepoint 三兄弟透传成固定 SQL。 */
    @TestCase
    public func savepointsArePassedThrough(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let transaction = connection.createTransaction()
            transaction.begin()
            transaction.save('sp1')
            transaction.rollback('sp1')
            transaction.release('sp1')
            let requests = stub.allReceived()
            @Assert(requests.size, 4)
            let expected = ['begin', 'savepoint sp1', 'rollback to savepoint sp1', 'release savepoint sp1']
            var i: Int64 = 0
            while (i < expected.size) {
                match (sqlOf(requests[i])) {
                    case Some(sql) => @Assert(sql.sql, expected[i])
                    case None => @Assert(false, true)
                }
                i += 1
            }
            transaction.commit()
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** savepoint 名是拼进 SQL 的：只放行标识符，其余 `PROTOCOL` 且不发包。 */
    @TestCase
    public func savepointNameInjectionIsRejected(): Unit {
        let stub = StubFdbm(handler: {msg => resp(msg.id, data: UpdateResultPayload(0, 0))})
        let connection = connectTo(stub)
        try {
            let transaction = connection.createTransaction()
            transaction.begin()
            let before = stub.receivedCount()
            let illegal = ['', '1abc', 'bad name', 'a;b', 'a-b', 'a\'b']
            for (name in illegal) {
                @Assert(codeOf { transaction.save(name) }, DbdErrorCode.PROTOCOL)
                @Assert(codeOf { transaction.rollback(name) }, DbdErrorCode.PROTOCOL)
                @Assert(codeOf { transaction.release(name) }, DbdErrorCode.PROTOCOL)
            }
            @Assert(stub.receivedCount(), before)
            transaction.save('_ok_1')
            @Assert(stub.receivedCount(), before + 1)
            transaction.commit()
        } finally {
            connection.close()
            stub.close()
        }
    }

    /** 结果集未关闭时事务方法一律 `CURSOR_STATE` 且不发包。 */
    @TestCase
    public func transactionIsBlockedByOpenResult(): Unit {
        let script = QueryScript(twoColumnInfos(), [true])
        let stub = StubFdbm(handler: {msg => script.handler(msg)})
        let connection = connectTo(stub)
        try {
            let result = connection.prepareStatement('select id, name from t').query()
            let transaction = connection.createTransaction()
            let before = stub.receivedCount()
            @Assert(codeOf { transaction.begin() }, DbdErrorCode.CURSOR_STATE)
            @Assert(stub.receivedCount(), before)
            result.close()
            transaction.begin() // 关闭后正常
            @Assert(stub.receivedCount(), before + 2) // UNSUBSCRIBE + begin
            transaction.commit()
        } finally {
            connection.close()
            stub.close()
        }
    }
}
