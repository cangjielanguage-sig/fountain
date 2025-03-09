/*
    Copyright (c) [2022] [WuJingrun（吴京润）]
    fountain is licensed under Mulan PSL v2.
    You can use this software according to the terms and conditions of the Mulan PSL v2.
    You may obtain a copy of Mulan PSL v2 at:
            http://license.coscl.org.cn/MulanPSL2
    THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
    See the Mulan PSL v2 for more details.
 */
package f_orm.wrap

public class NamedDatasource <: Datasource & Resource {
    public NamedDatasource(
        optionSpecified: Bool,
        public let driverName: String,
        private var datasource: Datasource
    ) {
        if (!optionSpecified) {
            for (tuple in ORMConfig.instance.getAllConfigs(driverName: driverName)) {
                setOption(tuple[0], tuple[1])
            }
        }
    }
    public static func new(driver: Driver, needPool!: Bool = true): NamedDatasource {
        let cfg = ORMConfig.instance
        let driverName = driver.name
        let ds = match (driver.open(cfg.getUrl(driverName: driverName), cfg.getAllConfigs(driverName: driverName))) {
            case x: PooledDatasource => x
            case x where !needPool => x
            case x =>
                let p = PooledDatasource(x)
                if (let Some(x) <- cfg.getStdPoolConnectionTimeout(driverName: driverName)) {
                    p.connectionTimeout = x
                }
                if (let Some(x) <- cfg.getStdPoolIdleTimeout(driverName: driverName)) {
                    p.idleTimeout = x
                }
                if (let Some(x) <- cfg.getStdPoolKeepaliveTime(driverName: driverName)) {
                    p.keepaliveTime = x
                }
                if (let Some(x) <- cfg.getStdPoolMaxLifeTime(driverName: driverName)) {
                    p.maxLifeTime = x
                }
                if (let Some(x) <- cfg.getStdPoolMaxIdleSize(driverName: driverName)) {
                    p.maxIdleSize = x
                }
                if (let Some(x) <- cfg.getStdPoolMaxSize(driverName: driverName)) {
                    p.maxSize = x
                }
                for (tuple in cfg.getAllConfigs(driverName: driverName)) {
                    p.setOption(tuple[0], tuple[1])
                }
                p
        }
        NamedDatasource(true, driverName, ds)
    }

    public func connect(): Connection {
        ConnectionWrap(driverName, datasource.connect())
    }
    public func isClosed(): Bool {
        datasource.isClosed()
    }
    public func close(): Unit {
        datasource.close()
    }
    public func setOption(key: String, value: String): Unit {
        datasource.setOption(key, value)
    }
}
