package fountain::f_hydra

public struct BackendConfig {
    public let tokenizerPath: String
    public let modelPath: String
    public let numThreads: Int64
    public let enablePerfLog: Bool
    public let onnxLibPath: ?String
}
