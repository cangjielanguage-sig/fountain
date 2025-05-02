/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_data.path

internal class RegexFilter <: DataFilter {
    private let regex: Regex
    private let left: DataPath
    init(left: DataPath, regex: String){
        this.left = left
        this.regex = parseRegex(regex)
    }
    init(left: String, regex: String, solid: String){
        this(compilePath(left, solid), regex)
    }
    private static func parseRegex(regex: String){
        if(!regex.startsWith('/')){
            throw DataException('illegal regex ${regex}, regex must be format as /<REGEX>/ or /<REGEX>/i')
        }
        if(regex.endsWith('/')){
            regex[1 .. regex.size - 1].regex()
        }else if(regex.endsWith('/i')){
            regex[1 .. regex.size - 1].regex(flags: [IgnoreCase])
        }else{
            throw DataException('illegal regex ${regex}, regex must be format as /<REGEX>/ or /<REGEX>/i')
        }
    }
    public func check(data: Data){
        let d = match(left.get(data).next()){
            case Some(x) => x
            case _ => return false
        }
        match(d){
            case x: DataString => regex.matches(x.data)
            case _ => false
        }
    }
}