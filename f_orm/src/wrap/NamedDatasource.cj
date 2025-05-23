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
        private let datasource: Datasource
    ) {
        if (!optionSpecified) {
            for ((k, v) in ORMConfig.getAllConfigs(driverName: driverName)) {
                setOption(k, v)
            }
        }
    }
    public static func new(driver: Driver): NamedDatasource {
        let driverName = driver.name
        let ds = match (driver.open(ORMConfig.getUrl(driverName: driverName), ORMConfig.getAllConfigTuples(driverName: driverName))) {
            case x: PooledDatasource => x
            case x where driver.preferredPooling => 
                let p = PooledDatasource(x)
                if (let Some(x) <- ORMConfig.getStdPoolConnectionTimeout(driverName: driverName)) {
                    p.connectionTimeout = x
                }
                if (let Some(x) <- ORMConfig.getStdPoolIdleTimeout(driverName: driverName)) {
                    p.idleTimeout = x
                }
                if (let Some(x) <- ORMConfig.getStdPoolKeepaliveTime(driverName: driverName)) {
                    p.keepaliveTime = x
                }
                if (let Some(x) <- ORMConfig.getStdPoolMaxLifeTime(driverName: driverName)) {
                    p.maxLifeTime = x
                }
                if (let Some(x) <- ORMConfig.getStdPoolMaxIdleSize(driverName: driverName)) {
                    p.maxIdleSize = x
                }
                if (let Some(x) <- ORMConfig.getStdPoolMaxSize(driverName: driverName)) {
                    p.maxSize = x
                }
                p
            case x => x
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
