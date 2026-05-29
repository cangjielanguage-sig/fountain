package fountain::f_hydra

import std.fs.{exists, File}
import fountain.f_config.Config

// Engine configuration: reads all environment variables via f_config.
// All values have sensible defaults; validate() checks critical ranges.

public class HydraConfig {
    private init() {}

    // === Inference backend config ===

    public static func backendType(): String {
        Config.getString("hydra_backend") ?? "ort_cpu"
    }

    public static func modelPath(): String {
        Config.getString("hydra_model_path") ?? "./models/bge-m3-onnx/model.onnx"
    }

    public static func modelHash(): ?String {
        Config.getString("hydra_model_hash")
    }

    public static func tokenizerPath(): String {
        Config.getString("hydra_tokenizer_path") ?? "./models/tokenizer.json"
    }

    public static func numThreads(): Int64 {
        Config.getValue<Int64>("hydra_num_threads") ?? 4
    }

    public static func enablePerfLog(): Bool {
        Config.getString("hydra_perf_log") == Some("true")
    }

    public static func libPath(): ?String {
        Config.getString("hydra_lib_path")
    }

    // === HNSW dense index config ===

    public static func hnswM(): Int64 {
        Config.getValue<Int64>("hydra_hnsw_m") ?? 64
    }

    public static func hnswEfConstruction(): Int64 {
        Config.getValue<Int64>("hydra_hnsw_ef_construction") ?? 400
    }

    public static func hnswEfSearch(): Int64 {
        Config.getValue<Int64>("hydra_hnsw_ef_search") ?? 200
    }

    // === Sparse index config ===

    public static func sparseUseSkipPointers(): Bool {
        Config.getString("hydra_sparse_skip_pointers") != Some("false")
    }

    // === ColBERT index config ===

    public static func colbertK(): Int64 {
        Config.getValue<Int64>("hydra_colbert_k") ?? 150000
    }

    public static func colbertM(): Int64 {
        Config.getValue<Int64>("hydra_colbert_m") ?? 48
    }

    public static func colbertCentroidSearchWidth(): Int64 {
        Config.getValue<Int64>("hydra_colbert_centroid_search_width") ?? 16
    }

    // === Fusion config ===

    public static func fusionStrategy(): String {
        Config.getString("hydra_fusion_strategy") ?? "rrf"
    }

    // === Retrieval config ===

    public static func rerankDepth(): Int64 {
        Config.getValue<Int64>("hydra_rerank_depth") ?? 100
    }

    public static func coarseK(): Int64 {
        Config.getValue<Int64>("hydra_coarse_k") ?? 100
    }

    public static func searchTimeoutMs(): Int64 {
        Config.getValue<Int64>("hydra_search_timeout_ms") ?? 5000
    }

    // === Configuration validation ===
    // Returns list of error messages; empty list means valid.

    public static func validate(): Array<String> {
        var errors = ArrayList<String>()

        let modelFile = modelPath()
        if (!exists(File.new(modelFile))) {
            errors.add("Model file not found: ${modelFile}. Check fountain_hydra_model_path.")
        }

        let tokFile = tokenizerPath()
        if (!exists(File.new(tokFile))) {
            errors.add("Tokenizer file not found: ${tokFile}. Check fountain_hydra_tokenizer_path.")
        }

        let m = hnswM()
        if (m < 4 || m > 128) {
            errors.add("HNSW M must be in [4, 128], got ${m}")
        }

        let efC = hnswEfConstruction()
        if (efC < 10) {
            errors.add("HNSW efConstruction must be >= 10, got ${efC}")
        }

        let efS = hnswEfSearch()
        if (efS < 1) {
            errors.add("HNSW efSearch must be >= 1, got ${efS}")
        }

        let ck = colbertK()
        if (ck < 1 || ck > 1_000_000) {
            errors.add("ColBERT K must be in [1, 1000000], got ${ck}")
        }

        let nt = numThreads()
        if (nt < 1 || nt > 256) {
            errors.add("numThreads must be in [1, 256], got ${nt}")
        }

        errors
    }
}
