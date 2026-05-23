package fountain::f_hydra

import std.collection.{HashMap, ArrayList}
import fountain.f_hydra.index.posting_list.PostingList
import fountain.f_hydra.fusion.scored_document.ScoredDocument

// Cangjie-native sparse inverted index.
// Maps token IDs to posting lists of (docId, weight) entries.
// Build: iterate all documents, append to posting lists, then sort.
// Search: merge posting lists for query tokens, accumulate weights, top-k.

public class SparseIndexer {
    private let postingLists: HashMap<Int64, PostingList>
    private var totalDocs: Int64

    public init() {
        this.postingLists = HashMap<Int64, PostingList>()
        this.totalDocs = 0
    }

    // Build index from an array of sparse vectors.
    // Each sparse vector is a HashMap<tokenId, weight>.
    public func buildIndex(sparseVecs: Array<HashMap<Int64, Float32>>) {
        for (docId in 0..sparseVecs.size) {
            let vec = sparseVecs[docId]
            for ((tokenId, weight) in vec) {
                if (!this.postingLists.contains(tokenId)) {
                    this.postingLists[tokenId] = PostingList()
                }
                let pl = this.postingLists[tokenId]
                pl.add(docId, weight)
            }
        }

        // Post-processing: sort all posting lists by docId
        for ((_, pl) in this.postingLists) {
            pl.sortByDocId()
            pl.buildSkipPointers()
        }

        this.totalDocs = sparseVecs.size as Int64
    }

    // Search: merge posting lists for query tokens, score documents.
    // Returns top-k ScoredDocuments sorted by cumulative weight (descending).
    public func search(
        queryVec: HashMap<Int64, Float32>,
        k: Int64
    ): Array<ScoredDocument> {
        // Collect posting list positions for each query token
        var tokenLists = ArrayList<(Int64, PostingList)>(queryVec.size)
        for ((tokenId, weight) in queryVec) {
            if (let Some(pl) <- this.postingLists.get(tokenId)) {
                tokenLists.add((tokenId, pl))
            }
        }

        if (tokenLists.size == 0) {
            return Array<ScoredDocument>()
        }

        // Multi-list merge: advance all lists to the same docId, accumulate scores
        var docScores = HashMap<Int64, Float32>()
        var positions = Array<Int64>(tokenLists.size, init: 0)
        var active = true

        while (active) {
            // Find current docId (minimum across all active lists)
            var currentDocId: Int64 = -1
            var anyActive = false
            var minDocId: Int64 = -1
            var first = true

            for (i in 0..tokenLists.size) {
                let pos = positions[i]
                let pl = tokenLists[i][1]
                if (pos < pl.size()) {
                    let docId = pl.getDocId(pos)
                    if (first || docId < minDocId) {
                        minDocId = docId
                        first = false
                    }
                    anyActive = true
                }
            }

            if (!anyActive) { break }
            currentDocId = minDocId

            // Accumulate scores from all lists at currentDocId
            var score: Float32 = 0.0
            for (i in 0..tokenLists.size) {
                let pos = positions[i]
                let pl = tokenLists[i][1]
                if (pos < pl.size() && pl.getDocId(pos) == currentDocId) {
                    let tokenWeight = queryVec[tokenLists[i][0]]
                    score += tokenWeight * pl.getWeight(pos)
                    positions[i] += 1
                }
            }

            docScores[currentDocId] = (docScores.getOrPut(currentDocId, 0.0) + score)
        }

        // Sort by score descending, take top-k
        var scored = docScores.toArray()
        scored.sort({ a: (Int64, Float32), b: (Int64, Float32) =>
            if (a[1] > b[1]) { -1 }
            else if (a[1] < b[1]) { 1 }
            else { 0 }
        })

        let topK = if (scored.size < k) { scored.size } else { k }
        Array<ScoredDocument>(topK) { i =>
            ScoredDocument(
                docId: scored[i][0],
                score: scored[i][1],
                source: "sparse",
                rank: i as Int64
            )
        }
    }

    public func getPostingList(tokenId: Int64): ?PostingList {
        this.postingLists.get(tokenId)
    }

    public func getTotalDocs(): Int64 {
        this.totalDocs
    }
}
