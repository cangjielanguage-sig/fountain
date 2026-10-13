// SPDX-License-Identifier: Apache-2.0
package fountain::f_orm.orm_test

import std.math.numeric.Decimal
import std.unittest.*
import std.unittest.testmacro.*
import fountain::f_orm.*
import fountain::f_orm.macros.*

@DatabaseSchema[driver: 'postgres', database: 'postgres']
@QueryMappersGenerator['annotated_mapping_sample']
public class AnnotatedMappingSample {
    private var storedKey: String = ''
    private var storedAmount: Decimal = Decimal.parse('0')

    @ColumnSchema[typeName: 'varchar(80)']
    @ORMField[true 'entity_key']
    public mut prop key: String {
        get() { storedKey }
        set(value) { storedKey = value }
    }

    @ColumnSchema[typeName: 'numeric(30,8)']
    @ORMField['amount']
    public mut prop amount: Decimal {
        get() { storedAmount }
        set(value) { storedAmount = value }
    }

    public init() {}
}

@Test
public class AnnotatedQueryMappersTest {
    @TestCase
    public func testAnnotatedPropertiesKeepColumnMetadata(): Unit {
        let meta = TableMeta.new<AnnotatedMappingSample>()
        @Assert(2, meta.columns.size)
        var foundKey = false
        var foundAmount = false
        for (column in meta.columns) {
            if (column.columnName == 'entity_key') {
                @Assert('varchar(80)', column.typeName)
                foundKey = true
            }
            if (column.columnName == 'amount') {
                @Assert('numeric(30,8)', column.typeName)
                foundAmount = true
            }
        }
        @Assert(foundKey)
        @Assert(foundAmount)
        var count = 0
        for (_ in AnnotatedMappingSample.tableColumns()) {
            count++
        }
        @Assert(2, count)
    }
}
