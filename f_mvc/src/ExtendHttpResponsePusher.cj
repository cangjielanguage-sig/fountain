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

public interface ExtendHttpResponsePusher {
    func push(path: String, method: RequestMethod, header: HttpHeaders): Unit 
}

extend HttpResponsePusher <: ExtendHttpResponsePusher {
    public func push(path: String, method: RequestMethod, header: HttpHeaders): Unit {
        push(path, method.toString(), header)
    }
}