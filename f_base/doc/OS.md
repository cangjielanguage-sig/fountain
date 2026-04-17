## OS
```cj
//操作系统
public enum OS <: Equatable<OS> & ToString & Hashable {
    | Linux
    | Windows
    | macOS
    | HarmonyOS
    public operator func ==(other: OS): Bool
    public prop isWindows: Bool
    public prop isLinux: Bool
    public prop isMacOS: Bool
    public prop isHarmonyOS: Bool
    public func toString(): String
    public static func valueOf(value: String): OS
    public func hashCode(): Int64
    //返回当前操作系统的实例
    public static prop current: OS
    //返回当前操作系统的换行符
    public prop nextLine: String
}
```
