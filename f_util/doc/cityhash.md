## cityhash

@Frozen
public func cityHash(data: String): UInt128 
@Frozen
public func cityHash<T>(data: T): UInt128 where T <: ToString 
@Frozen
public func cityHash(data: Array<UInt8>): UInt128