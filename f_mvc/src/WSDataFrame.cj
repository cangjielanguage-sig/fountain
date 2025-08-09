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

abstract sealed class WSDataFrame <: ControllerFuncParam {
    public const WSDataFrame(protected let mediaType: String) {}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        throw MVCException()
    }
    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T>
}

@Annotation[target: [Parameter]]
public class WSTextFrame <: WSDataFrame {
    public const WSTextFrame(mediaType: String, public let charset!: String = 'utf-8') {
        super(mediaType)
    }

    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T> {
        let data = Charsets
            .forName(charset)
            .getOrThrow {MediaTypeException('charset ${charset} does not support')}
            .newDecoder()
            .decode(frame)
        if (mediaType == '') {
            if (let x: T <- data) {
                x
            } else {
                throw MediaTypeException('media type is not specified')
            }
        } else {
            MediaTypes.parse(mediaType).toDataFields<T>(data)
        }
    }
}

@Annotation[target: [Parameter]]
public class WSBinaryFrame <: WSDataFrame {
    public const WSBinaryFrame(mediaType: String) {
        super(mediaType)
    }
    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T> {
        if (mediaType == '') {
            if (let x: T <- frame) {
                x
            } else {
                throw MediaTypeException('media type is not specified')
            }
        } else {
            MediaTypes.parse(mediaType).toDataFields<T>(frame)
        }
    }
}
