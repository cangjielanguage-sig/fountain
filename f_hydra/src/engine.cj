package fountain::f_hydra

import std.sync.{Mutex, AtomicBool}
import std.time.{DateTime, Duration}
import fountain.f_hydra.backend.backend_factory.createBgeBackend
import fountain.f_hydra.backend.bge_backend.BgeBackend
import fountain.f_hydra.backend.bge_output.BgeOutput
import fountain.f_hydra.config.hydra_config.HydraConfig
import fountain.f_hydra.index.dense_indexer.DenseIndexer
import fountain.f_hydra.index.dense_retriever.DenseRetriever
import fountain.f_hydra.index.sparse_indexer.SparseIndexer
import fountain.f_hydra.index.sparse_retriever.SparseRetriever
import fountain.f_hydra.index.colbert_indexer.ColBERTIndexer
import fountain.f_hydra.index.colbert_retriever.ColBERTRetriever
import fountain.f_hydra.fusion.fusion_layer.FusionLayer
import fountain.f_hydra.fusion.scored_document.ScoredDocument

// Search result including ranked documents and latency
public class HybridSearchResult {
    public let results: Array<ScoredDocument>
    public let latency: Duration

    public init(results: Array<ScoredDocument>, latency: Duration) {
        this.results = results
        this.latency = latency
    }
}

// Top-level hybrid search engine.
// Assembles all components: backend, indexers, retrievers, fusion.
public class HybridSearchEngine {
    private let embedder: BgeBackend
    private let denseIndexer: DenseIndexer
    private let sparseIndexer: SparseIndexer
    private let colbertIndexer: ColBERTIndexer
    private let denseRetriever: DenseRetriever
    private let sparseRetriever: SparseRetriever
    private let colbertRetriever: ColBERTRetriever
    private let fusion: FusionLayer

    // Lifecycle control
    private let closing: AtomicBool

    public init() {
        // Step 1: Validate configuration
        let errors = HydraConfig.validate()
        if (errors.size > 0) {
            for (err in errors) {
                eprintln("[f_hydra] Config error: ${err}")
            }
            throw Exception("HybridSearchEngine: config validation failed (${errors.size} errors)")
        }

        // Step 2: Create inference backend
        this.embedder = createBgeBackend()
        let info = this.embedder.backendInfo()
        println("[f_hydra] Backend: ${info.name} v${info.version}, HW: ${info.capabilities.hardwareName}")

        // Step 3: Create indexers
        this.denseIndexer = DenseIndexer(
            dim: 1024,
            M: HydraConfig.hnswM(),
            efConstruction: HydraConfig.hnswEfConstruction()
        )
        this.sparseIndexer = SparseIndexer()
        this.colbertIndexer = ColBERTIndexer(dim: 1024)

        // Step 4: Create retrievers
        this.denseRetriever = DenseRetriever(
            indexer: this.denseIndexer,
            timeoutMs: HydraConfig.searchTimeoutMs()
        )
        this.sparseRetriever = SparseRetriever(indexer: this.sparseIndexer)
        this.colbertRetriever = ColBERTRetriever(indexer: this.colbertIndexer)

        // Step 5: Create fusion layer
        this.fusion = FusionLayer()

        // Step 6: Initialize lifecycle
        this.closing = AtomicBool(false)

        println("[f_hydra] Engine initialized: ${HydraConfig.backendType()}, threads=${HydraConfig.numThreads()}")
    }

    // Search: end-to-end pipeline.
    // 1. Encode query text → BgeOutput (dense, sparse, colbert vectors)
    // 2. Parallel dense + sparse coarse retrieval
    // 3. ColBERT rerank on merged candidate pool
    // 4. Fusion of all three result sets
    // Returns ranked results and total latency.
    public func search(query: String, topK: Int64): HybridSearchResult {
        if (this.closing.load()) {
            throw Exception("HybridSearchEngine: engine is closing")
        }

        let start = DateTime.now()

        // Step 1: Encode query
        let queryVec = this.embedder.encode(query)

        // Step 2: Parallel coarse retrieval (spawn for parallelism)
        let coarseK = HydraConfig.coarseK()

        // Run both in spawned threads for parallelism
        let denseFuture = spawn { => this.denseRetriever.search(queryVec.denseVec, coarseK) }
        let sparseFuture = spawn { => this.sparseRetriever.search(queryVec.sparseVec, coarseK) }

        // Collect results with timeout
        let timeoutMs = HydraConfig.searchTimeoutMs()
        let denseResults = try {
            denseFuture.get(Duration.millisecond * timeoutMs)
        } catch (e: Exception) {
            eprintln("[f_hydra] Dense search timeout after ${timeoutMs}ms")
            Array<ScoredDocument>()
        }

        let sparseResults = try {
            sparseFuture.get(Duration.millisecond * timeoutMs)
        } catch (e: Exception) {
            eprintln("[f_hydra] Sparse search timeout after ${timeoutMs}ms")
            Array<ScoredDocument>()
        }

        // Step 3: ColBERT rerank on merged candidate pool
        let rerankDepth = HydraConfig.rerankDepth()
        let colbertResults = try {
            this.colbertRetriever.search(
                queryVec.colbertVecs,
                rerankDepth,
                HydraConfig.colbertCentroidSearchWidth()
            )
        } catch (e: Exception) {
            eprintln("[f_hydra] ColBERT search failed: ${e.message}")
            Array<ScoredDocument>()
        }

        // Step 4: Fusion
        let strategy = HydraConfig.fusionStrategy()
        let finalResults = this.fusion.fuse(
            sparseResults,
            denseResults,
            colbertResults,
            strategy,
            None<Array<Float64>>,
            topK
        )

        let elapsed = DateTime.now().durationSince(start)
        HybridSearchResult(results: finalResults, latency: elapsed)
    }

    // Close: graceful shutdown.
    // Order: set closing flag → no active searches to wait for → close backend.
    public func close() {
        this.closing.store(true)
        println("[f_hydra] Engine closing...")
        this.embedder.close()
        this.denseIndexer.close()
        this.colbertIndexer.close()
        // sparseIndexer is pure Cangjie (GC-managed)
        println("[f_hydra] Engine closed")
    }
}
