## geohash
```cj
public struct GeoHash <: Hashable & Equatable<GeoHash> & ToString & Parsable<GeoHash> & DataParsable<GeoHash> {
    /**初始化geohash*/
    public static func encode(latitude: Float64, longitude: Float64): GeoHash
    /**
     * GeoHash.encode(coordinate[0], coordinate[1])
     */
    public static func encode(coordinate: (Float64, Float64)): GeoHash
    /**从geohash反向计算经伟度，返回的元组是(longitude, latitude)*/
    public func decode(): (Float64, Float64)
    public operator func ==(other: GeoHash): Bool
    public func hashCode(): Int64
    /**把geohash转成4进制*/
    public func toString(): String 
    /**把四进制字符串转成GeoHash*/
    public static func tryParse(hash: String): Option<GeoHash>
    /**把四进制字符串转成GeoHash*/
    public static func parse(hash: String): GeoHash
}
```
