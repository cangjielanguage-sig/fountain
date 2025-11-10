/*
Copyright (c) 2025 WuJingrun（吴京润）

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
package f_orm.wrap

public class NamedDatasource <: Datasource & Resource {
    public NamedDatasource(
        optionSpecified: Bool,
        public let driverName: String,
        private let datasource: Datasource
    ) {
        if (!optionSpecified) {
            for ((k, v) in ORMConfig.getAllConfigs(driverName: driverName) where k.contains('_option_')) {
                setOption(k[k.indexOf('_option_').getOrThrow() + '_option_'.size .. ], v)
            }
        }
    }
    public static func new(driver: Driver, url: String, options: Array<(String, String)>){
        let driverName = driver.name
        let ds = match (driver.open(url, options)) {
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
        NamedDatasource(options.size > 0, driverName, ds)
    }
    private static func getUrl(driver: Driver){
        ORMConfig.getUrl(driverName: driver.name)
    }
    private static func getOptions(driver: Driver){
        ORMConfig.getAllConfigTuples(driverName: driver.name)
    }
    public static func new(driver: Driver, options: Array<(String ,String)>): NamedDatasource {
        new(driver, getUrl(driver), options)
    }
    public static func new(driver: Driver, url: String){
        new(driver, url, getOptions(driver))
    }
    public static func new(driver: Driver){
        let driverName = driver.name
        new(driver, getUrl(driver), getOptions(driver))
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
