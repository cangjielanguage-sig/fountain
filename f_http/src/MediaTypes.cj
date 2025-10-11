/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_http

public class MediaTypes {
    private static let mediaTypes = ConcurrentHashMap<String, MediaType>()
    static init() {
        register(JsonMediaType.instance)
        register(MultipartMediaType.instance)
        register(PlainTextMediaType.instance)
        registerFromBeanFactory()
    }
    public static func register(mediaType: MediaType) {
        mediaTypes[mediaType.mediaType] = mediaType
    }
    public static func parse(mediaType: String) {
        tryParse(mediaType).getOrThrow {MediaTypeException("${mediaType} is an illegal MediaType string")}
    }
    private static func registerFromBeanFactory() {
        register(BeanFactory.instance.getList<MediaType>())
    }
    private static func register(mediaTypes: ArrayList<MediaType>) {
        for (m in mediaTypes) {
            register(m)
        }
    }
    public static func tryParse(mediaType: String): ?MediaType {
        if (let Some(x) <- mediaTypes.get(mediaType)) {
            x
        } else {
            let idx = mediaType.indexOf(";") ?? -1
            let mt = if (idx > 0) {
                mediaType[0..idx]
            } else {
                mediaType
            }
            if (let Some(x) <- mediaTypes.get(mt)) {
                x
            } else if (let list <- BeanFactory.instance.getList<MediaType>() && list.size > 0) {
                register(list)
                tryParse(mediaType)
            } else {
                None<MediaType>
            }
        }?.make(mediaType)
    }
}
