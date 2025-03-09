/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm.wrap

public import std.database.sql.*
public import std.math.numeric.*
import fountain.base.exception.UnreachableException

public interface SqlData<T> <: SqlAnyData where T <: Data<T> {
    func getValue(): T
}

extend<T> SqlChar <: SqlData<String> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): String {
        this.value
    }
}
extend<T> SqlVarchar <: SqlData<String> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): String {
        this.value
    }
}
extend<T> SqlBinary <: SqlData<Array<Byte>> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Array<Byte> {
        this.value
    }
}
extend<T> SqlVarBinary <: SqlData<Array<Byte>> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Array<Byte> {
        this.value
    }
}
extend<T> SqlClob <: SqlData<DataInputStream> {
    public func getData(): AnyData {
        getValue()
    }
    public func getValue(): DataInputStream {
        match (this.value) {
            case x: DataInputStream => x
            case x: InputStream => DataInputStream(this.value)
            case _ => throw UnreachableException()
        }
    }
}
extend<T> SqlBlob <: SqlData<DataInputStream> {
    public func getData(): AnyData {
        getValue()
    }
    public func getValue(): DataInputStream {
        DataInputStream(this.value)
    }
}
extend<T> SqlBool <: SqlData<Bool> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Bool {
        this.value
    }
}
extend<T> SqlByte <: SqlData<Int8> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Int8 {
        this.value
    }
}
extend<T> SqlSmallInt <: SqlData<Int16> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Int16 {
        this.value
    }
}
extend<T> SqlInteger <: SqlData<Int32> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Int32 {
        this.value
    }
}
extend<T> SqlBigInt <: SqlData<Int64> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Int64 {
        this.value
    }
}
extend<T> SqlReal <: SqlData<Float32> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Float32 {
        this.value
    }
}
extend<T> SqlDouble <: SqlData<Float64> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Float64 {
        this.value
    }
}
extend<T> SqlDecimal <: SqlData<Decimal>{
    public func getData(): AnyData{
        this.value
    }
    public func getValue(): Decimal {
        this.value
    }
}
extend<T> SqlDate <: SqlData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): DateTime {
        this.value
    }
}
extend<T> SqlTime <: SqlData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): DateTime {
        this.value
    }
}
extend<T> SqlTimeTz <: SqlData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): DateTime {
        this.value
    }
}
extend<T> SqlTimestamp <: SqlData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): DateTime {
        this.value
    }
}
extend<T> SqlInterval <: SqlData<Duration> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): Duration {
        this.value
    }
}
