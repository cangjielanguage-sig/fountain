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

public class MultipartMixed <: Multipart & Iterable<MultipartFile> {
    private let parts = ArrayList<MultipartFile>()

    public init(contentDisposition: ContentDisposition) {
        super(contentDisposition)
    }
    public init(
        contentDisposition: ContentDisposition,
        files: Multiparts
    ) {
        super(contentDisposition)
        addAll(files)
    }

    public func add(file: MultipartFile) {
        parts.add(file)
    }
    public func addAll<C>(files: C) where C <: Collection<MultipartFile> {
        parts.add(all: files)
    }
    public func addAll(files: Multiparts) {
        for (file in files.allFiles()) {
            match (file) {
                case f: MultipartFile => add(f)
                case _ => continue
            }
        }
    }
    public func iterator(): Iterator<MultipartFile> {
        parts.iterator()
    }
}
