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

public class ContentDispositionBuilder {
    ContentDispositionBuilder(private let cd: ContentDisposition) {}

    public prop attachment: ContentDispositionBuilder {
        get() {
            cd.setType(ContentDispositionType.attachment)
            this
        }
    }
    public prop inline: ContentDispositionBuilder {
        get() {
            cd.setType(ContentDispositionType.inline)
            this
        }
    }
    public prop formData: ContentDispositionBuilder {
        get() {
            cd.setType(ContentDispositionType.formData)
            this
        }
    }
    public func name(value: String): ContentDispositionBuilder {
        cd.setName(value)
        this
    }
    public func filename(value: String): ContentDispositionBuilder {
        cd.setFilename(value)
        this
    }
    public func size(value: Int64): ContentDispositionBuilder {
        cd.setSize(value)
        this
    }
    public func creationDate(value: DateTime): ContentDispositionBuilder {
        cd.setCreationDate(value)
        this
    }
    public func creationDate(value: String): ContentDispositionBuilder {
        cd.setCreationDate(value)
        this
    }
    public func modificationDate(value: String): ContentDispositionBuilder {
        cd.setModificationDate(value)
        this
    }
    public func readDate(value: String): ContentDispositionBuilder {
        cd.setReadDate(value)
        this
    }

    public func modificationDate(value: DateTime): ContentDispositionBuilder {
        cd.setModificationDate(value)
        this
    }
    public func readDate(value: DateTime): ContentDispositionBuilder {
        cd.setReadDate(value)
        this
    }
    public func build(): ContentDisposition {
        cd
    }
}
