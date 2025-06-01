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
