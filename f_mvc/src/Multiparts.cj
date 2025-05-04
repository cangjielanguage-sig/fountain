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

public class Multiparts<T> where T <: InputStream {
    private let files = HashMap<String, Multipart>()
    private var form_ = Form()
    private let medias = HashMap<MediaType, MultipartMedia>()

    func setForm(form: Form){
        this.form_ = form
    }
    public prop form: Form {
        get() {
            form_
        }
    }

    func add(media: MultipartMedia) {
        medias[media.mediaType] = media
    }
    public func get(mediaType: MediaType) {
        medias.get(mediaType)
    }

    func add<P>(part: P) where P <: Multipart {
        if(part is MultipartFile<T> || part is MultipartMixed<T>) {
            files[part.name] = part
        } else {
            throw MultipartFormDataException("${part.name} must be multipart/form-data, name=xxx or multipart/mixed")
        }
    }
    public func getFile<P>(name: String): ?P where P <: Multipart {
        match(files.get(name)) {
            case Some(x) => x as P
            case _ => None
        }
    }
    public func get(name: String): ?Multipart {
        files.get(name)
    }
    public func allFiles(): Iterator<(String, Multipart)> {
        files.iterator()
    }
    public func allMedias(): Collection<MultipartMedia> {
        medias.values()
    }
}
