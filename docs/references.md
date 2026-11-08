# References

The works Cepheus follows, measures itself against, or plans to follow, by subject. Each entry gives the authors, the
title, the venue and the year, a link (a DOI where there is one, else the publisher's or the authors' page), and what
Cepheus took from it. Every entry was checked against the publisher's record or DBLP (authors in order, exact title,
venue, volume and year); a work that could not be checked is not listed. The design documentation of other databases
(PostgreSQL, SQLite, Oracle, Datomic, RocksDB, Neo4j, FoundationDB, CockroachDB) is cited on the
[comparison](comparison.md) page.

## Storage: log-structured merge-trees

- **[O'Neil 1996]** P. O'Neil, E. Cheng, D. Gawlick, E. O'Neil. The Log-Structured Merge-Tree (LSM-Tree). *Acta
  Informatica* 33(4), 351–385, 1996. https://doi.org/10.1007/s002360050048
  — The structure of the store: changes in a small component in memory, merged in bulk into sorted components on
  disk by a merge of sorted runs (the "rolling merge" of C0 into C1, and of each component into the next); the cost
  of a merge as the size ratio plus one.
- **[Luo 2020]** C. Luo, M. J. Carey. LSM-based Storage Techniques: A Survey. *The VLDB Journal* 29(1), 393–418, 2020.
  https://doi.org/10.1007/s00778-019-00555-y
  — The vocabulary and the costs of leveling and tiering (write amplification O(T·L) and O(L), runs a read visits L
  and T·L), from which Cepheus' leveling with ratio 4 is chosen (theory, section 9).
- **[Dong 2017]** S. Dong, M. Callaghan, L. Galanis, D. Borthakur, T. Savor, M. Stumm. Optimizing Space Amplification
  in RocksDB. *CIDR* 2017. https://cidrdb.org/cidr2017/papers/p82-dong-cidr17.pdf
  — Space and write amplification in RocksDB; with RocksDB's `bytes_per_sync` option, the reason a merge forces its
  file every 8 MiB while clients write.
- **[Balmau 2019]** O. Balmau, F. Dinu, W. Zwaenepoel, K. Gupta, R. Chandhiramoorthi, D. Didona. SILK: Preventing
  Latency Spikes in Log-Structured Merge Key-Value Stores. *USENIX ATC* 2019, 753–766.
  https://www.usenix.org/conference/atc19/presentation/balmau
  — Merges scheduled around the clients' writes; a plain rate limit was tried here and did not help (benchmarks).
- **[Brodal 2003]** G. S. Brodal, R. Fagerberg. Lower Bounds for External Memory Dictionaries. *SODA* 2003, 546–554.
  https://cs.au.dk/~gerth/papers/soda03.pdf
  — The best possible trade-off between the cost of writes and of reads on disk; why a write-optimized structure
  (an LSM-tree or a Bε-tree) is chosen for an append-only history.
- **[Bender 2015]** M. A. Bender, M. Farach-Colton, W. Jannen, R. Johnson, B. C. Kuszmaul, D. E. Porter, J. Yuan,
  Y. Zhan. An Introduction to Bε-trees and Write-Optimization. *;login:* 40(5), 22–28, 2015.
  https://www.usenix.org/publications/login/oct15/bender
  — The other write-optimized structure, weighed against the LSM-tree in the design.
- **[Lu 2016]** L. Lu, T. S. Pillai, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau. WiscKey: Separating Keys from Values
  in SSD-Conscious Storage. *FAST* 2016, 133–148.
  https://www.usenix.org/conference/fast16/technical-sessions/presentation/lu
  — Keep large values out of the sorted runs: Cepheus' texts live in a dictionary and the rows hold their numbers.
- **[Dayan 2017]** N. Dayan, M. Athanassoulis, S. Idreos. Monkey: Optimal Navigable Key-Value Store. *SIGMOD* 2017,
  79–94. https://doi.org/10.1145/3035918.3064054
  — Bloom filters tuned per level make a point lookup of a whole key cost about one run's probe; not built:
  Cepheus' reads are short ranges and exact counts, which visit every run that may hold the key (theory, section 9).
- **[Dayan 2018]** N. Dayan, S. Idreos. Dostoevsky: Better Space-Time Trade-Offs for LSM-Tree Based Key-Value Stores
  via Adaptive Removal of Superfluous Merging. *SIGMOD* 2018, 505–520. https://doi.org/10.1145/3183713.3196927
  — Leveling, tiering and lazy leveling (tiering above, leveling at the last level) weighed by the cost of writes,
  point reads, range reads and space: the comparison Cepheus' choice of leveling rests on.

## Logging, recovery and crash consistency

- **[Mohan 1992]** C. Mohan, D. Haderle, B. Lindsay, H. Pirahesh, P. Schwarz. ARIES: A Transaction Recovery Method
  Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging. *ACM TODS* 17(1), 94–162, 1992.
  https://doi.org/10.1145/128765.128770
  — The write-ahead rule (the log is durable before a change counts). Cepheus' journal is redo-only: it logs changes
  already resolved and never undoes one, so recovery is a replay in order.
- **[DeWitt 1984]** D. J. DeWitt, R. H. Katz, F. Olken, L. D. Shapiro, M. R. Stonebraker, D. A. Wood. Implementation
  Techniques for Main Memory Database Systems. *SIGMOD* 1984, 1–8. https://doi.org/10.1145/602259.602261
  — Group commit: the commits waiting during one log write share the next.
- **[Helland 1987]** P. Helland, H. Sammer, J. Lyon, R. Carr, P. Garrett, A. Reuter. Group Commit Timers and High
  Volume Transaction Systems. *HPTS* 1987; Lecture Notes in Computer Science 359, Springer, 1989, 301–329.
  https://doi.org/10.1007/3-540-51085-0_52
  — Group commit at high volume; Cepheus groups without a timer: a frame holds what arrived during the previous fsync.
- **[Pillai 2014]** T. S. Pillai, V. Chidambaram, R. Alagappan, S. Al-Kiswany, A. C. Arpaci-Dusseau,
  R. H. Arpaci-Dusseau. All File Systems Are Not Created Equal: On the Complexity of Crafting Crash-Consistent
  Applications. *OSDI* 2014, 433–448. https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai
  — The ALICE study: crash bugs come from the order of writes, fsyncs and renames. Cepheus forces a file before its
  rename and a directory after a name changes, and its exhaustive test enumerates every crash state in that spirit.
- **[Rebello 2020]** A. Rebello, Y. Patel, R. Alagappan, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau. Can Applications
  Recover from fsync Failures? *USENIX ATC* 2020, 753–767. https://www.usenix.org/conference/atc20/presentation/rebello
  — After a failed fsync, ext4 and XFS mark the pages clean and keep their new bytes in memory, Btrfs undoes them;
  retrying is wrong, and recovery must rest on what the disk holds. Cepheus stops and never retries (G10), cuts the
  journal back to its last durable frame, and writes the newest frame again at recovery so that its fsync really
  writes it, the paper's own advice (G13); its simulated disk does what the paper measured.
- **[Zheng 2013]** M. Zheng, J. Tucek, F. Qin, M. Lillibridge. Understanding the Robustness of SSDs under Power Fault.
  *FAST* 2013, 271–284. https://www.usenix.org/conference/fast13/technical-sessions/presentation/zheng
  — Real SSDs lose and tear data at a power cut: why the fault model includes torn and reordered sectors, and why
  production disks need power-loss protection.
- **[Castagnoli 1993]** G. Castagnoli, S. Brauer, M. Herrmann. Optimization of Cyclic Redundancy-Check Codes with 24
  and 32 Parity Bits. *IEEE Transactions on Communications* 41(6), 883–892, 1993. https://doi.org/10.1109/26.231911
  — The CRC-32C polynomial (0x1EDC6F41, reflected 0x82F63B78) of every frame and page.
- **[Koopman 2002]** P. Koopman. 32-Bit Cyclic Redundancy Codes for Internet Applications. *DSN* 2002, 459–468.
  https://doi.org/10.1109/DSN.2002.1028931
  — What CRC-32C detects for certain (its Hamming distance by length) and with what probability the rest escapes.
- **[Alagappan 2018]** R. Alagappan, A. Ganesan, E. Lee, A. Albarghouthi, V. Chidambaram, A. C. Arpaci-Dusseau,
  R. H. Arpaci-Dusseau. Protocol-Aware Recovery for Consensus-Based Storage. *FAST* 2018, 15–32.
  https://www.usenix.org/conference/fast18/presentation/alagappan
  — One damaged sector can lose confirmed data in replicated systems; the rule planned for replication (a damaged
  replica does not vote, it repairs), and why a single machine refuses to open rather than cut.

## Buffer management and caching

- **[Crotty 2022]** A. Crotty, V. Leis, A. Pavlo. Are You Sure You Want to Use MMAP in Your Database Management
  System? *CIDR* 2022. https://vldb.org/cidrdb/2022/are-you-sure-you-want-to-use-mmap-in-your-database-management-system.html
  — Why the base is read through Cepheus' own cache rather than mapped: errors as signals, no control of eviction,
  stalls beyond memory.
- **[Leis 2018]** V. Leis, M. Haubenschild, A. Kemper, T. Neumann. LeanStore: In-Memory Data Management beyond Main
  Memory. *ICDE* 2018, 185–196. https://doi.org/10.1109/ICDE.2018.00026
  — A buffer pool with the speed of an in-memory database when everything fits: hot pages reached with no lock.
- **[Neumann 2020]** T. Neumann, M. J. Freitag. Umbra: A Disk-Based System with In-Memory Performance. *CIDR* 2020.
  https://vldb.org/cidrdb/2020/umbra-a-disk-based-system-with-in-memory-performance.html
  — Variable page sizes; 64 KiB pages were measured here and gave nothing over 16 KiB.
- **[Leis 2023]** V. Leis, A. Alhomssi, T. Ziegler, Y. Loeck, C. Dietrich. Virtual-Memory Assisted Buffer Management.
  *Proceedings of the ACM on Management of Data* 1(1), 1–25 (SIGMOD 2023). https://doi.org/10.1145/3588687
  — The database decides what to read and evict, even when the memory mapping is used as a page table.
- **[Harizopoulos 2008]** S. Harizopoulos, D. J. Abadi, S. Madden, M. Stonebraker. OLTP Through the Looking Glass, and
  What We Found There. *SIGMOD* 2008, 981–992. https://doi.org/10.1145/1376616.1376713
  — In a classic engine, locking, latching, logging and the buffer manager take most of the time: Cepheus has one
  writer (no locks) and lock-free hits.
- **[Yang 2023]** J. Yang, Y. Zhang, Z. Qiu, Y. Yue, R. Vinayak. FIFO Queues are All You Need for Cache Eviction.
  *SOSP* 2023, 130–149. https://doi.org/10.1145/3600006.3613147
  — S3-FIFO, the eviction policy of the cache: three FIFO queues, nothing moved on a hit.
- **[Belady 1966]** L. A. Belady. A Study of Replacement Algorithms for a Virtual-Storage Computer. *IBM Systems
  Journal* 5(2), 78–101, 1966. https://doi.org/10.1147/sj.52.0078
  — The optimal offline policy (evict the page needed the farthest in the future), the yardstick of the cache study.
- **[Johnson 1994]** T. Johnson, D. Shasha. 2Q: A Low Overhead High Performance Buffer Management Replacement
  Algorithm. *VLDB* 1994, 439–450. https://www.vldb.org/conf/1994/P439.PDF
  — One of the policies simulated on the recorded traces.
- **[Megiddo 2003]** N. Megiddo, D. S. Modha. ARC: A Self-Tuning, Low Overhead Replacement Cache. *FAST* 2003.
  https://www.usenix.org/conference/fast-03/arc-self-tuning-low-overhead-replacement-cache
  — Simulated on the traces.
- **[Einziger 2017]** G. Einziger, R. Friedman, B. Manes. TinyLFU: A Highly Efficient Cache Admission Policy. *ACM
  Transactions on Storage* 13(4), article 35, 2017. https://doi.org/10.1145/3149371
  — W-TinyLFU, simulated on the traces.
- **[Zhang 2024]** Y. Zhang, J. Yang, Y. Yue, Y. Vigfusson, K. V. Rashmi. SIEVE is Simpler than LRU: an Efficient
  Turn-Key Eviction Algorithm for Web Caches. *NSDI* 2024, 1229–1246.
  https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo
  — Simulated on the traces.
- **[Corbató 1968]** F. J. Corbató. A Paging Experiment with the Multics System. MIT Project MAC Memorandum MAC-M-384,
  1968; in *In Honor of Philip M. Morse*, H. Feshbach and K. U. Ingard (eds.), MIT Press, 1969, 217–228.
  https://multicians.org/paging-experiment.pdf
  — CLOCK, the reference bit and the hand; S3-FIFO's main queue keeps a page the same way.

## Indexes and compression

- **[Weiss 2008]** C. Weiss, P. Karras, A. Bernstein. Hexastore: Sextuple Indexing for Semantic Web Data Management.
  *PVLDB* 1(1), 1008–1019, 2008. https://doi.org/10.14778/1453856.1453965
  — Triples in every order; Cepheus keeps two orders, because dense thing numbers make "by thing" an array.
- **[Neumann 2008]** T. Neumann, G. Weikum. RDF-3X: a RISC-style Engine for RDF. *PVLDB* 1(1), 647–659, 2008.
  https://doi.org/10.14778/1453856.1453927
  — Sorted triple orders, compressed; the third order (property, thing) is weighed for data larger than memory.
- **[Zukowski 2006]** M. Zukowski, S. Héman, N. Nes, P. Boncz. Super-Scalar RAM-CPU Cache Compression. *ICDE* 2006, 59.
  https://doi.org/10.1109/ICDE.2006.150
  — PFOR compression of sorted integers: planned for the runs.
- **[Lemire 2015]** D. Lemire, L. Boytsov. Decoding Billions of Integers per Second through Vectorization. *Software:
  Practice and Experience* 45(1), 1–29, 2015. https://doi.org/10.1002/spe.2203
  — The same, vectorized: planned.
- **[Binnig 2009]** C. Binnig, S. Hildenbrand, F. Färber. Dictionary-based Order-preserving String Compression for
  Main Memory Column Stores. *SIGMOD* 2009, 283–296. https://doi.org/10.1145/1559845.1559877
  — An order-preserving dictionary would allow ranges and prefixes on texts; today the dictionary keeps a sorted list
  of its ids (`ssort`) for lookups only.

- **[Jacobson 1989]** G. Jacobson. Space-efficient Static Trees and Graphs. *FOCS* 1989, 549–554.
  https://doi.org/10.1109/SFCS.1989.63533
  — The rank directory: a bit vector with counts stored every few words answers "how many ones before position i" in
  constant time. Each part of a run keeps one by thing (presence bits for 32 thing ids and the count before them, a
  quarter of a byte a thing id).
- **[Knuth 1998]** D. E. Knuth. *The Art of Computer Programming, Volume 3: Sorting and Searching*, 2nd edition.
  Addison-Wesley, 1998. ISBN 0-201-89685-0.
  — Section 5.2.5, sorting by distribution: the counting sort and the stable least-significant-digit radix sort that
  sort a large group's facts (by thing, by property, then by value inside each property, 11-bit digits).
- **[Bentley 1976]** J. L. Bentley, A. C.-C. Yao. An Almost Optimal Algorithm for Unbounded Searching. *Information
  Processing Letters* 5(3), 82–87, 1976. https://doi.org/10.1016/0020-0190(76)90071-5
  — Exponential (galloping) search: a merge places the other runs' texts among the largest run's by searches that
  gallop from the last place, so that the largest run's texts are read only where another text falls.

## Joins

- **[Atserias 2008]** A. Atserias, M. Grohe, D. Marx. Size Bounds and Query Plans for Relational Joins. *FOCS* 2008,
  739–748. https://doi.org/10.1109/FOCS.2008.43 ; *SIAM Journal on Computing* 42(4), 1737–1767, 2013.
  https://doi.org/10.1137/110859440
  — The AGM bound: the largest answer of a conjunctive query from the sizes of its inputs (N^1.5 for a triangle).
- **[Ngo 2012]** H. Q. Ngo, E. Porat, C. Ré, A. Rudra. Worst-case Optimal Join Algorithms. *PODS* 2012, 37–48.
  https://doi.org/10.1145/2213556.2213565 ; *Journal of the ACM* 65(3), 2018. https://doi.org/10.1145/3180143
  — The first join algorithm that meets the AGM bound, and the proof that binary-join plans cannot.
- **[Ngo 2013]** H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms. *ACM
  SIGMOD Record* 42(4), 5–16, 2013. https://doi.org/10.1145/2590989.2590991
  — Generic Join, the algorithm of every question, and the argument for its bound.
- **[Veldhuizen 2014]** T. L. Veldhuizen. Leapfrog Triejoin: A Simple, Worst-Case Optimal Join Algorithm. *ICDT* 2014,
  96–106. https://doi.org/10.5441/002/icdt.2014.13
  — The iterator form over sorted indexes; why a sorted intersection keeps the bound only with seeks, and a lookup per
  candidate is the simpler way here.
- **[Aberger 2016]** C. R. Aberger, S. Tu, K. Olukotun, C. Ré. EmptyHeaded: A Relational Engine for Graph Processing.
  *SIGMOD* 2016, 431–446. https://doi.org/10.1145/2882903.2915213
  — A worst-case optimal engine for graph queries.
- **[Freitag 2020]** M. J. Freitag, M. Bandle, T. Schmidt, A. Kemper, T. Neumann. Adopting Worst-Case Optimal Joins in
  Relational Database Systems. *PVLDB* 13(11), 1891–1904, 2020. https://doi.org/10.14778/3407790.3407797
  — In practice the order of the variables matters most.
- **[Mhedhbi 2019]** A. Mhedhbi, S. Salihoglu. Optimizing Subgraph Queries by Combining Binary and Worst-Case Optimal
  Joins. *PVLDB* 12(11), 1692–1704, 2019. https://doi.org/10.14778/3342263.3342643
  — The cost-based choice of the variable order.
- **[Wang 2023]** Y. R. Wang, M. Willsey, D. Suciu. Free Join: Unifying Worst-Case Optimal and Traditional Joins.
  *Proceedings of the ACM on Management of Data* 1(2), 1–23 (SIGMOD 2023). https://doi.org/10.1145/3589295
  — The mix of binary and worst-case optimal joins; Cepheus keeps one way, Generic Join.

## Transactions and isolation

- **[Papadimitriou 1979]** C. H. Papadimitriou. The Serializability of Concurrent Database Updates. *Journal of the
  ACM* 26(4), 631–653, 1979. https://doi.org/10.1145/322154.322158
  — The definition of serializability that G4 proves.
- **[Kung 1981]** H. T. Kung, J. T. Robinson. On Optimistic Methods for Concurrency Control. *ACM TODS* 6(2), 213–226,
  1981. https://doi.org/10.1145/319566.319567
  — Optimistic concurrency control with backward validation: `Expect`, checked by the writer at the end.
- **[Herlihy 1990]** M. P. Herlihy, J. M. Wing. Linearizability: A Correctness Condition for Concurrent Objects. *ACM
  TOPLAS* 12(3), 463–492, 1990. https://doi.org/10.1145/78969.78972
  — The real-time order that makes the history of groups strictly serializable.
- **[Berenson 1995]** H. Berenson, P. Bernstein, J. Gray, J. Melton, E. O'Neil, P. O'Neil. A Critique of ANSI SQL
  Isolation Levels. *SIGMOD* 1995, 1–10. https://doi.org/10.1145/223784.223785
  — Snapshot isolation defined, and its write skew; the vocabulary of the isolation section.
- **[Adya 1999]** A. Adya. Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed
  Transactions. PhD thesis, MIT, 1999. https://hdl.handle.net/1721.1/149899
  — Anomalies as cycles in the dependency graph (G0, G1, G2): none can form among groups.
- **[Fekete 2005]** A. Fekete, D. Liarokapis, E. O'Neil, P. O'Neil, D. Shasha. Making Snapshot Isolation
  Serializable. *ACM TODS* 30(2), 492–528, 2005. https://doi.org/10.1145/1071610.1071615
  — Why snapshot isolation is not serializable, and "materialize the conflict": the way to protect a set with
  `Expect`.
- **[Cahill 2008]** M. J. Cahill, U. Röhm, A. D. Fekete. Serializable Isolation for Snapshot Databases. *SIGMOD* 2008,
  729–738. https://doi.org/10.1145/1376616.1376690
  — Serializable snapshot isolation, as PostgreSQL's SERIALIZABLE implements it.
- **[Ports 2012]** D. R. K. Ports, K. Grittner. Serializable Snapshot Isolation in PostgreSQL. *PVLDB* 5(12),
  1850–1861, 2012. https://doi.org/10.14778/2367502.2367523
  — PostgreSQL's implementation, compared with on the comparison page.
- **[Thomson 2012]** A. Thomson, T. Diamond, S.-C. Weng, K. Ren, P. Shao, D. J. Abadi. Calvin: Fast Distributed
  Transactions for Partitioned Database Systems. *SIGMOD* 2012, 1–12. https://doi.org/10.1145/2213836.2213838
  — Transactions in an order fixed in advance, with no locks: the single writer, and the plan for several machines.

## Persistent structures and forks

- **[Driscoll 1989]** J. R. Driscoll, N. Sarnak, D. D. Sleator, R. E. Tarjan. Making Data Structures Persistent.
  *Journal of Computer and System Sciences* 38(1), 86–124, 1989. https://doi.org/10.1016/0022-0000(89)90034-2
  — Every version kept by copying a path: what makes views and forks free.
- **[Okasaki 1998]** C. Okasaki. Purely Functional Data Structures. Cambridge University Press, 1998.
  https://doi.org/10.1017/CBO9780511530104
  — Persistent balanced trees, the delta's maps.
- **[Kemper 2011]** A. Kemper, T. Neumann. HyPer: A Hybrid OLTP&OLAP Main Memory Database System Based on Virtual
  Memory Snapshots. *ICDE* 2011, 195–206. https://doi.org/10.1109/ICDE.2011.5767867
  — A consistent snapshot by `fork()` of the process: the same need, met by persistence instead.
- **[Rodeh 2008]** O. Rodeh. B-trees, Shadowing, and Clones. *ACM Transactions on Storage* 3(4), 1–27, 2008.
  https://doi.org/10.1145/1326542.1326544
  — Copy-on-write B-trees (btrfs, the test machine's file system).

## Rules and incremental views (planned)

- **[Bancilhon 1986]** F. Bancilhon, R. Ramakrishnan. An Amateur's Introduction to Recursive Query Processing
  Strategies. *SIGMOD* 1986, 16–52. https://doi.org/10.1145/16894.16859
  — Semi-naive evaluation, planned for rules at write time.
- **[Motik 2015]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Incremental Update of Datalog Materialisation: the
  Backward/Forward Algorithm. *AAAI* 2015. https://doi.org/10.1609/aaai.v29i1.9409
  — Retractions in a materialized ontology, planned.
- **[Budiu 2023]** M. Budiu, T. Chajed, F. McSherry, L. Ryzhyk, V. Tannen. DBSP: Automatic Incremental View
  Maintenance for Rich Query Languages. *PVLDB* 16(7), 1601–1614, 2023. https://doi.org/10.14778/3587136.3587137
  — The delta rules of joins, planned for live questions (subscriptions).

## Replication and many machines (planned)

- **[Ongaro 2014]** D. Ongaro, J. Ousterhout. In Search of an Understandable Consensus Algorithm. *USENIX ATC* 2014,
  305–319. https://www.usenix.org/conference/atc14/technical-sessions/presentation/ongaro
  — Raft, chosen for replication, with its public TLA+ specification.
- **[Verbitski 2017]** A. Verbitski, A. Gupta, D. Saha, M. Brahmadesam, K. Gupta, R. Mittal, S. Krishnamurthy,
  S. Maurice, T. Kharatishvili, X. Bao. Amazon Aurora: Design Considerations for High Throughput Cloud-Native
  Relational Databases. *SIGMOD* 2017, 1041–1052. https://doi.org/10.1145/3035918.3056101
  — "The log is the database": the journal is the only thing to replicate.
- **[Antonopoulos 2019]** P. Antonopoulos, A. Budovski, C. Diaconu, A. Hernandez Saenz, J. Hu, H. Kodavalla,
  D. Kossmann, S. Lingam, U. F. Minhas, N. Prakash, V. Purohit, H. Qu, C. S. Ravella, K. Reisteter, S. Shrotri,
  D. Tang, V. Wakade. Socrates: The New SQL Server in the Cloud. *SIGMOD* 2019, 1743–1756.
  https://doi.org/10.1145/3299869.3314047
  — Log, pages and compute separated: the plan for storage on object stores.
- **[Ammar 2018]** K. Ammar, F. McSherry, S. Salihoglu, M. Joglekar. Distributed Evaluation of Subgraph Queries Using
  Worst-case Optimal Low-Memory Dataflows. *PVLDB* 11(6), 691–704, 2018. https://doi.org/10.14778/3184470.3184473
  — BiGJoin: Generic Join over many machines, planned.

## Testing and verification

- **[Zhou 2021]** J. Zhou, M. Xu, A. Shraer, B. Namasivayam, A. Miller, E. Tschannen, S. Atherton, A. J. Beamon,
  R. Sears, J. Leach, D. Rosenthal, X. Dong, W. Wilson, B. Collins, D. Scherer, A. Grieser, Y. Liu, A. Moore,
  B. Muppana, X. Su, V. Yadav. FoundationDB: A Distributed Unbundled Transactional Key Value Store. *SIGMOD* 2021,
  2653–2666. https://doi.org/10.1145/3448016.3457559
  — Deterministic simulation testing: the whole system on simulated time and disks, a failure replayed from its seed.
- **[Bornholt 2021]** J. Bornholt, R. Joshi, V. Astrauskas, B. Cully, B. Kragl, S. Markle, K. Sauri, D. Schleit,
  G. Slatton, S. Tasiran, J. Van Geffen, A. Warfield. Using Lightweight Formal Methods to Validate a Key-Value Storage
  Node in Amazon S3. *SOSP* 2021, 836–850. https://doi.org/10.1145/3477132.3483540
  — The real system compared with a simple reference model over random operations and crashes: the property tests.
- **[Claessen 2000]** K. Claessen, J. Hughes. QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs.
  *ICFP* 2000, 268–279. https://doi.org/10.1145/351240.351266
  — Property-based testing.
- **[Steele 2014]** G. L. Steele Jr., D. Lea, C. H. Flood. Fast Splittable Pseudorandom Number Generators. *OOPSLA*
  2014, 453–472. https://doi.org/10.1145/2660193.2660195
  — SplitMix64, the seeded generator of every randomized test (`Rng`).
- **[Lamport 2002]** L. Lamport. Specifying Systems: The TLA+ Language and Tools for Hardware and Software Engineers.
  Addison-Wesley, 2002. https://lamport.azurewebsites.net/tla/book.html
  — TLA+, the language of `spec/Journal.tla` and `spec/Merge.tla`.
- **[Yu 1999]** Y. Yu, P. Manolios, L. Lamport. Model Checking TLA+ Specifications. *CHARME* 1999, LNCS 1703, 54–66.
  https://doi.org/10.1007/3-540-48153-2_6
  — TLC, the model checker run by `tools/tlc.sh`.
- **[Newcombe 2015]** C. Newcombe, T. Rath, F. Zhang, B. Munteanu, M. Brooker, M. Deardeuff. How Amazon Web Services
  Uses Formal Methods. *Communications of the ACM* 58(4), 66–73, 2015. https://doi.org/10.1145/2699417
  — Model checking finds protocol bugs that tests miss; TLC found one in the journal's recovery rule here.
- **[Kingsbury 2020]** K. Kingsbury, P. Alvaro. Elle: Inferring Isolation Anomalies from Experimental Observations.
  *PVLDB* 14(3), 268–280, 2020. https://doi.org/10.14778/3430915.3430918
  — Jepsen's checker of isolation; the bank test follows Jepsen's, Elle comes with replication.

## Benchmarking and statistics

- **[Raasveldt 2018]** M. Raasveldt, P. Holanda, T. Gubner, H. Mühleisen. Fair Benchmarking Considered Difficult:
  Common Pitfalls in Database Performance Testing. *DBTest* 2018, 1–6. https://doi.org/10.1145/3209950.3209955
  — The fairness rules of the comparison: the same data, the same answers, each side set up as an expert would.
- **[Hoefler 2015]** T. Hoefler, R. Belli. Scientific Benchmarking of Parallel Computing Systems: Twelve Ways to Tell
  the Masses when Reporting Performance Results. *SC* 2015, article 73. https://doi.org/10.1145/2807591.2807644
  — Medians with distribution-free confidence intervals, the number of runs stated.
- **[Le Boudec 2010]** J.-Y. Le Boudec. Performance Evaluation of Computer and Communication Systems. EPFL Press, 2010.
  https://leboudec.github.io/perfeval/
  — Theorem 2.1: the confidence interval of a median from two order statistics, used by `bench/stats.ml`.
- **[Tene 2015]** G. Tene. How NOT to Measure Latency. Talk, Strange Loop 2015, St. Louis.
  https://www.youtube.com/watch?v=lJ8ydIuPFeU ; HdrHistogram, http://hdrhistogram.org/ ; wrk2,
  https://github.com/giltene/wrk2
  — Coordinated omission and open-loop loads; log-linear histograms of every latency (`Histogram`).
- **[Little 1961]** J. D. C. Little. A Proof for the Queuing Formula: L = λW. *Operations Research* 9(3), 383–387,
  1961. https://doi.org/10.1287/opre.9.3.383
  — The throughput of group commit, λ = N / W.
- **[Gray 1994]** J. Gray, P. Sundaresan, S. Englert, K. Baclawski, P. J. Weinberger. Quickly Generating
  Billion-Record Synthetic Databases. *SIGMOD* 1994, 243–252. https://doi.org/10.1145/191839.191886
  — Zipf-distributed keys for the traces of the cache study.
- **[Cooper 2010]** B. F. Cooper, A. Silberstein, E. Tam, R. Ramakrishnan, R. Sears. Benchmarking Cloud Serving
  Systems with YCSB. *SoCC* 2010, 143–154. https://doi.org/10.1145/1807128.1807152
  — The Zipf exponent 0.99 of YCSB, used for the traces.
