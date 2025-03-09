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

public interface SqlNullableData<T> <: SqlData<Option<T>> where T <: Data<T> {}

extend<T> SqlNullableChar <: SqlNullableData<String> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?String {
        this.value
    }
}
extend<T> SqlNullableVarchar <: SqlNullableData<String> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?String {
        this.value
    }
}
extend<T> SqlNullableBinary <: SqlNullableData<Array<Byte>> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Array<Byte> {
        this.value
    }
}
extend<T> SqlNullableVarBinary <: SqlNullableData<Array<Byte>> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Array<Byte> {
        this.value
    }
}
extend<T> SqlNullableClob <: SqlNullableData<DataInputStream> {
    public func getData(): AnyData {
        this.getValue()
    }
    public func getValue(): ?DataInputStream {
        match (this.value) {
            case Some(s) => DataInputStream(s)
            case _ => None<DataInputStream>
        }
    }
}
extend<T> SqlNullableBlob <: SqlNullableData<DataInputStream> {
    public func getData(): AnyData {
        this.getValue()
    }
    public func getValue(): ?DataInputStream {
        match (this.value) {
            case Some(s) => DataInputStream(s)
            case _ => None<DataInputStream>
        }
    }
}
extend<T> SqlNullableBool <: SqlNullableData<Bool> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Bool {
        this.value
    }
}
extend<T> SqlNullableByte <: SqlNullableData<Int8> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Int8 {
        this.value
    }
}
extend<T> SqlNullableSmallInt <: SqlNullableData<Int16> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Int16 {
        this.value
    }
}
extend<T> SqlNullableInteger <: SqlNullableData<Int32> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Int32 {
        this.value
    }
}
extend<T> SqlNullableBigInt <: SqlNullableData<Int64> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Int64 {
        this.value
    }
}
extend<T> SqlNullableReal <: SqlNullableData<Float32> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Float32 {
        this.value
    }
}
extend<T> SqlNullableDouble <: SqlNullableData<Float64> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Float64 {
        this.value
    }
}
extend<T> SqlNullableDecimal <: SqlNullableData<Decimal> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Decimal {
        this.value
    }
}
extend<T> SqlNullableDate <: SqlNullableData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?DateTime {
        this.value
    }
}
extend<T> SqlNullableTime <: SqlNullableData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?DateTime {
        this.value
    }
}
extend<T> SqlNullableTimeTz <: SqlNullableData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?DateTime {
        this.value
    }
}
extend<T> SqlNullableTimestamp <: SqlNullableData<DateTime> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?DateTime {
        this.value
    }
}
extend<T> SqlNullableInterval <: SqlNullableData<Duration> {
    public func getData(): AnyData {
        this.value
    }
    public func getValue(): ?Duration {
        this.value
    }
}
