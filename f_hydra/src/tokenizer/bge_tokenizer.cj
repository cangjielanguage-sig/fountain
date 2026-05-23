package fountain::f_hydra

import std.collection.HashMap
import std.ffi.{CPointer, CString}
import std.fs.{exists, File}
import std.json.JSON
import fountain.f_hydra.tokenizer.tokenize_result.TokenizeResult
import fountain.f_hydra.ffi.ffi_check.FfiCheck

// Opaque C handle for tokenizers library (defined in tokenizers_bridge.rs)
@C
class TokenizerHandle {
    // opaque handle
}

// C FFI declarations for custom tokenizers bridge
@C foreign
func hf_tokenizer_from_file(path: CString): CPointer<TokenizerHandle>

@C foreign
func hf_tokenizer_encode(
    handle: CPointer<TokenizerHandle>,
    text: CString,
    add_special_tokens: Bool,
    out_ids: CPointer<UInt64>,
    out_ids_len: CPointer<Int64>,
    out_mask: CPointer<UInt64>,
    out_mask_len: CPointer<Int64>
): Int32

@C foreign
func hf_tokenizer_free(handle: CPointer<TokenizerHandle>): ()

// Shared tokenizer component for BGE-M3 inference.
// Uses HuggingFace Tokenizers C FFI via custom Rust wrapper.
public class BgeTokenizer {
    private let handle: CPointer<TokenizerHandle>
    private let clsTokenId: Int64
    private let padTokenId: Int64
    private let sepTokenId: Int64
    private let unkTokenId: Int64

    // Initialize tokenizer from tokenizer.json file.
    // Reads special token IDs from tokenizer_config.json.
    public init(tokenizerPath: String) {
        // Validate file exists
        if (!exists(File.new(tokenizerPath))) {
            throw Exception("Tokenizer file not found: ${tokenizerPath}")
        }

        // Load via FFI
        let rawHandle = unsafe { hf_tokenizer_from_file(tokenizerPath.toCString()) }
        if (rawHandle.isNull()) {
            throw Exception("Failed to load tokenizer from: ${tokenizerPath}")
        }
        this.handle = rawHandle

        // Read special token IDs from tokenizer_config.json
        let configDir = getDir(tokenizerPath)
        let configPath = "${configDir}/tokenizer_config.json"
        if (exists(File.new(configPath))) {
            let (clsId, padId, sepId, unkId) = readSpecialTokenIds(configPath)
            this.clsTokenId = clsId
            this.padTokenId = padId
            this.sepTokenId = sepId
            this.unkTokenId = unkId
        } else {
            // XLM-RoBERTa defaults as fallback
            this.clsTokenId = 0
            this.padTokenId = 1
            this.sepTokenId = 2
            this.unkTokenId = 3
        }
    }

    // Tokenize a text string.
    // Returns token IDs and attention mask for ONNX Runtime input.
    public func tokenize(text: String): TokenizeResult {
        let maxLen: Int64 = 8192
        let idsArr = Array<UInt64>(maxLen, 0u64)
        let maskArr = Array<UInt64>(maxLen, 0u64)
        var idsLen: Int64 = 0
        var maskLen: Int64 = 0

        let ret = unsafe {
            hf_tokenizer_encode(
                this.handle,
                text.toCString(),
                true,                           // add_special_tokens
                idsArr.toCPointer(),
                &idsLen,
                maskArr.toCPointer(),
                &maskLen
            )
        }
        if (ret != 0) {
            throw Exception("Tokenizer encode failed for text of length ${text.size}")
        }

        let inputIds = Array<Int64>(idsLen) {i => Int64(idsArr[i])}
        let attnMask = Array<Int64>(maskLen) {i => Int64(maskArr[i])}
        TokenizeResult(inputIds: inputIds, attnMask: attnMask, seqLen: idsLen)
    }

    // Special token IDs
    public func getClsTokenId(): Int64 { this.clsTokenId }
    public func getPadTokenId(): Int64 { this.padTokenId }
    public func getSepTokenId(): Int64 { this.sepTokenId }
    public func getUnkTokenId(): Int64 { this.unkTokenId }

    public func close() {
        unsafe { hf_tokenizer_free(this.handle) }
    }

    // Read special token IDs from tokenizer_config.json
    private static func readSpecialTokenIds(configPath: String): (Int64, Int64, Int64, Int64) {
        // Default XLM-RoBERTa values
        var clsId: Int64 = 0
        var padId: Int64 = 1
        var sepId: Int64 = 2
        var unkId: Int64 = 3
        // TODO(v0.2.0): parse JSON to read actual special token IDs
        (clsId, padId, sepId, unkId)
    }

    // Get directory from file path
    private static func getDir(path: String): String {
        let parts = path.split("/", removeEmpty: true)
        if (parts.size <= 1) { return "." }
        var dirParts = Array<String>(parts.size - 1) {i => parts[i]}
        "/" + dirParts.join("/")
    }
}
