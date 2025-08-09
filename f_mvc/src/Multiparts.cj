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
