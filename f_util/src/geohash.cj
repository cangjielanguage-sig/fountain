/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_util

import std.convert.Parsable
import f_base.*
import f_util.exception.GeoHashException

public struct GeoHash <: Hashable & Equatable<GeoHash> & ToString & Parsable<GeoHash> {
    private static const MAX_LATITUDE: Float64 = 90.0
    private static const MIN_LATITUDE: Float64 = -90.0
    private static const MAX_LONGITUDE: Float64 = 180.0
    private static const MIN_LONGITUDE: Float64 = -180.0

    private GeoHash(public let hash: UInt64){}

    public static func encode(latitude: Float64, longitude: Float64): GeoHash {
        var lowlat = MIN_LATITUDE
        var highlat = MAX_LATITUDE
        var lowlng = MIN_LONGITUDE
        var highlng = MAX_LONGITUDE
        var h = 0u64
        var shift = 63
        while (shift >= 0) {
            let midlat = (highlat + lowlat) / 2.0
            let midlng = (highlng + lowlng) / 2.0
            h |= if(midlng >= longitude) {
                lowlng = midlng
                1 << shift
            }else{
                highlng = midlng
                0
            }
            shift--
            h |= if(midlat >= latitude) {
                lowlat = midlat
                1u64 << shift
            }else{
                highlat = midlat
                0u64
            }
            shift--
        }
        GeoHash(h)
    }
    public static func encode(coordinate: (Float64, Float64)): GeoHash {
        encode(coordinate[0], coordinate[1])
    }
    public func decode(): (Float64, Float64) {
        var lowlat = MIN_LATITUDE
        var highlat = MAX_LATITUDE
        var lowlng = MIN_LONGITUDE
        var highlng = MAX_LONGITUDE
        var lng = 0.0
        var lat = 0.0
        var mask = 1u64 << 63
        while(mask > 0) {
            lng = (lowlng + highlng) / 2.0
            if((mask & hash) == 0){
                highlng = lng
            }else{
                lowlng = lng
            }
            mask >>= 1
            lat = (lowlat + highlat) / 2.0
            if((mask & hash) == 0) {
                highlat = lat
            }else{
                lowlat = lat
            }
            mask >>= 1
        }
        (lng, lat)
    }
    public operator func ==(other: GeoHash): Bool {
        this.hash == other.hash
    }
    public func hashCode(): Int64 {
        this.hash.hashCode()
    }
    public func toString(){
        let gen = StringGenerator()
        for(shift in 62 ..= 0: -2) {
            gen.append((hash >> shift) & 3u64)
        }
        gen.toString()
    }
    public static func tryParse(hash: String): Option<GeoHash> {
        var lowlat = MIN_LATITUDE
        var highlat = MAX_LATITUDE
        var lowlng = MIN_LONGITUDE
        var highlng = MAX_LONGITUDE
        var lng = 0.0
        var lat = 0.0
        for(r in hash.runes()){
            lng = (lowlng + highlng) / 2.0
            lat = (lowlat + highlat) / 2.0
            match(r){
                case r'0' => (highlng, highlat) = (lng, lat)
                case r'1' => (highlng, lowlat) = (lng, lat)
                case r'2' => (lowlng, highlat) = (lng, lat)
                case r'3' => (lowlng, lowlat) = (lng, lat)
                case _ => return None<GeoHash>
            }
        }
        encode(lng, lat)
    }
    public static func parse(hash: String): GeoHash {
        tryParse(hash).getOrThrow{GeoHashException(hash)}
    }
}