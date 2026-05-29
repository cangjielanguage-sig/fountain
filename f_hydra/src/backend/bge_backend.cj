package fountain::f_hydra

import std.collection.HashMap
import fountain.f_hydra.backend.bge_output.BgeOutput

public struct BackendCapabilities {
    public let supportsDense: Bool
    public let supportsSparse: Bool
    public let supportsColBERT: Bool
    public let supportsBatch: Bool
    public let hardwareName: String
}

public struct BackendInfo {
    public let name: String
    public let version: String
    public let capabilities: BackendCapabilities
}

public interface BgeBackend {
    func encode(text: String): BgeOutput
    func encodeBatch(texts: Array<String>): Array<BgeOutput>
    func warmup()
    func isReady(): Bool
    func backendInfo(): BackendInfo
    func close()
}
