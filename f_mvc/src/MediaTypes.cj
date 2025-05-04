/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_mvc

public class MediaTypes {
    private static let mediaTypes = ConcurrentHashMap<String, MediaType>()
    static init(){
        register(JsonMediaType.instance)
        register(MultipartMediaType.instance)
    }
    public static func register(mediaType: MediaType){
        mediaTypes[mediaType.mediaType] = mediaType
    }
    public static func parse(mediaType: String) {
        tryParse(mediaType).getOrThrow{MediaTypeException("${mediaType} is an illegal MediaType string")}
    }
    public static func tryParse(mediaType: String): ?MediaType {
        if (let Some(x) <- mediaTypes.get(mediaType)) {
            x
        } else {
            let idx = mediaType.indexOf(";") ?? -1
            let mt =
            if (idx > 0) {
                mediaType[0 .. idx]
            } else {
                mediaType
            }
            if (let Some(x) <- mediaTypes.get(mt)) {
                let new = x.clone(mediaType)
                if(x is TextMediaType) {
                    if(let Some(x) <- mediaTypes.putIfAbsent(mediaType, new)) {
                        x
                    } else {
                        new
                    }
                } else {
                    new
                }
            } else {
                None<MediaType>
            }
        }
    }
}
