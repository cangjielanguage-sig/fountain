package f_orm

public interface QueryMappersInit<T> where T <: QueryMappersInit<T> {
    static prop isSimpleData: Bool {
        get() {
            true
        }
    }
    static func queryMappers(): QueryMappers<T> {
        throw ORMException("not supported")
    }
}
extend<T> Option<T> <: QueryMappersInit<T> where T <: QueryMappersInit<T> {
    public static prop isSimpleData: Bool {
        get() {
            T.isSimpleData
        }
    }
    public static func queryMappers(): QueryMappers<T> {
        T.queryMappers()
    }
}
extend Int8 <: QueryMappersInit<Int8> {}
extend UInt8 <: QueryMappersInit<UInt8> {}
extend Int16 <: QueryMappersInit<Int16> {}
extend UInt16 <: QueryMappersInit<UInt16> {}
extend Int32 <: QueryMappersInit<Int32> {}
extend UInt32 <: QueryMappersInit<UInt32> {}
extend Int64 <: QueryMappersInit<Int64> {}
extend UInt64 <: QueryMappersInit<UInt64> {}
extend Float16 <: QueryMappersInit<Float16> {}
extend Float32 <: QueryMappersInit<Float32> {}
extend Float64 <: QueryMappersInit<Float64> {}
extend Rune <: QueryMappersInit<Rune> {}
extend String <: QueryMappersInit<String> {}
extend Bool <: QueryMappersInit<Bool> {}
extend Duration <: QueryMappersInit<Duration> {}
extend DateTime <: QueryMappersInit<DateTime> {}
extend<T> Array<T> <: QueryMappersInit<Array<T>> where T <: QueryMappersInit<T> {}
extend DataInputStream <: QueryMappersInit<DataInputStream> {}
