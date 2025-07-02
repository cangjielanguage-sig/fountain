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

import f_base.StringGenerator

abstract sealed class CaseFormat {
    /**
     * 首字母大写的驼峰
     */
    public static let Pascal: CaseFormat = PascalCaseFormat()
    /**
     * 首字母小写的驼峰
     */
    public static let Camel: CaseFormat = CamelCaseFormat()
    /**
     * 全小写按下划线分割
     */
    public static let LowerUnderScore: CaseFormat = LowerUnderScoreCaseFormat()
    /**
     * 全大写按下划线分割
     */
    public static let UpperUnderScore: CaseFormat = UpperUnderScoreCaseFormat()
    /**
     * 全小写按-分割
     */
    public static let LowerHyphen: CaseFormat = LowerHyphenCaseFormat()
    /**
     * 全大写按-分割
     */
    public static let UpperHyphen: CaseFormat = UpperHyphenCaseFormat()

    protected CaseFormat(protected let withDelimiter!: Bool) {}

    public func convert(text: String, format: CaseFormat): String {
        let builder = StringGenerator()
        let caseFormat = format.new()
        let withDelim = this.withDelimiter
        for (ch in text.runes()) {
            let delim = isDelimiter(ch)
            if (delim && withDelim) {
                caseFormat.convert(ch, delim, builder)
            } else if (delim) {
                caseFormat.delimiter(builder)
            } else {
                caseFormat.convert(ch, false, builder)
            }
        }
        builder.toString()
    }
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit
    protected func delimiter(builder: StringGenerator): Unit
    protected func isDelimiter(ch: Rune): Bool
    protected func new(): CaseFormat
}

class PascalCaseFormat <: CaseFormat {
    init() {
        super(withDelimiter: true)
    }
    private var sectionStart = true
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit {
        let c = if (builder.size == 0) {
            sectionStart = false
            ch.toAsciiUpperCase()
        } else if (delimiter || sectionStart) {
            sectionStart = false
            ch.toAsciiUpperCase()
        } else {
            ch.toAsciiLowerCase()
        }
        builder.append(c)
    }
    protected func isDelimiter(ch: Rune): Bool {
        ch.isAsciiUpperCase()
    }
    protected func new(): CaseFormat {
        PascalCaseFormat()
    }
    protected func delimiter(builder: StringGenerator): Unit {
        sectionStart = true
    }
}

class CamelCaseFormat <: CaseFormat {
    init() {
        super(withDelimiter: true)
    }
    private var sectionStart = true
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit {
        let c = if (builder.size == 0) {
            sectionStart = false
            ch.toAsciiLowerCase()
        } else if (delimiter || sectionStart) {
            sectionStart = false
            ch.toAsciiUpperCase()
        } else {
            ch.toAsciiLowerCase()
        }
        builder.append(c)
    }
    protected func isDelimiter(ch: Rune): Bool {
        ch.isAsciiUpperCase()
    }
    protected func new(): CaseFormat {
        CamelCaseFormat()
    }
    protected func delimiter(builder: StringGenerator): Unit {
        sectionStart = true
    }
}

class LowerUnderScoreCaseFormat <: CaseFormat {
    init() {
        super(withDelimiter: false)
    }
    private static const DELIMITER = r'_'
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit {
        if (builder.size == 0) {
            builder.append(ch.toAsciiLowerCase())
        } else if (delimiter) {
            this.delimiter(builder)
            builder.append(ch.toAsciiLowerCase())
        } else {
            builder.append(ch.toAsciiLowerCase())
        }
    }
    protected func delimiter(builder: StringGenerator): Unit {
        builder.append(DELIMITER)
    }
    protected func isDelimiter(ch: Rune): Bool {
        ch == DELIMITER
    }
    protected func new(): CaseFormat {
        this
    }
}

class UpperUnderScoreCaseFormat <: CaseFormat {
    init() {
        super(withDelimiter: false)
    }
    private static const DELIMITER = r'_'
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit {
        if (builder.size == 0) {
            builder.append(ch.toAsciiUpperCase())
        } else if (delimiter) {
            this.delimiter(builder)
            builder.append(ch.toAsciiUpperCase())
        } else {
            builder.append(ch.toAsciiUpperCase())
        }
    }
    protected func delimiter(builder: StringGenerator): Unit {
        builder.append(DELIMITER)
    }
    protected func isDelimiter(ch: Rune): Bool {
        ch == DELIMITER
    }
    protected func new(): CaseFormat {
        this
    }
}

class LowerHyphenCaseFormat <: CaseFormat {
    init() {
        super(withDelimiter: false)
    }
    private static const DELIMITER = r'-'
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit {
        if (builder.size == 0) {
            builder.append(ch.toAsciiLowerCase())
        } else if (delimiter) {
            this.delimiter(builder)
            builder.append(ch.toAsciiLowerCase())
        } else {
            builder.append(ch.toAsciiLowerCase())
        }
    }
    protected func delimiter(builder: StringGenerator): Unit {
        builder.append(DELIMITER)
    }
    protected func isDelimiter(ch: Rune): Bool {
        ch == DELIMITER
    }
    protected func new(): CaseFormat {
        this
    }
}

class UpperHyphenCaseFormat <: CaseFormat {
    init() {
        super(withDelimiter: false)
    }
    private static const DELIMITER = r'-'
    protected func convert(ch: Rune, delimiter: Bool, builder: StringGenerator): Unit {
        if (builder.size == 0) {
            builder.append(ch.toAsciiUpperCase())
        } else if (delimiter) {
            this.delimiter(builder)
            builder.append(ch.toAsciiUpperCase())
        } else {
            builder.append(ch.toAsciiUpperCase())
        }
    }
    protected func delimiter(builder: StringGenerator): Unit {
        builder.append(DELIMITER)
    }
    protected func isDelimiter(ch: Rune): Bool {
        ch == DELIMITER
    }
    protected func new(): CaseFormat {
        this
    }
}
