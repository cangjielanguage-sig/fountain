/*
Copyright (c) 2026 WuJingrun（吴京润）

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package fountain::fdbm.server

import fountain::f_config.Config
import fountain::f_protocol.default.ProtocolConfig

/** 测试进程的协议配置：`MessageID` 拒绝 `hostId == 0`，用例里先给一个合法主机号。 */
let testProtocolHostIdSetup: Unit = Config.set([(ProtocolConfig.protocol_hostId, 1)])

/**
 * 测试进程的客户端驱动注册名：集成夹具以 f_dbd 客户端身份连自己启动的 fdbm 服务，走公开入口 `dbdDriver()`，
 * 该入口按契约要求 `dbd_driverName`，未配置时抛 `DbdException(CONFIG)`。
 *
 * 取测试专用名：不能用 `mockdb` —— 同一进程里 f_mockdb 已把物理驱动注册成它，重名会让服务端取到代理驱动；
 * 也不用 `postgres` / `mysql` 这类真实方言名，避免与「方言驱动缺失应报 NO_DRIVER」的负向用例前提纠缠。
 */
let testDbdDriverNameSetup: Unit = Config.set([('dbd_driverName', 'testdialect')])
