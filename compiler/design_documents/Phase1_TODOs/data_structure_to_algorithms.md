# Data Structure → Algorithm Map (Purely Functional)

**Purpose:** Map every standard Silica collection **trait** and abstract representation family to **purely functional** insertion and deletion algorithms drawn from Chris Okasaki's work and subsequent research.

**Scope:** Logical algorithms, persistence techniques, and primary literature only. This document does not prescribe or refer to any existing Silica stdlib implementation.

**Status:** Algorithm choices below are **locked** (reviewed 2026-06; BinaryTree decision 16 added 2026-07-02). Do not add parallel representations without revisiting this section. **Implementation status (2026-10-16):** every decision is implemented as locked (stdlib `compiler/stdlib/data_structures/`, trials `trials/ordered_data_structures/`); the only representation deviation is that dense graph cells are optional references over the skew RAL rather than boolean or tagged-sum cells (`graph_dense_core.silica` header). `join`/`split`/`concat` for the WBT remain deferred.

---

## Locked decisions


| #   | Topic                                   | Decision                                                                                                      |
| --- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 1   | `OrderedSet`                            | Adams **weight-balanced tree (WBT)** [Ada93] for **all** key types                                            |
| 2   | Integer key specialization              | **None** — no Patricia / crit-bit trie                                                                        |
| 3   | `OrderedMap`                            | **WBT map** (same rule as set)                                                                                |
| 4   | `SearchTree`                            | Same as `OrderedSet` (WBT)                                                                                    |
| 5   | Graph vertex index                      | **WBT** keyed by `compare_node`                                                                               |
| 6   | Graph neighbors (unweighted)            | **WBT set** of target node ids                                                                                |
| 7   | Graph neighbors (weighted / attributed) | **WBT map** `to → edge data` (one edge per `(from, to)`); `{to,data}` neighbor wrappers are generated views   |
| 8   | CSR graph                               | **WBT live adjacency** + optional **CSR freeze** O(V + E)                                                     |
| 9   | Dense matrix graph                      | **One skew binary random-access-list cell sequence** [Oka95, Oka98 §5]: boolean cells when unweighted; `:none |
| 10  | Dense bitset graph                      | **Not in scope** — family removed                                                                             |
| 11  | `Tree` child sequences                  | **Skew binary random-access list**                                                                            |
| 12  | `Heap`                                  | **Brodal–Okasaki** optimal queue [BO96]                                                                       |
| 13  | `PriorityQueue`                         | **Brodal–Okasaki** on `(priority, value)` pairs; shared implementation with `Heap`                            |
| 14  | Decrease-key                            | **Not in the Phase 1 `PriorityQueue` API**; no arbitrary-entry deletion, handles, or priority-search queue    |
| 15  | Bulk WBT construction                   | **Fold insert** (default) + optional `**from_sorted`** O(n) linear builder                                    |
| 16  | `BinaryTree`                            | Persistent fixed-role left/right tree with path copying; Huet zipper [Hue97] for focused traversal/rebuild   |


### Architecture (summary)

```text
OrderedSet / OrderedMap / SearchTree  →  Adams WBT [Ada93]
                                         bulk: fold insert | from_sorted

Graphs (live)                         →  WBT<Vertex, WBT<Neighbor, …>>
                                         unweighted: inner WBT set
                                         weighted:   inner WBT map (to → edge data)
Graphs (snapshot)                     →  CSR freeze O(V+E) from live WBT [KL95]

Dense matrix (specialized)            →  Okasaki skew binary random-access list [Oka95]

Tree children                         →  Okasaki skew binary random-access list [Oka95]

BinaryTree                            →  Fixed left/right recursive tuple + path copying
                                         focused traversal: Huet zipper [Hue97]

Heap / PriorityQueue                  →  Brodal–Okasaki [BO96]
```

### Explicitly rejected (do not implement as parallel paths)

Finger trees [HP06], Patricia / crit-bit tries [Hin01, Ber13], HAMT maps [Bag00], lazy / bootstrapped heaps as primary heap [Oka98 §7–8], persistent vector / RRB tries [Bag00, Str10], dense bitset graphs [Oka95, CP95], d-ary array heaps, Hinze priority-search queues for decrease-key [Hin01].

---

## Literature used in this map


| Structure                                  | Typical bounds                                           | References           |
| ------------------------------------------ | -------------------------------------------------------- | -------------------- |
| **Weight-balanced tree (WBT)**             | O(log n) insert / delete / lookup                        | [Ada93]              |
| **Skew binary random-access list**         | O(log n) index update                                    | [Oka95, Oka98]       |
| **Brodal–Okasaki heap**                    | O(1) worst insert / find-min / meld; O(log n) delete-min | [BO96, Bro95, Vui78] |
| **Functional graph (WBT + WBT adjacency)** | O(log V + log degree) edge update                        | [KL95, Erw97, Ada93] |
| **CSR snapshot**                           | O(V + E) batch build from live graph                     | [KL95, Erw97]        |
| **Persistent binary tree**                 | O(h) path lookup/update; O(n) fold/map                   | [Driscoll86, Hue97]  |


### Okasaki (*Purely Functional Data Structures*, 1998) [Oka98] — chapters referenced


| Chapter | Use in this map                                                   |
| ------- | ----------------------------------------------------------------- |
| §5      | Skew binary random-access lists (dense matrix, tree children)     |
| §6      | Amortized analysis background                                     |
| §8      | Data-structural bootstrapping (internal to Brodal–Okasaki [BO96]) |


---

## Persistence techniques

All mutators return a **new value**; prior bindings remain valid.


| Technique                         | Used by                                                    | References          |
| --------------------------------- | ---------------------------------------------------------- | ------------------- |
| **Path copying**                  | WBT; skew RAL; persistent BinaryTree                       | [Driscoll86, Oka98] |
| **Focused path reconstruction**   | Persistent BinaryTree zipper                              | [Hue97]             |
| **Data-structural bootstrapping** | Brodal–Okasaki queue (nested queues, global min)           | [Oka98, BO96]       |
| **Recursive slowdown**            | Brodal–Okasaki worst-case analysis (Kaplan–Tarjan lineage) | [KT95, BO96]        |
| **Batch rebuild**                 | CSR freeze from WBT adjacency                              | [KL95]              |


---

## Trait modules → functional representations


| Trait module                        | Representation                                        | References           |
| ----------------------------------- | ----------------------------------------------------- | -------------------- |
| `OrderedSet`                        | Adams WBT                                             | [Ada93]              |
| `OrderedMap`                        | Adams WBT map                                         | [Ada93]              |
| `SearchTree`                        | Adams WBT (same as `OrderedSet`)                      | [Ada93]              |
| `DirectedGraph` / `UndirectedGraph` | WBT vertex map + WBT neighbor set                     | [Ada93, KL95, Erw97] |
| `WeightedGraph`                     | WBT vertex map + WBT neighbor map (`to → edge data`)  | [Ada93, KL95, Erw97] |
| `Heap`                              | Brodal–Okasaki min/max queue                          | [BO96]               |
| `PriorityQueue`                     | Brodal–Okasaki on `(priority, value)` pairs           | [BO96]               |
| `Tree`                              | Rose tree; children in skew binary random-access list | [Oka95, Oka98]       |
| `BinaryTree`                        | Fixed left/right recursive tuple; optional zipper     | [Driscoll86, Hue97]  |


---

## Ordered collections

All ordered collections use **Adams WBT** [Ada93] with path copying. Keys are ordered by captured comparators (`compare_item`, `compare_key`); there is **no** separate representation for integer keys.

### `OrderedSet`


| Operation    | Algorithm                                                                  | Persistence  | Complexity | References |
| ------------ | -------------------------------------------------------------------------- | ------------ | ---------- | ---------- |
| **Insert**   | Descend by compare; insert at leaf; Adams single/double rotation rebalance | Path copying | O(log n)   | [Ada93]    |
| **Delete**   | Locate key; delete or successor swap; Adams rebalance                      | Path copying | O(log n)   | [Ada93]    |
| **Contains** | BST search                                                                 | Read-only    | O(log n)   | [Ada93]    |
| **Fold**     | In-order traversal                                                         | Read-only    | O(n)       | [Ada93]    |


**Duplicate policy:** key present → unchanged tree, `inserted = false`.

**Bulk construction:**


| Constructor                     | Algorithm                                                                 | Complexity           | References |
| ------------------------------- | ------------------------------------------------------------------------- | -------------------- | ---------- |
| **Default** (`from_list`, fold) | Repeated `insert` in fold order                                           | O(n log n)           | [Ada93]    |
| `**from_sorted`**               | Linear balanced build from sorted unique keys (divide on median, recurse) | O(n) when pre-sorted | [Ada93]    |


### `OrderedMap`


| Operation           | Algorithm                                      | Persistence  | Complexity | References |
| ------------------- | ---------------------------------------------- | ------------ | ---------- | ---------- |
| **Insert / update** | WBT insert; **replace** value on duplicate key | Path copying | O(log n)   | [Ada93]    |
| **Delete**          | WBT delete on key                              | Path copying | O(log n)   | [Ada93]    |
| **Get**             | WBT search                                     | Read-only    | O(log n)   | [Ada93]    |


Bulk construction: same **fold insert** + `**from_sorted`** policy as `OrderedSet`.

### `SearchTree`


| Operation                      | Algorithm                     | References |
| ------------------------------ | ----------------------------- | ---------- |
| **Insert / delete / contains** | Identical to `OrderedSet` WBT | [Ada93]    |


---

## Graphs

### Live model (King–Launchbury / Erwig)

```text
adj : WBTMap<NodeIdType, WBTSet<NodeIdType>>               -- unweighted
adj : WBTMap<NodeIdType, WBTMap<NodeIdType, EdgeData>>     -- weighted / attributed
```

Outer and inner maps/sets use **WBT** with `compare_node`. Undirected graphs: symmetric update on `(u,v)` and `(v,u)`.


| Operation                 | Algorithm                                                           | Persistence     | Complexity                  | References           |
| ------------------------- | ------------------------------------------------------------------- | --------------- | --------------------------- | -------------------- |
| **Add edge (unweighted)** | Update outer WBT; insert `to` in inner WBT set at `from`            | Path copying    | O(log V + log degree)       | [Ada93, KL95, Erw97] |
| **Add edge (weighted)**   | Update outer WBT; insert/replace `(to, edge_data)` in inner WBT map | Path copying    | O(log V + log degree)       | [Ada93, KL95, Erw97] |
| **Remove edge**           | Delete from inner WBT; remove outer entry if inner empty            | Path copying    | O(log V + log degree)       | [Ada93, KL95]        |
| **Add vertex**            | Insert `id ↦ empty` inner WBT into outer WBT                        | Path copying    | O(log V)                    | [Ada93]              |
| **Has edge**              | Inner WBT lookup at `from`                                          | Read-only       | O(log degree)               | [Ada93]              |
| **From edge list**        | Fold **add edge**                                                   | Persistent fold | O(E · (log V + log degree)) | [KL95, Erw97]        |


### CSR graph — snapshot only


| Operation  | Algorithm                                                                                                                                 | Complexity | References    |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------- |
| **Freeze** | Two-pass build from live WBT adjacency: degree count → prefix-sum → scatter into fresh offsets/neighbors (and weight buffers if weighted) | O(V + E)   | [KL95, Erw97] |


The live WBT graph is unchanged after freeze. CSR is for read-heavy traversal, not incremental edge updates.

### Dense matrix graph (specialized, small V)


| Operation              | Algorithm                                                                              | Persistence  | Complexity | References     |
| ---------------------- | -------------------------------------------------------------------------------------- | ------------ | ---------- | -------------- |
| **Set / clear edge**   | Skew binary random-access list over index `from * V + to`                              | Path copying | O(log V)   | [Oka95, Oka98] |
| **Weighted edge data** | One tagged optional-data random-access-list cell, replacing `:none` or `(:some, data)` | Path copying | O(log V)   | [Oka95, Oka98] |


---

## Heaps and priority queues

Single **Brodal–Okasaki** implementation [BO96] serves both `Heap` and `PriorityQueue`.

### `Heap`


| Operation            | Algorithm                                                                    | Persistence                         | Complexity          | References    |
| -------------------- | ---------------------------------------------------------------------------- | ----------------------------------- | ------------------- | ------------- |
| **Insert (push)**    | Skew binomial insert; global min root; bootstrapped meld                     | Path copying + strict bootstrapping | O(1) worst-case     | [BO96, Vui78] |
| **Delete-min (pop)** | Remove global min; skew binomial forest fixup; bootstrapped meld of children | Path copying                        | O(log n) worst-case | [BO96]        |
| **Peek**             | Read global root                                                             | Read-only                           | O(1)                | [BO96]        |
| **Meld**             | Bootstrapped queue meld                                                      | Path copying                        | O(1) worst-case     | [BO96]        |


Max-heap uses an orientation adapter that reverses comparator results (`:less` ↔ `:greater`, preserving `:equal`). Stored values are never negated.

### `PriorityQueue`


| Operation | Algorithm                                                               | Complexity          | References |
| --------- | ----------------------------------------------------------------------- | ------------------- | ---------- |
| **Push**  | Brodal–Okasaki insert on `(priority, value)` with lexicographic compare | O(1) worst-case     | [BO96]     |
| **Pop**   | Delete-min; return pair                                                 | O(log n) worst-case | [BO96]     |


---

## Tree traits

### `Tree` — rose tree


| Operation        | Algorithm                                                                | Persistence  | Complexity                           | References     |
| ---------------- | ------------------------------------------------------------------------ | ------------ | ------------------------------------ | -------------- |
| **Add child**    | Append at child index and path-copy every ancestor child sequence        | Path copying | O(Σ log b_i + h) at target depth `h` | [Oka95, Oka98] |
| **Remove child** | Vacate the stable child slot and path-copy every ancestor child sequence | Path copying | O(Σ log b_i + h) at target depth `h` | [Oka95, Oka98] |


Here `b_i` is the child-slot count at ancestor `i`; these whole-tree updates are not generally `O(log n)`.

### `BinaryTree` — persistent fixed-role binary tree

`BinaryTree` is not an ordered search tree. Items do not determine placement, and there is no comparator.

| Operation | Algorithm | Persistence | Complexity | References |
|---|---|---|---|---|
| **Get path** | Follow fixed `:left` / `:right` components | Read-only | O(h) | [Driscoll86] |
| **Replace item** | Rebuild target and path-copy ancestors | Path copying | O(h) | [Driscoll86] |
| **Replace child subtree** | Install at exact left/right role and path-copy ancestors | Path copying | O(h) | [Driscoll86] |
| **Fold** | Preorder, inorder, or postorder traversal | Read-only | O(n) | — |
| **Map** | Shape-preserving traversal and rebuild | Path copying | O(n) | [Driscoll86] |
| **Zipper move down/up** | Breadcrumb focus movement and one-level reconstruction | Purely functional zipper | O(1) per step | [Hue97] |

Here `h` is target depth and `n` is the number of logical node occurrences. Repeated physical subtree references are allowed and counted once per logical position.

---

## Collection families → algorithm map


| Family                            | Insert / add                     | Delete / remove                  | References           |
| --------------------------------- | -------------------------------- | -------------------------------- | -------------------- |
| Ordered set / map                 | WBT insert                       | WBT delete                       | [Ada93]              |
| Search tree                       | WBT insert                       | WBT delete                       | [Ada93]              |
| Adjacency-list graph (unweighted) | WBT + WBT set edge insert        | WBT + WBT set edge delete        | [Ada93, KL95, Erw97] |
| Weighted adjacency-list graph     | WBT + WBT map insert/replace     | WBT + WBT map edge delete        | [Ada93, KL95, Erw97] |
| CSR graph (snapshot)              | O(V+E) freeze from WBT adjacency | Re-freeze after live-graph edits | [KL95, Erw97]        |
| Dense matrix graph                | Random-access list cell set      | Random-access list cell clear    | [Oka95, Oka98]       |
| Min / max heap                    | Brodal–Okasaki insert            | Brodal–Okasaki delete-min        | [BO96]               |
| Priority queue                    | Brodal–Okasaki insert (pair)     | Brodal–Okasaki delete-min        | [BO96]               |
| Tree (rose)                       | Random-access list child append  | Random-access list child remove  | [Oka95, Oka98]       |
| Binary tree                       | Fixed left/right subtree install | Fixed left/right subtree clear   | [Driscoll86, Hue97]  |


**Not in scope:** dense bitset graph.

---

## Cross-representation pipelines


| Pipeline                      | Algorithms                                       | References           |
| ----------------------------- | ------------------------------------------------ | -------------------- |
| Edge list → live graph        | Fold **add edge** over WBT + WBT adjacency       | [KL95, Erw97, Ada93] |
| Live graph → CSR snapshot     | O(V + E) degree count + prefix-sum + scatter     | [KL95]               |
| Ordered set → sorted sequence | In-order fold on WBT                             | [Ada93]              |
| Static sorted keys → WBT      | `**from_sorted`** O(n) or fold insert O(n log n) | [Ada93]              |
| Multiple heaps → one          | Brodal–Okasaki **meld** O(1)                     | [BO96]               |


---

## Complexity summary (single operation)


| Family                            | Insert / add       | Delete / remove    | References            |
| --------------------------------- | ------------------ | ------------------ | --------------------- |
| WBT set / map                     | O(log n)           | O(log n)           | [Ada93]               |
| WBT graph edge                    | O(log V + log deg) | O(log V + log deg) | [Ada93, KL95]         |
| Random-access list (dense / tree) | O(log n)           | O(log n)           | [Oka95, Oka98]        |
| Brodal–Okasaki heap / PQ          | O(1) worst         | O(log n) worst     | [BO96]                |
| Persistent binary tree            | O(h) path update   | O(h) path update   | [Driscoll86, Hue97]   |
| CSR freeze                        | —                  | —                  | O(V + E) batch [KL95] |


No single insert/delete is O(n) in structure size except batch CSR freeze or explicit full traversal (fold).

---

## Complete bibliography

Citation keys appear in square brackets throughout this document.

### Chris Okasaki and co-authored work

- **[Oka98]** Okasaki, C. (1998). *Purely Functional Data Structures*. Cambridge University Press. ISBN 978-0521663502.
- **[Oka95]** Okasaki, C. (1995). Purely Functional Random-Access Lists. In *Proceedings of the 7th ACM Conference on Functional Programming Languages and Computer Architecture (FPCA '95)*, pages 86–95. ACM. DOI: 10.1145/224164.224187.
- **[Oka96]** Okasaki, C. (1996). The Role of Lazy Evaluation in Amortized Data Structures. In *Proceedings of the 23rd ACM SIGPLAN-SIGACT Symposium on Principles of Programming Languages (POPL '96)*, pages 62–72. ACM. DOI: 10.1145/237721.237748.
- **[BO96]** Brodal, G. S., & Okasaki, C. (1996). Optimal Purely Functional Priority Queues. *Journal of Functional Programming*, 6(6), 839–857. DOI: 10.1017/S095679680000201X.

### Persistence foundations

- **[Driscoll86]** Driscoll, J. R., Sarnak, N., Sleator, D. D., & Tarjan, R. E. (1986). Making Data Structures Persistent. In *Proceedings of the 18th Annual ACM Symposium on Theory of Computing (STOC '86)*, pages 109–121. ACM. DOI: 10.1145/12130.12138.
- **[KT95]** Kaplan, H., & Tarjan, R. E. (1995). Persistent Lists with Catenation via Recursive Slow-Down. In *Proceedings of the 27th Annual ACM Symposium on Theory of Computing (STOC '95)*, pages 93–102. ACM. DOI: 10.1145/225058.225093.
- **[Hue97]** Huet, G. (1997). The Zipper. *Journal of Functional Programming*, 7(5), 549–554. DOI: 10.1017/S0956796897002864.

### Ordered sets and maps

- **[Ada93]** Adams, N. (1993). Efficient Sets—A Balancing Act. *Journal of Functional Programming*, 3(4), 553–562. DOI: 10.1017/S0956796800000505.

### Heaps and priority queues

- **[Vui78]** Vuillemin, J. (1978). A Data Structure for Manipulating Priority Queues. *Communications of the ACM*, 21(7), 545–548. DOI: 10.1145/359545.359553.
- **[Bro95]** Brodal, G. S. (1995). Worst-case Efficient Priority Queues. In *Proceedings of the 7th Annual ACM-SIAM Symposium on Discrete Algorithms (SODA '96)*, pages 52–58. ACM/SIAM.

### Functional graphs

- **[KL95]** King, D. J., & Launchbury, J. (1995). Graph Algorithms in a Lazy Functional Language. *Journal of Functional Programming*, 5(1), 81–110. DOI: 10.1017/S0956796800000149.
- **[Erw97]** Erwig, M. (1997). Functional Graphs. *Technical Report 97-9*, Department of Computing Science, Chalmers University of Technology. [https://www.cs.tufts.edu/~nr/cs257/archive/martin-erwig/functional-graphs.pdf](https://www.cs.tufts.edu/~nr/cs257/archive/martin-erwig/functional-graphs.pdf)

When implementing, use the primary sources above. Background papers cited only in the rejected-alternatives list are intentionally omitted from the bibliography.
