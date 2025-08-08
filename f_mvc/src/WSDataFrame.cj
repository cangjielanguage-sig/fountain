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

sealed abstract class WSDataFrame <: ControllerFuncParam {
    public const init(){}
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        throw MVCException()
    }
    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T>
}

@Annotation[target: [MemberFunction]]
public class WSTextFrame <: WSDataFrame {
    public const WSTextFrame(public let mediaType: String, public let charset!: String = 'utf-8') {}
    
    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T> {
        let data = Charsets.forName(charset).getOrThrow{MediaTypeException('charset ${charset} does not support')}.newDecoder().decode(frame)
        MediaTypes.parse(mediaType).toDataFields<T>(data)
    }
}

@Annotation[target: [MemberFunction]]
public class WSBinaryFrame <: WSDataFrame {
    public const WSBinaryFrame(public let mediaType: String) {}
    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T> {
        MediaTypes.parse(mediaType).toDataFields<T>(frame)
    }
}