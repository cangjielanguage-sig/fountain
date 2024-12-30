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

internal class AvgPathNode <: DataPathNode {
    static let instance = AvgPathNode()
    private init(){}
    public func get(data: Data): Iterator<Data> {
        match(data){
            case x: DataSequence => 
                var r = Decimal.ZERO
                var c = 0
                for(v in x){
                    match(v){
                        case x: DataReal => 
                            c++
                            r += x.data
                        case _ => return OptionIterator<Data>.NONE
                    }
                }
                OptionIterator<Data>((r/Decimal(BigInt(c))).toData())
            case _ => OptionIterator<Data>.NONE                
        }
    }
}