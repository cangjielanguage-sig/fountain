/*
    Copyright (c) 2022 WuJingrun（吴京润）
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.  
*/
package f_mvc

/**
 * 如果需要主动向客户端写应为被@OnWSOpen注解的函数声明WebSocket参数并设法保持此WebSocket实例。
 * WSMeta提供了几个静态写函数用于辅助向客户端写。
 */
@Annotation[target:[MemberFunction]]
public class  OnWSOpen {
    public const init(){}
}