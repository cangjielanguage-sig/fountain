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
package fountain::fsync.exception

import fountain::f_base.BaseException

/** sync_hosts 配置缺失 */
public class InvalidConfigException <: BaseException {
    public init(msg: String) {
        super(msg)
    }
}

/** 客户端写入操作失败（add / delete） */
public class WriteFailedException <: BaseException {
    public init(key: String) {
        super('write failed for key: ${key}')
    }
}

/** KEY 不是绝对路径格式 */
public class InvalidKeyException <: BaseException {
    public init(key: String) {
        super('key must be an absolute path starting with /, but got: ${key}')
    }
}
