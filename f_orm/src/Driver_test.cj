/*
   Copyright (c) 2022 WuJingrun（吴京润）
   fountain is licensed under Mulan PSL v2.
   You can use this software according to the terms and conditions of the Mulan PSL v2.
   You may obtain a copy of Mulan PSL v2 at:
           http://license.coscl.org.cn/MulanPSL2
   THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
   See the Mulan PSL v2 for more details.
 */

package f_orm

public class DriverTest <: Driver {
    /**
     * 驱 动 名 称
     */
    public prop name: String {
        get() {
            "test"
        }
    }

    /**
     * 驱 动 版 本
     */
    public prop version: String {
        get() {
            "1.0.0"
        }
    }

    /**
     * 指 示 驱 动 程 序 是 否 与 连 接 池 亲 和 。
     * 如 果 否 ， 则 不 建 议 使 用 连 接 池 。
     * 比 如 sqlite 驱 动 连 接 池 化 的 收 益 不 明 显 ， 不 建 议 使 用 连 接 池
     */
    public prop preferredPooling: Bool {
        get() {
            false
        }
    }

    /**
     * 通 过 connectionString 和 选 项 打 开 数 据 源
     * 参 数 connectionString - 数 据 库 连 接 字 符 串
     * 参 数 opts - key,value 的 tuple 数 组 ， 打 开 数 据 源 的 选 项
     * 返 回 值 Datasource - 数 据 源 实 例
     */
    public func open(connectionString: String, opts: Array<(String, String)>): Datasource {
        DatasourceTest()
    }
}

public class DatasourceCreatorImpl <: DatasourceCreator {
    public func create(): NamedDatasource {
        let driver = DriverTest()
        NamedDatasource(true, driver.name, driver.open(""))
    }
}
