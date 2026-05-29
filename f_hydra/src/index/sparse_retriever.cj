package fountain::f_hydra

import std.collection.HashMap
import fountain.f_hydra.index.sparse_indexer.SparseIndexer
import fountain.f_hydra.fusion.scored_document.ScoredDocument

// Thin retriever wrapper around SparseIndexer.
// Implements the same ScoredDocument-based API as DenseRetriever.
public class SparseRetriever {
    private let indexer: SparseIndexer

    public init(indexer: SparseIndexer) {
        this.indexer = indexer
    }

    // Search with sparse query vector (tokenId → weight).
    // Returns top-k ScoredDocuments.
    public func search(
        queryVec: HashMap<Int64, Float32>,
        k: Int64
    ): Array<ScoredDocument> {
        this.indexer.search(queryVec, k)
    }
}
