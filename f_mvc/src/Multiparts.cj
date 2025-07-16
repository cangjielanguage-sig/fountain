/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_mvc

public class Multiparts {
    private let files = HashMap<String, Multipart>()
    private var form_ = ('', Form())
    private let medias = HashMap<String, ArrayList<MultipartMedia>>()

    func setForm(name: String, form: Form) {
        this.form_ = (name, form)
    }
    public prop form: (String, Form) {
        get() {
            form_
        }
    }

    func get(name: String): ?Any {
        if (let Some(x) <- files.get(name)) {
            x
        } else if (form[0] == name) {
            form[1]
        } else if (let Some(x) <- medias.get(name)) {
            x
        } else {
            None<Any>
        }
    }
    func add(media: MultipartMedia) {
        match (medias
            .get(media.name)) {
                case Some(x) => x
                case _ =>
                    let l = ArrayList<MultipartMedia>()
                    medias[media
                        .name] = l
                    l
            }
            .add(media)
    }
    public func getMedias(name: String) {
        medias.get(name)
    }

    func add<P>(part: P) where P <: Multipart {
        if (part is MultipartFile || part is MultipartMixed) {
            files[part.name] = part
        } else {
            throw MultipartFormDataException("${part.name} must be multipart/form-data, name=<NAME> or multipart/mixed")
        }
    }
    public func getFile(name: String): ?Multipart {
        files.get(name)
    }
    public func allFiles(): Iterator<(String, Multipart)> {
        files.iterator()
    }
    public func allMedias(): Collection<MultipartMedia> {
        medias.values().iterator().flatten<MultipartMedia>().fold(ArrayList<MultipartMedia>()) {
            acc, x =>
            acc.add(x)
            acc
        }
    }
}
