/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
*/
package f_bean

public class RingChecker {
    private let map = TreeMap<BeanManager, Int64>()
    private let list = ArrayList<BeanManager>()
    RingChecker(var forOn!: Bool = true){}
    func put(manager: BeanManager){
        list.add(manager)
        if(map.contains(manager)){
            let ringStr = StringBuilder()
            var i = map[manager]
            while(i < list.size) {
                if(i > 0){
                    ringStr.append(">>")
                }
                ringStr.append(manager.name)
                i++
            }
            let purpose = if(forOn){
                "for bean initialization condition"
            }else{
                "for bean initialization dependency"
            }
            throw BeanException("there is at least one ring in f_bean.BeanFactory ${purpose}: ${ringStr}")
        }else{
            map.add(manager, list.size - 1)
        }
    }
    func remove(manager: BeanManager){
        if(let Some(idx) <- map.remove(manager)){
            list.remove(at: idx)
        }
    }
    func clear(){
        map.clear()
        list.clear()
    }
}
