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

class WSDataFrame <: ControllerFuncParam {
    protected func extract<T>(name: String, ctx: HttpContext, pattern: HttpRequestPathPatterns): ?T where T <: DataFields<T> {
        throw MVCException()
    }
    protected func extract<T>(frame: Array<Byte>): T where T <: DataFields<T>
}

@Annotation[target: [MemberFunction]]
public class WSTextFrame <: ControllerFuncParam {
    public const WSTextFrame(public let mediaType: String, public let charset!: Charset = Charsets.UTF8) {}
    
    protected func extract<T>(frame: Array<Byte>): ?T where T <: DataFields<T> {
        let data = charset.newDecoder().decode(frame)
        mediaType.toDataFields<T>(data)
    }
}

@Annotation[target: [MemberFunction]]
public class WSBinaryFrame <: ControllerFuncParam {
    public const WSBinaryFrame(public let mediaType: String) {}
    protected func extract<T>(frame: Array<Byte>): ?T where T <: DataFields<T> {
        mediaType.toDataFields<T>(frame)
    }
}