# References

The works Cepheus follows or measures itself against, and those behind what it does not build yet, by subject. Each
entry gives the authors, the title, the venue and the year, a link (a DOI where there is one, else the publisher's or
the authors' page), and what Cepheus took from it. Every entry was checked against the publisher's record or DBLP
(authors in order, exact title, venue, volume and year); a work that could not be checked is not listed. The design
documentation of other databases (PostgreSQL, SQLite, Oracle, Datomic, RocksDB, Neo4j, FoundationDB, CockroachDB) is
cited on the [comparison](comparison.md) page.

## Storage: log-structured merge-trees

- **[O'Neil 1996]** P. O'Neil, E. Cheng, D. Gawlick, E. O'Neil. The Log-Structured Merge-Tree (LSM-Tree). *Acta
  Informatica* 33(4), 351–385, 1996. https://doi.org/10.1007/s002360050048
  — The structure of the store: changes in a small component in memory, merged in bulk into sorted components on
  disk by a merge of sorted runs (the "rolling merge" of C0 into C1, and of each component into the next); the cost
  of a merge as the size ratio plus one.
- **[Luo 2020]** C. Luo, M. J. Carey. LSM-based Storage Techniques: A Survey. *The VLDB Journal* 29(1), 393–418, 2020.
  https://doi.org/10.1007/s00778-019-00555-y
  — The vocabulary and the costs of leveling and tiering (write amplification $O(T \cdot L)$ and $O(L)$, runs a read visits $L$
  and $T \cdot L$), from which Cepheus' leveling with ratio 4 is chosen (theory, section 9).
- **[Dong 2017]** S. Dong, M. Callaghan, L. Galanis, D. Borthakur, T. Savor, M. Stumm. Optimizing Space Amplification
  in RocksDB. *CIDR* 2017. https://cidrdb.org/cidr2017/papers/p82-dong-cidr17.pdf
  — Space and write amplification in RocksDB (with dynamic level sizes and a size ratio of 10, space amplification
  stays under 1.111); with RocksDB's `bytes_per_sync` option, the reason a merge forces its file every 8 MiB while
  clients write. A full copy of the base kept beside it makes space amplification 2: why no run is kept outside the
  chain.
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
- **[RFC 3720]** J. Satran, K. Meth, C. Sapuntzakis, M. Chadalapaka, E. Zeidner. Internet Small Computer Systems
  Interface (iSCSI). *RFC 3720*, IETF, April 2004. https://doi.org/10.17487/RFC3720
  — The CRC-32C as a standard defines it (section 12.1: the generator polynomial 0x11EDC6F41, citing [Castagnoli 1993];
  the bits complemented before and after), and five examples with their CRCs (appendix B.4), which `test/unit.ml`
  checks.
- **[Intel SDM]** Intel. Intel 64 and IA-32 Architectures Software Developer's Manual, volume 2A, "CRC32 — Accumulate
  CRC32 Value". https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
  — The instruction Cepheus computes its CRC with on x86-64: the polynomial 11EDC6F41H, 1, 2, 4 or 8 bytes a step,
  present when CPUID.01H:ECX.SSE4_2 (bit 20) is set, an invalid-opcode fault otherwise.
- **[Arm ARM]** Arm. Arm Architecture Reference Manual for A-profile architecture (DDI 0487), the instructions CRC32CB
  to CRC32CX. https://developer.arm.com/documentation/ddi0487/latest; and Arm C Language Extensions (ACLE), "CRC32
  intrinsics". https://arm-software.github.io/acle/main/acle.html
  — The arm64 side: the same polynomial, optional in Armv8.0 and mandatory from Armv8.1 (FEAT_CRC32), reached from C
  by `__crc32cd` and `__crc32cb`; Linux tells a program whether the processor has them (`HWCAP_CRC32`).
- **[x86-64 psABI]** System V Application Binary Interface, AMD64 Architecture Processor Supplement.
  https://gitlab.com/x86-psABIs/x86-64-ABI
  — Its table "Micro-Architecture Levels": x86-64-v2 is CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSE4_1, SSE4_2 and SSSE3.
- **[Koopman 2002]** P. Koopman. 32-Bit Cyclic Redundancy Codes for Internet Applications. *DSN* 2002, 459–468.
  https://doi.org/10.1109/DSN.2002.1028931
  — What CRC-32C detects for certain (its Hamming distance by length) and with what probability the rest escapes.
- **[Alagappan 2018]** R. Alagappan, A. Ganesan, E. Lee, A. Albarghouthi, V. Chidambaram, A. C. Arpaci-Dusseau,
  R. H. Arpaci-Dusseau. Protocol-Aware Recovery for Consensus-Based Storage. *FAST* 2018, 15–32.
  https://www.usenix.org/conference/fast18/presentation/alagappan
  — One damaged sector can lose confirmed data in replicated systems; the rule of a Cepheus cluster's damaged log (a
  damaged server neither votes nor stands for election until it is repaired: [the
  server](server.md#a-damaged-log-the-2018-rule)), and why a single machine refuses to open rather than cut.

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
- **[Linux cgroup v2]** The Linux Kernel documentation, Control Group v2, section "Memory Ownership".
  https://docs.kernel.org/admin-guide/cgroup-v2.html
  — A page of the page cache stays charged to the control group that brought it in; `POSIX_FADV_DONTNEED` gives it
  up. Why the measures larger than memory drop the files' pages before each side
  ([benchmarks](benchmarks.md#compressed-runs-and-journal-2026-11-09-at-10-million-facts)).

## Indexes and compression

- **[Weiss 2008]** C. Weiss, P. Karras, A. Bernstein. Hexastore: Sextuple Indexing for Semantic Web Data Management.
  *PVLDB* 1(1), 1008–1019, 2008. https://doi.org/10.14778/1453856.1453965
  — Triples in every order; Cepheus keeps two orders, because dense thing numbers make "by thing" an array.
- **[Neumann 2008]** T. Neumann, G. Weikum. RDF-3X: a RISC-style Engine for RDF. *PVLDB* 1(1), 647–659, 2008.
  https://doi.org/10.14778/1453856.1453927
  — Sorted triple orders, compressed; the third order (property, thing) is weighed for data larger than memory.
- **[Goldstein 1998]** J. Goldstein, R. Ramakrishnan, U. Shaft. Compressing Relations and Indexes. *ICDE* 1998,
  370–379. https://doi.org/10.1109/ICDE.1998.655800
  — The frame of reference: the values of a page stored from their least, each in the bits its range needs, any one
  decoded alone. Every block of a run of format 7 and every column of the journal's format 2 is coded so.
- **[Zukowski 2006]** M. Zukowski, S. Héman, N. Nes, P. Boncz. Super-Scalar RAM-CPU Cache Compression. *ICDE* 2006, 59.
  https://doi.org/10.1109/ICDE.2006.150
  — PFOR and PFOR-DELTA: the frame of reference in blocks of 128 values for columns, decoded in a few cycles a value,
  the rare outliers patched apart. Cepheus takes the blocks of 128 and the frame of reference, without patching (a
  value is read in $O(1)$, never by walking the exceptions), and deltas where they code shorter.
- **[Lemire 2015]** D. Lemire, L. Boytsov. Decoding Billions of Integers per Second through Vectorization. *Software:
  Practice and Experience* 45(1), 1–29, 2015. https://doi.org/10.1002/spe.2203
  — Binary packing of blocks, its scalar and vectorized decoders measured: Cepheus' fields are read the scalar way, one
  unaligned 8-byte load, a shift and a mask (OCaml has no SIMD), as their non-vectorized binary packing does.
- **[Kuschewski 2023]** M. Kuschewski, D. Sauerwein, A. Alhomssi, V. Leis. BtrBlocks: Efficient Columnar Compression
  for Data Lakes. *Proc. ACM Manag. Data* 1(2), article 118 (SIGMOD 2023). https://doi.org/10.1145/3589263
  — The coding chosen per block by what makes it shortest: the journal's columns take a frame of reference or deltas
  block by block, the row blocks their things from the least or by gaps.
- **[Ailamaki 2001]** A. Ailamaki, D. J. DeWitt, M. D. Hill, M. Skounakis. Weaving Relations for Cache Performance.
  *VLDB* 2001, 169–180. http://www.vldb.org/conf/2001/P169.pdf
  — PAX: inside a page, the values of each attribute together. Measured for the thing blocks (a column a property in a
  block of 128 things): a lookup of a thing touched one cache line a property. The blocks keep a record a thing for
  the properties each thing has at most once (the row store PAX compares against) and columns only for the others;
  the order by property is the columns.
- **[Vigna 2013]** S. Vigna. Quasi-Succinct Indices. *WSDM* 2013, 83–92. https://doi.org/10.1145/2433396.2433409
  — Elias-Fano coding of a sorted list of $n$ values below $u$ in at most $2 + \lceil \log_2(u/n) \rceil$ bits each: the bound used to
  weigh the order by property against the information in the data (theory, section 11).
- **[Vigna 2016]** S. Vigna. An Experimental Exploration of Marsaglia's xorshift Generators, Scrambled. *ACM
  Transactions on Mathematical Software* 42(4), article 30, 2016. https://arxiv.org/abs/1402.6246 (the extended
  version)
  — Its multiplier M32 = 2685821657736338717 (0x2545F4914F6CDD1D, table IV, the one of xorshift64*) is the constant of
  the text hash of the runs' dictionaries.
- **[Neumann 2011]** T. Neumann, G. Moerkotte. Characteristic Sets: Accurate Cardinality Estimation for RDF Queries
  with Multiple Joins. *ICDE* 2011, 984–994. https://doi.org/10.1109/ICDE.2011.5767868
  — Things grouped by the set of properties they have: a way, not taken yet, to cut thing blocks by kind of thing so
  that a block of invoices holds no absent field.
- **[Binnig 2009]** C. Binnig, S. Hildenbrand, F. Färber. Dictionary-based Order-preserving String Compression for
  Main Memory Column Stores. *SIGMOD* 2009, 283–296. https://doi.org/10.1145/1559845.1559877
  — An order-preserving dictionary would allow ranges and prefixes on texts; the runs' dictionaries find a text by a
  hash table and keep no order (format 6's sorted list of ids is gone with format 7).

- **[Jacobson 1989]** G. Jacobson. Space-efficient Static Trees and Graphs. *FOCS* 1989, 549–554.
  https://doi.org/10.1109/SFCS.1989.63533
  — The rank directory: a bit vector with counts stored every few words answers "how many ones before position i" in
  constant time. Each part of a run keeps one by thing (presence bits for 32 thing ids and the count before them, a
  quarter of a byte a thing id).
- **[Knuth 1998]** D. E. Knuth. *The Art of Computer Programming, Volume 3: Sorting and Searching*, 2nd edition.
  Addison-Wesley, 1998. ISBN 0-201-89685-0.
  — Section 6.4, hashing with linear probing: the runs' text tables, at most half full (about 1.5 probes for a text
  that is there, 2.5 for one that is not). Section 5.2.5, sorting by distribution: the counting sort and the stable least-significant-digit radix sort that
  sort a large group's facts (by thing, by property, then by value inside each property, 11-bit digits), and a change's
  sink heads past 64 runs, and the whole sorts of an answer whose first keys are inline words (`Top.sort_radix`: the
  keys' words one after the other in one int, 11-bit digits). Section 5.2.4, sorting by merging: the natural merge
  that sorts a change's sink heads, which come as a few ascending runs.
- **[Herf 2001]** M. Herf. Radix Tricks. 2001. http://stereopsis.com/radix.html
  — The counts of every pass of a radix sort made in one read of the keys, and a pass skipped when every key has the
  same digit there: `Top.sort_radix`.
- **[Graefe 2011]** G. Graefe. Modern B-Tree Techniques. *Foundations and Trends in Databases* 3(4), 2011, 203–402.
  https://doi.org/10.1561/1900000028
  — Keys of several columns in one B-tree (PostgreSQL's index on `(client, date)`), which reads the latest rows of
  each client from the index: Cepheus has no index of two properties, so `Each` with `Limit` reads every row of the
  question once.
- **[Leis 2014]** V. Leis, P. Boncz, A. Kemper, T. Neumann. Morsel-Driven Parallelism: A NUMA-Aware Query
  Evaluation Framework for the Many-Core Age. *SIGMOD* 2014, 743–754. https://doi.org/10.1145/2588555.2610507
  — Work cut into small pieces ("morsels") that worker threads take in turn from a shared dispatcher, so that the
  load balances itself without a plan. A large group's chunks are taken this way by the domains, as are the slices of
  a question's first variable (`Query.fold`).
- **[Bentley 1976]** J. L. Bentley, A. C.-C. Yao. An Almost Optimal Algorithm for Unbounded Searching. *Information
  Processing Letters* 5(3), 82–87, 1976. https://doi.org/10.1016/0020-0190(76)90071-5
  — Exponential (galloping) search: the seeks of the leapfrog intersection (`Query.gallop`): steps of 1, 2, 4, ...
  from the last place, then a binary search, $O(\log d)$ for a place $d$ further. Until format 7, a merge also placed the
  other runs' texts among the largest run's sorted list this way.

- **[Abadi 2007]** D. J. Abadi, A. Marcus, S. R. Madden, K. Hollenbach. Scalable Semantic Web Data Management Using
  Vertical Partitioning. *VLDB* 2007, 411–422. https://www.vldb.org/conf/2007/papers/research/p411-abadi.pdf
  — Vertical partitioning of triples: one two-column table (subject, object) a property, sorted by subject. Run format
  8's column order: each property's rows apart, in thing order, so a lookup reads one property's bytes and the
  triangles read `follows` alone (2.2 MB of a 70 MB run).

## Joins

- **[Atserias 2008]** A. Atserias, M. Grohe, D. Marx. Size Bounds and Query Plans for Relational Joins. *FOCS* 2008,
  739–748. https://doi.org/10.1109/FOCS.2008.43 ; *SIAM Journal on Computing* 42(4), 1737–1767, 2013.
  https://doi.org/10.1137/110859440
  — The AGM bound: the largest answer of a conjunctive query from the sizes of its inputs ($N^{1.5}$ for a triangle).
- **[Ngo 2012]** H. Q. Ngo, E. Porat, C. Ré, A. Rudra. Worst-case Optimal Join Algorithms. *PODS* 2012, 37–48.
  https://doi.org/10.1145/2213556.2213565 ; *Journal of the ACM* 65(3), 2018. https://doi.org/10.1145/3180143
  — The first join algorithm that meets the AGM bound, and the proof that binary-join plans cannot.
- **[Ngo 2013]** H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms. *ACM
  SIGMOD Record* 42(4), 5–16, 2013. https://doi.org/10.1145/2590989.2590991
  — Generic Join, the algorithm of every question, and the argument for its bound.
- **[Veldhuizen 2014]** T. L. Veldhuizen. Leapfrog Triejoin: A Simple, Worst-Case Optimal Join Algorithm. *ICDT* 2014,
  96–106. https://doi.org/10.5441/002/icdt.2014.13
  — The leapfrog intersection of a level's sorted slices (a thing's values, a value's things): the iterators in key
  order, each seeking the largest key in turn; run format 8's columns give the slices in order (`Query.leapfrog`).
  The bound with seeks within a log factor of AGM; the engine reads a slice only when it is at most 8 times the
  smallest, so the tested bound stays within a constant of Generic Join's.
- **[Aberger 2016]** C. R. Aberger, S. Tu, K. Olukotun, C. Ré. EmptyHeaded: A Relational Engine for Graph Processing.
  *SIGMOD* 2016, 431–446. https://doi.org/10.1145/2882903.2915213
  — A worst-case optimal engine for graph queries.
- **[Freitag 2020]** M. J. Freitag, M. Bandle, T. Schmidt, A. Kemper, T. Neumann. Adopting Worst-Case Optimal Joins in
  Relational Database Systems. *PVLDB* 13(11), 1891–1904, 2020. https://doi.org/10.14778/3407790.3407797
  — In practice the order of the variables matters most.
- **[Mhedhbi 2019]** A. Mhedhbi, S. Salihoglu. Optimizing Subgraph Queries by Combining Binary and Worst-Case Optimal
  Joins. *PVLDB* 12(11), 1692–1704, 2019. https://doi.org/10.14778/3342263.3342643
  — The cost-based choice of the variable order.
- **[Selinger 1979]** P. G. Selinger, M. M. Astrahan, D. D. Chamberlin, R. A. Lorie, T. G. Price. Access Path Selection
  in a Relational Database Management System. *SIGMOD* 1979, 23–34. https://doi.org/10.1145/582095.582099
  — The dynamic program over subsets that chooses the order of joins: the best plan of a set from the best plans of
  its subsets, the size of each subset's result estimated once, whatever the order. `Query.order` runs it over the
  sets of a question's variables.
- **[Hellerstein 1993]** J. M. Hellerstein, M. Stonebraker. Predicate Migration: Optimizing Queries with Expensive
  Predicates. *SIGMOD* 1993, 267–276. https://doi.org/10.1145/170035.170078
  — Where a test goes in a plan: a cheap, selective one before the steps it saves. `Query.order` places a field of
  a row (a leaf: one value, in no other pattern) after the filters that follow its row, so that its lookup is made
  for the rows they keep only.
- **[Garwood 1936]** F. Garwood. Fiducial Limits for the Poisson Distribution. *Biometrika* 28(3–4), 437–442, 1936.
  https://doi.org/10.1093/biomet/28.3-4.437
  — The upper bound of a Poisson mean from a count, half a chi-square quantile: the most hopeful yield of a sorted
  page's walk in the index's order, from the rows it found; the walk gives up when even that yield cannot fill the
  page within its budget (`Top`).
- **[Wilson 1931]** E. B. Wilson, M. M. Hilferty. The Distribution of Chi-Square. *Proceedings of the National Academy
  of Sciences* 17(12), 684–688, 1931. https://doi.org/10.1073/pnas.17.12.684
  — The cube-root approximation of a chi-square quantile, which gives Garwood's bound without a table (within 0.2 %
  for 0 to 199 rows).
- **[Wang 2023]** Y. R. Wang, M. Willsey, D. Suciu. Free Join: Unifying Worst-Case Optimal and Traditional Joins.
  *Proceedings of the ACM on Management of Data* 1(2), 1–23 (SIGMOD 2023). https://doi.org/10.1145/3589295
  — The mix of binary and worst-case optimal joins; Cepheus keeps one way, Generic Join.
- **[Khayyat 2015]** Z. Khayyat, W. Lucia, M. Singh, M. Ouzzani, P. Papotti, J.-A. Quiané-Ruiz, N. Tang, P. Kalnis.
  Lightning Fast and Space Efficient Inequality Joins. *PVLDB* 8(13), 2074–2085, 2015.
  https://doi.org/10.14778/2831360.2831362
  — Joins on $<$ and $\le$ read from sorted columns instead of a cross product followed by a filter, which is what
  the systems they describe ran. `Less` takes the seek of one side's sorted values from the other's value: once one
  variable is bound, the other's candidates are a range of the property's sorted index (`Query.fold`).
- **[Pérez 2009]** J. Pérez, M. Arenas, C. Gutierrez. Semantics and Complexity of SPARQL. *ACM Transactions on
  Database Systems* 34(3), 1–45, 2009. https://doi.org/10.1145/1567274.1567278
  — The meaning of SPARQL's `OPTIONAL` (a left outer join of sets of bindings), and the *well-designed* patterns,
  those whose answer does not depend on where the optional part is joined. `Optional` is one pattern whose variable
  is in no other item: a well-designed pattern, bound last (`Ask.expand`).
- **[IEEE 754-2019]** IEEE Standard for Floating-Point Arithmetic. IEEE Std 754-2019.
  https://doi.org/10.1109/IEEESTD.2019.8766229
  — totalOrder (section 5.10): one order of every float, $-\mathrm{NaN} < -\infty < \dots < -0 < +0 < \dots <
  +\infty < +\mathrm{NaN}$. `Sort`, the ranges and `Less` on floats compare in it (`Value.total_order`).

## Reports

- **[Hyndman 1996]** R. J. Hyndman, Y. Fan. Sample Quantiles in Statistical Packages. *The American Statistician*
  50(4), 361–365, 1996. https://doi.org/10.1080/00031305.1996.10473566
  — The nine definitions of a sample quantile that statistical packages use; `Quantile` is their definition 7 (R's and
  NumPy's default, PostgreSQL's `percentile_cont`), `discrete = true` their definition 1 (`percentile_disc`).
- **[Hoare 1961]** C. A. R. Hoare. Algorithm 65: Find. *Communications of the ACM* 4(7), 321–322, 1961.
  https://doi.org/10.1145/366622.366647
  — Selection: the k-th of n values by partitions about a pivot on one side only, linear on average; a quantile's
  rank in Cepheus, on a group's different values weighted by their counts.
- **[Floyd 1975]** R. W. Floyd, R. L. Rivest. Expected Time Bounds for Selection. *Communications of the ACM* 18(3),
  165–172, 1975. https://doi.org/10.1145/360680.360691
  — The expected number of comparisons of selection, and a faster sampling variant; Cepheus keeps Hoare's with a
  median-of-three pivot.
- **[Musser 1997]** D. R. Musser. Introspective Sorting and Selection Algorithms. *Software: Practice and Experience*
  27(8), 983–993, 1997. https://doi.org/10.1002/(SICI)1097-024X(199708)27:8%3C983::AID-SPE117%3E3.0.CO;2-%23
  — Introselect: past a bound on the partitions, the rest sorted, so that no input makes selection quadratic.
- **[Welford 1962]** B. P. Welford. Note on a Method for Calculating Corrected Sums of Squares and Products.
  *Technometrics* 4(3), 419–420, 1962. https://doi.org/10.1080/00401706.1962.10490022
  — The one-pass update of a mean and a sum of squared deviations; accurate in floats, but its last digits depend on
  the order of the values, so Cepheus does not use it.
- **[Youngs 1971]** E. A. Youngs, E. M. Cramer. Some Results Relevant to Choice of Sum and Sum-of-Product Algorithms.
  *Technometrics* 13(3), 657–665, 1971. https://doi.org/10.1080/00401706.1971.10488826
  — The update PostgreSQL's `float8` variance and standard deviation run (its `float8_accum`).
- **[Chan 1983]** T. F. Chan, G. H. Golub, R. J. LeVeque. Algorithms for Computing the Sample Variance: Analysis and
  Recommendations. *The American Statistician* 37(3), 242–247, 1983. https://doi.org/10.1080/00031305.1983.10483115
  — Why the textbook formula $\sum x^2 - (\sum x)^2 / n$ loses its digits in floats when the values are far from 0, and
  how to merge two parts' sums; with exact sums, Cepheus computes that formula's numerator with no loss.
- **[Neal 2015]** R. M. Neal. Fast exact summation using small and large superaccumulators. arXiv:1505.05571, 2015.
  https://arxiv.org/abs/1505.05571
  — Sums of floats kept exactly, as integers at each binary place, rounded once; Cepheus's exact sums are of that
  family, with parts of 30 bits carried lazily.
- **[RFC 8536]** A. Olson, P. Eggert, K. Murchison. The Time Zone Information Format (TZif). IETF RFC 8536, 2019.
  https://www.rfc-editor.org/rfc/rfc8536
  — The format of the zone database's files that Cepheus reads: transitions, time types, and the footer's POSIX TZ
  string for the times after the last transition (with its extensions: hours from -167 to 167, a year of summer time).
- **[tz]** The IANA Time Zone Database. https://www.iana.org/time-zones
  — The rules of the world's local times, which every system ships (`tzdata`) and updates several times a year.
- **[Hinnant 2013]** H. Hinnant. chrono-Compatible Low-Level Date Algorithms. 2013.
  https://howardhinnant.github.io/date_algorithms.html
  — The days of the proleptic Gregorian calendar from a year, month and day, and back, with no table: `Zone`'s calendar.
- **[ISO 8601]** ISO 8601-1:2019. Date and time — Representations for information interchange, part 1.
  https://www.iso.org/standard/70907.html
  — Weeks from Monday: `Trunc(d, "week")`.
- **[PostgreSQL aggregates]** PostgreSQL 18 documentation, 9.21 Aggregate Functions, and 9.9.2 date_trunc.
  https://www.postgresql.org/docs/18/functions-aggregate.html ,
  https://www.postgresql.org/docs/18/functions-datetime.html#FUNCTIONS-DATETIME-TRUNC
  — `avg`, `count(DISTINCT)`, `array_agg`, `string_agg`, `percentile_cont`, `percentile_disc`, `stddev`, `variance`
  and `date_trunc` with a zone, the forms the tutorials set beside Cepheus's.

## Windows

- **[Leis 2015]** V. Leis, K. Kundhikanjana, A. Kemper, T. Neumann. Efficient Processing of Window Functions in
  Analytical SQL Queries. *PVLDB* 8(10), 1058–1069, 2015. https://doi.org/10.14778/2794367.2794375
  — The window operator of a main-memory database: the rows partitioned and sorted once, then each frame's aggregate
  by cumulative aggregation (a frame that only grows), removable cumulative aggregation (a sum that takes out the row
  leaving the frame; in floats it drifts, which Cepheus's exact sums avoid) or a segment tree (any frame, $O(\log n)$ a
  row). `Running`, `Rank` and `Prev` are computed by the first two.
- **[Lemire 2006]** D. Lemire. Streaming Maximum-Minimum Filter Using No More than Three Comparisons per Element.
  *Nordic Journal of Computing* 13(4), 328–339, 2006. https://arxiv.org/abs/cs/0610046
  — The least or largest value of a sliding window by a monotone queue of its candidates, each value in and out once:
  `Running(Min(x), last = n)` and `Max`, $O(1)$ amortized a row where a segment tree takes $O(\log n)$.
- **[PostgreSQL windows]** PostgreSQL 18 documentation, 3.5 Window Functions, 4.2.8 Window Function Calls, 9.22 Window
  Functions, and SELECT's DISTINCT ON. https://www.postgresql.org/docs/18/tutorial-window.html ,
  https://www.postgresql.org/docs/18/sql-expressions.html#SYNTAX-WINDOW-FUNCTIONS ,
  https://www.postgresql.org/docs/18/functions-window.html , https://www.postgresql.org/docs/18/sql-select.html#SQL-DISTINCT
  — `OVER`, `PARTITION BY`, the frames `ROWS` and `RANGE` (`RANGE UNBOUNDED PRECEDING` the default with an `ORDER BY`),
  `rank`, `dense_rank`, `row_number`, `lag`, `LATERAL` and `DISTINCT ON`, the forms the tutorials set beside Cepheus's.

## Transactions and isolation

- **[Codd 1970]** E. F. Codd. A Relational Model of Data for Large Shared Data Banks. *Communications of the ACM*
  13(6), 377–387, 1970. https://doi.org/10.1145/362384.362685
  — The foreign key: a value of one relation that is the key of another, as a link that names a kind
  (`Link(to = "client")`) is; what it does on delete is SQL's referential actions (ISO/IEC 9075-2: `ON DELETE
  CASCADE`, `SET NULL`, `SET DEFAULT`, `RESTRICT`, `NO ACTION`), of which Cepheus has `cascade`, `clear` and `refuse`.
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
  — Transactions in an order fixed in advance, with no locks: the single writer; a database partitioned over several
  machines that way is not built.

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

## Rules: Datalog, materialisation and its maintenance

- **[Abiteboul 1995]** S. Abiteboul, R. Hull, V. Vianu. *Foundations of Databases*. Addison-Wesley, 1995. Free copy:
  http://webdam.inria.fr/Alice/
  — Datalog, its least model and its evaluation (part D, chapters 12-13, semi-naive among them): the semantics of
  Cepheus' rules (G17).
- **[Bancilhon 1986]** F. Bancilhon, R. Ramakrishnan. An Amateur's Introduction to Recursive Query Processing
  Strategies. *SIGMOD* 1986, 16–52. https://doi.org/10.1145/16894.16859
  — Semi-naive evaluation (§3.2.2: the differential instead of the whole at each step): the evaluation of each group's
  consequences.
- **[Ramakrishnan 1990]** R. Ramakrishnan, D. Srivastava, S. Sudarshan. Rule Ordering in Bottom-Up Fixpoint
  Evaluation of Logic Programs. *VLDB* 1990, 359–371.
  — The semi-naive property, each inference made exactly once: the work bound of a group's reasoning.
- **[Feeley 1987]** M. Feeley, G. Lapalme. Using Closures for Code Generation. *Computer Languages* 12(1), 47–66, 1987.
  https://doi.org/10.1016/0096-0551(87)90012-9
  — Code compiled to closures without generating code: each rule compiled once into its plans.
- **[Gupta 1993]** A. Gupta, I. S. Mumick, V. S. Subrahmanian. Maintaining Views Incrementally. *SIGMOD* 1993,
  157–166. https://doi.org/10.1145/170035.170066
  — Counting (for nonrecursive views) and DRed: the two algorithms B/F was chosen over; counting shown wrong here on
  inverse properties.
- **[Motik 2015]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Incremental Update of Datalog Materialisation: the
  Backward/Forward Algorithm. *AAAI* 2015, 1560–1568. https://doi.org/10.1609/aaai.v29i1.9409
  — B/F, the retraction algorithm, and its measured gains over DRed.
- **[Motik 2019]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Maintenance of Datalog Materialisations Revisited.
  *Artificial Intelligence* 269, 76–136, 2019. https://doi.org/10.1016/j.artint.2018.12.004
  — Counting made correct on recursive rules, and FBF: the later refinements, to be measured before they are taken.
- **[Motik 2014]** B. Motik, Y. Nenov, R. Piro, I. Horrocks, D. Olteanu. Parallel Materialisation of Datalog Programs
  in Centralised, Main-Memory RDF Systems. *AAAI* 2014, 129–137. https://doi.org/10.1609/aaai.v28i1.8730
  — RDFox: the triple table with hash indexes and chains the working set follows; its published rates, the yardstick
  of the benchmarks.
- **[Urbani 2016]** J. Urbani, C. Jacobs, M. Krötzsch. Column-Oriented Datalog Materialization for Large Knowledge
  Graphs. *AAAI* 2016, 258–264. https://doi.org/10.1609/aaai.v30i1.9993
  — VLog: materialisation over sorted columns, the model of a load's sorted prefix (large groups); its published
  one-thread rate, beside ours.
- **[Scholz 2016]** B. Scholz, H. Jordan, P. Subotić, T. Westmann. On Fast Large-Scale Program Analysis in Datalog.
  *CC* 2016, 196–206. https://doi.org/10.1145/2892208.2892226
  — Soufflé, Datalog compiled to C++: its published times, beside ours.
- **[Subotic 2018]** P. Subotić, H. Jordan, L. Chang, A. Fekete, B. Scholz. Automatic Index Selection for Large-Scale
  Datalog Computation. *PVLDB* 12(2), 141–153, 2018. https://doi.org/10.14778/3282495.3282500
  — The indexes a rule set needs, chosen from the searches its plans make: in a large group, a derived fact joins only
  the chains some plan reads; a change's sink facts, which no plan searches, join no table at all.
- **[Zhao 2020]** D. Zhao, P. Subotić, B. Scholz. Debugging Large-scale Datalog: A Scalable Provenance Evaluation
  Strategy. *ACM TOPLAS* 42(2), 2020. https://doi.org/10.1145/3379446
  — Provenance stored per fact (rule and proof height) at a published 1.31× run time: the alternative to Cepheus'
  `why` computed when asked.
- **[Hu 2019]** P. Hu, B. Motik, I. Horrocks. Modular Materialisation of Datalog Programs. *AAAI* 2019, 2859–2866.
  https://doi.org/10.1609/aaai.v33i01.33012859
  — Modules for transitive and symmetric properties: the closure module.
- **[Hu 2022]** P. Hu, B. Motik, I. Horrocks. Modular Materialisation of Datalog Programs. *Artificial Intelligence*
  308, 103726, 2022. https://doi.org/10.1016/j.artint.2022.103726
  — The journal version: modules for transitivity, symmetry and chains, LUBM-LE 1,268 s → 339 s with them, small
  deletions in 1 s against 585 s; the module's insertion here, its retraction by walks not yet.
- **[Apt 1988]** K. R. Apt, H. A. Blair, A. Walker. Towards a Theory of Declarative Knowledge. In J. Minker (ed.),
  *Foundations of Deductive Databases and Logic Programming*, Morgan Kaufmann, 1988, 89–148.
  https://doi.org/10.1016/B978-0-934613-40-8.50006-3
  — Stratified programs and their standard model, computed stratum by stratum: what a rule set with `Not` means.
- **[Przymusinski 1988]** T. C. Przymusinski. On the Declarative Semantics of Deductive Databases and Logic Programs.
  Same volume, 193–216. https://doi.org/10.1016/B978-0-934613-40-8.50009-9
  — The perfect model, which is that standard model: the facts Cepheus holds with `Not` and aggregates.
- **[Mumick 1990]** I. S. Mumick, H. Pirahesh, R. Ramakrishnan. The Magic of Duplicates and Aggregates. *VLDB* 1990,
  264–277. https://www.vldb.org/conf/1990/P264.PDF
  — Aggregates in recursive rules, stratified as negation is: an aggregate's body complete before its value.
- **[Tarjan 1972]** R. Tarjan. Depth-First Search and Linear Graph Algorithms. *SIAM Journal on Computing* 1(2),
  146–160, 1972. https://doi.org/10.1137/0201010
  — Strong components in linear time, found in reverse topological order: the order a closure from scratch is computed
  in.
- **[Nuutila 1995]** E. Nuutila. *Efficient Transitive Closure Computation in Large Digraphs*. Acta Polytechnica
  Scandinavica, Mathematics and Computing in Engineering Series No. 74, 1995.
  — Closure by strong components, a component's reach shared by its members: the union of successors' targets.
- **[Jones 1993]** N. D. Jones, C. K. Gomard, P. Sestoft. *Partial Evaluation and Automatic Program Generation*.
  Prentice Hall, 1993.
  — Partial evaluation, a program specialised on part of its input: the rules unfolded on the ontology's facts.
- **[W3C 2012]** W3C. OWL 2 Web Ontology Language Profiles (Second Edition). Recommendation, 11 December 2012, §4.3.
  https://www.w3.org/TR/owl2-profiles/
  — OWL 2 RL's rules (prp-dom, prp-trp, cax-sco, …), written over the ontology's facts with the property a variable:
  the form a rule with a variable property takes; its 78 rules in Tables 4 to 9, LIST[…] over RDF lists: the library
  `Cepheus.Owl`, rule by rule, and its templates.
- **[Motik 2015b]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Handling owl:sameAs via Rewriting. *AAAI* 2015, 231–237.
  https://doi.org/10.1609/aaai.v29i1.9187 (arXiv:1411.3622)
  — Equality by rewriting: a representative a class, the facts of the others outdated and skipped, the rules' constants
  rewritten too; a clique of n equal resources gives n² sameAs triples in 2n³ + n² + n derivations when axiomatised;
  rewriting 31.1× faster on Claros, 2.3× on UOBM (one thread, Table 3). The classes of equal things.
- **[Motik 2015c]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Combining Rewriting and Incremental Materialisation
  Maintenance for Datalog Programs with Equality. *IJCAI* 2015, 3127–3133.
  — B/F≈, retraction with rewritten equality: the finer algorithm Cepheus' Delete-Rederive of a class leaves for later.
- **[Tarjan 1975]** R. E. Tarjan. Efficiency of a Good But Not Linear Set Union Algorithm. *JACM* 22(2), 215–225, 1975.
  https://doi.org/10.1145/321879.321884
  — Union by size: a thing changes class O(log n) times over any sequence of merges.
- **[Ma 2006]** L. Ma, Y. Yang, Z. Qiu, G. T. Xie, Y. Pan, S. Liu. Towards a Complete OWL Ontology Benchmark. *ESWC*
  2006, 125–139 (as cited by [Motik 2015b]).
  — UOBM, LUBM with the axioms that make individuals equal: the shape of the UOBM-like benchmark.
- **[Fan 2019]** Z. Fan, J. Zhu, Z. Zhang, A. Albarghouthi, P. Koutris, J. M. Patel. Scaling-Up In-Memory Datalog
  Processing: Observations and Techniques. *PVLDB* 12(6), 695–708, 2019. https://doi.org/10.14778/3311880.3311886
  — Soufflé "runs out of memory when evaluating TC on G80K": transitive closure is where Datalog engines break.
- **[Henzinger 2015]** M. Henzinger, S. Krinninger, D. Nanongkai, T. Saranurak. Unifying and Strengthening Hardness
  for Dynamic Problems via the Online Matrix-Vector Multiplication Conjecture. *STOC* 2015, 21–30.
  https://doi.org/10.1145/2746539.2746609
  — Conditional lower bounds for decremental transitive closure: why no retraction algorithm is cheap in the worst case.
- **[Guo 2005]** Y. Guo, Z. Pan, J. Heflin. LUBM: A Benchmark for OWL Knowledge Base Systems. *Journal of Web
  Semantics* 3(2–3), 158–182, 2005. https://doi.org/10.1016/j.websem.2005.06.005
  — The shape of the benchmark's data (universities, departments, people, courses) and its ontology.
- **[Budiu 2023]** M. Budiu, T. Chajed, F. McSherry, L. Ryzhyk, V. Tannen. DBSP: Automatic Incremental View
  Maintenance for Rich Query Languages. *PVLDB* 16(7), 1601–1614, 2023. https://doi.org/10.14778/3587136.3587137
  — The delta rules of joins (a bilinear operator's change), which a live question's change is a case of; Sum and
  Count of rules kept by difference, as linear operators.
- **[Gjengset 2018]** J. Gjengset, M. Schwarzkopf, J. Behrens, L. T. Araújo, M. Ek, E. Kohler, M. F. Kaashoek,
  R. Morris. Noria: dynamic, partially-stateful data-flow for high-performance web applications. *OSDI* 2018,
  213–231. https://www.usenix.org/conference/osdi18/presentation/gjengset
  — Reads that differ by a parameter sharing one state: the templates of live questions, whose constants are
  parameters.

## Replication and many machines

- **[Ongaro 2014]** D. Ongaro, J. Ousterhout. In Search of an Understandable Consensus Algorithm. *USENIX ATC* 2014,
  305–319. https://www.usenix.org/conference/atc14/technical-sessions/presentation/ongaro
  — Raft, the algorithm of a Cepheus cluster ([the server](server.md#a-cluster-of-three-raft)), with its public TLA+
  specification.
- **[Verbitski 2017]** A. Verbitski, A. Gupta, D. Saha, M. Brahmadesam, K. Gupta, R. Mittal, S. Krishnamurthy,
  S. Maurice, T. Kharatishvili, X. Bao. Amazon Aurora: Design Considerations for High Throughput Cloud-Native
  Relational Databases. *SIGMOD* 2017, 1041–1052. https://doi.org/10.1145/3035918.3056101
  — "The log is the database": the journal is the only thing to replicate.
- **[Antonopoulos 2019]** P. Antonopoulos, A. Budovski, C. Diaconu, A. Hernandez Saenz, J. Hu, H. Kodavalla,
  D. Kossmann, S. Lingam, U. F. Minhas, N. Prakash, V. Purohit, H. Qu, C. S. Ravella, K. Reisteter, S. Shrotri,
  D. Tang, V. Wakade. Socrates: The New SQL Server in the Cloud. *SIGMOD* 2019, 1743–1756.
  https://doi.org/10.1145/3299869.3314047
  — Log, pages and compute separated: storage on object stores, not built.
- **[Ammar 2018]** K. Ammar, F. McSherry, S. Salihoglu, M. Joglekar. Distributed Evaluation of Subgraph Queries Using
  Worst-case Optimal Low-Memory Dataflows. *PVLDB* 11(6), 691–704, 2018. https://doi.org/10.14778/3184470.3184473
  — BiGJoin: Generic Join over many machines, not built; and its delta queries, the change of a join for added or
  removed facts, each new binding at the first pattern that matches an added fact: how a live question's change is
  computed (G21).

## The file vault

- **[Xia 2016]** W. Xia, Y. Zhou, H. Jiang, D. Feng, Y. Hua, Y. Hu, Q. Liu, Y. Zhang. FastCDC: a Fast and Efficient
  Content-Defined Chunking Approach for Data Deduplication. *USENIX ATC* 2016, 101–114.
  https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia
  — The Gear hash and normalized chunking (level 2, masks of 18 and 14 bits around 64 KiB): the vault's chunks.
- **[Aumasson 2013]** J.-P. Aumasson, S. Neves, Z. Wilcox-O'Hearn, C. Winnerlein. BLAKE2: simpler, smaller, fast as
  MD5. *ACNS* 2013, LNCS 7954, 119–135. https://doi.org/10.1007/978-3-642-38980-1_8 ; RFC 7693 (2015).
  — The keyed hash that names chunks and nodes (libsodium's `crypto_generichash`).
- **[Wu 2013]** H. Wu, B. Preneel. AEGIS: A Fast Authenticated Encryption Algorithm. *SAC* 2013, LNCS 8282, 185–201.
  https://doi.org/10.1007/978-3-662-43414-7_10 ; draft-irtf-cfrg-aegis-aead.
  — AEGIS-256, libsodium's `crypto_aead_aegis256`, which seals every chunk.
- **[Rogaway 2006]** P. Rogaway, T. Shrimpton. A Provable-Security Treatment of the Key-Wrap Problem. *EUROCRYPT*
  2006, LNCS 4004, 373–390. https://doi.org/10.1007/11761679_23
  — SIV, the synthetic nonce: a chunk's nonce is its keyed name, so it is sealed into the same bytes everywhere.
- **[Collet RFC 8878]** Y. Collet, M. Kucherawy. Zstandard Compression and the 'application/zstd' Media Type. RFC
  8878, 2021. https://www.rfc-editor.org/rfc/rfc8878 ; LZ4's block format: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
  — The cold and the warm codec, vendored at Zstandard 1.5.7 and LZ4 1.10.0.
- **[Merkle 1987]** R. C. Merkle. A Digital Signature Based on a Conventional Encryption Function. *CRYPTO* 1987,
  LNCS 293, 369–378. https://doi.org/10.1007/3-540-48184-2_32
  — The hash tree over the names of a vault's records, compared to find what a copy lacks.
- **[DeCandia 2007]** G. DeCandia, D. Hastorun, M. Jampani, G. Kakulapati, A. Lakshman, A. Pilchin, S. Sivasubramanian,
  P. Vosshall, W. Vogels. Dynamo: Amazon's Highly Available Key-value Store. *SOSP* 2007, 205–220.
  https://doi.org/10.1145/1294261.1294281
  — Anti-entropy by Merkle trees: walk the trees where their digests differ.
- **[Harnik 2010]** D. Harnik, B. Pinkas, A. Shulman-Peleg. Side Channels in Cloud Services: Deduplication in Cloud
  Storage. *IEEE Security & Privacy* 8(6), 40–47, 2010. https://doi.org/10.1109/MSP.2010.187
  — Deduplication as an oracle of what others store: why the vault deduplicates inside a key domain only.
- **[Douceur 2002]** J. R. Douceur, A. Adya, W. J. Bolosky, D. Simon, M. Theimer. Reclaiming Space from Duplicate
  Files in a Serverless Distributed File System. *ICDCS* 2002, 617–624. https://doi.org/10.1109/ICDCS.2002.1022312
  — Convergent encryption, which the vault does not use (it would show that two people hold one file).
- **[Corbató 1968]** F. J. Corbató. A Paging Experiment with the Multics System. MIT Project MAC, MAC-M-384, 1968.
  — CLOCK, the second chance: the cache of the vault's decoded nodes.

## The server

- **[Ongaro 2014b]** D. Ongaro. Consensus: Bridging Theory and Practice. PhD dissertation, Stanford University, 2014.
  https://web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf
  — Section 6.3, client sessions: "Each server's state machine maintains a session for each client ... latest serial
  number processed ... along with the associated response"; the server's session table (G14), with a floor so that
  many writes of a session are in flight.
- **[Terry 1994]** D. B. Terry, A. J. Demers, K. Petersen, M. J. Spreitzer, M. M. Theimer, B. B. Welch. Session
  Guarantees for Weakly Consistent Replicated Data. *PDIS* 1994, 140–149. https://doi.org/10.1109/PDIS.1994.331722
  — "Read your writes" and "monotonic writes": what one connection's requests keep.
- **[RFC 4648]** S. Josefsson. The Base16, Base32, and Base64 Data Encodings. RFC 4648, 2006.
  https://www.rfc-editor.org/rfc/rfc4648
  — Section 5, base64url: the text of a token.
- **[RFC 7693]** M-J. Saarinen, J-P. Aumasson. The BLAKE2 Cryptographic Hash and Message Authentication Code (MAC).
  RFC 7693, 2015. https://www.rfc-editor.org/rfc/rfc7693
  — BLAKE2b-256, the hash a token is kept as (OCaml's `Digest.BLAKE256`).
- **[PostgreSQL 11.2]** PostgreSQL Global Development Group. Release notes of PostgreSQL 11.2 (and 10.7, 9.6.12,
  9.5.16, 9.4.21), 14 February 2019. https://www.postgresql.org/docs/release/11.2/
  — A failed fsync stops the server (PANIC) instead of being retried (`data_sync_retry` off): the server stops on a
  failed disk the same way.
- **[RFC 8446]** E. Rescorla. The Transport Layer Security (TLS) Protocol Version 1.3. RFC 8446, 2018.
  https://www.rfc-editor.org/rfc/rfc8446
  — The only TLS version the server and its clients accept.
- **[Kaloper-Meršinjak 2015]** D. Kaloper-Meršinjak, H. Mehnert, A. Madhavapeddy, P. Sewell. Not-Quite-So-Broken TLS:
  Lessons in Re-Engineering a Security Protocol Specification and Implementation. *USENIX Security* 2015.
  https://www.usenix.org/conference/usenixsecurity15/technical-sessions/presentation/kaloper-mersinjak
  — ocaml-tls, the TLS in OCaml weighed against OpenSSL (its ciphers are C too; not an OSS-Fuzz project): OpenSSL kept.
- **[sd_notify]** systemd. sd_notify(3), the readiness protocol: one datagram (`READY=1`) on `$NOTIFY_SOCKET`.
  https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
  — The server sends `READY=1` once its databases are open and its listeners listen, and `STOPPING=1` when it stops: a
  unit of `Type=notify` counts it started only then.
- **[Lamport 1986]** L. Lamport. On Interprocess Communication. Part I: Basic Formalism; Part II: Algorithms.
  *Distributed Computing* 1(2), 77–85 and 86–101, 1986. https://doi.org/10.1007/BF01786227,
  https://doi.org/10.1007/BF01786228
  — Safe, regular and atomic registers: a regular register lets two reads, one after the other, see a new value and
  then the old one; an atomic one does not. Local reads are atomic (G15); the design's first lease gave a regular one.
- **[Gray 1989]** C. G. Gray, D. R. Cheriton. Leases: An Efficient Fault-Tolerant Mechanism for Distributed File Cache
  Consistency. *SOSP* 1989, 202–210. https://doi.org/10.1145/74850.74870
  — The lease, a right that ends by itself after a time: what the design first proposed for local reads, left for
  the visibility number on one machine; between machines, a Raft leader serves its reads under a lease ([the
  server](server.md#reads-and-what-a-program-sees)).
- **[Moraru 2014]** I. Moraru, D. G. Andersen, M. Kaminsky. Paxos Quorum Leases: Fast Reads Without Sacrificing
  Writes. *SoCC* 2014. https://doi.org/10.1145/2670979.2671001
  — A lease holder reads locally only after it has assessed "whether an update to any of the leased objects is
  ongoing (i.e., in the process of being committed), and if not": reads by message-based leases need that wait to
  be linearizable; one machine's shared memory removes it. Local reads on other machines by such leases are not built.
- **[unix(7)]** The Linux man-pages project. unix(7): `SCM_RIGHTS`, "Send or receive a set of open file descriptors
  from another process". https://man7.org/linux/man-pages/man7/unix.7.html
  — How the server passes a local reader its run files and its visibility page (`server/fdpass_stubs.c`).
- **[mmap(2)]** The Linux man-pages project. mmap(2): `MAP_SHARED`, "Updates to the mapping are visible to other
  processes mapping the same region". https://man7.org/linux/man-pages/man2/mmap.2.html
  — The visibility page, mapped by the server and, read-only (`PROT_READ`), by every local reader.
- **[socket(7)]** The Linux man-pages project. socket(7): `SO_RCVTIMEO` and `SO_SNDTIMEO`, the timeouts of a socket's
  reads and writes. https://man7.org/linux/man-pages/man7/socket.7.html
  — How a blocked connection thread wakes to apply the idle limit.

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
  — Jepsen's checker of isolation; the bank test follows Jepsen's; Elle itself is not run.

- **[Serebryany 2012]** K. Serebryany, D. Bruening, A. Potapenko, D. Vyukov. AddressSanitizer: A Fast Address Sanity
  Checker. *USENIX ATC* 2012, 309–318. https://www.usenix.org/conference/atc12/technical-sessions/presentation/serebryany
  — The memory checker the C file of the CRC is fuzzed under: a read one byte outside its block stops the run.
- **\[libFuzzer]** The LLVM Project. libFuzzer – a library for coverage-guided fuzz testing.
  https://llvm.org/docs/LibFuzzer.html
  — The fuzzer of `test/fuzz_crc32c.c` and `test/fuzz_tls.c`: inputs mutated toward new paths of the code, every
  one checked against the CRC computed bit by bit, or against what the other side of a TLS conversation wrote.

## Method: solving and measuring

- **[Pólya 1945]** G. Pólya. *How to Solve It: A New Aspect of Mathematical Method*. Princeton University Press, 1945.
  https://press.princeton.edu/books/paperback/9780691164076/how-to-solve-it
  — "Understanding the problem" first: the unknown, the data, the condition; the first step of the
  [case of the seats](case-seats.md).
- **\[Heilmeier]** G. H. Heilmeier. The Heilmeier Catechism, the questions DARPA asks of every proposed research
  program. https://www.darpa.mil/about/heilmeier-catechism
  — What are you trying to do, how is it done today, what is new, how will you know you succeeded: the frame of the
  problem's statement.
- **[Jain 1991]** R. Jain. *The Art of Computer Systems Performance Analysis: Techniques for Experimental Design,
  Measurement, Simulation, and Modeling*. Wiley, 1991. ISBN 0-471-50336-3.
  — An experiment states its workload, metric and factors before it runs; the baseline of the case.
- **[Georges 2007]** A. Georges, D. Buytaert, L. Eeckhout. Statistically Rigorous Java Performance Evaluation.
  *OOPSLA* 2007, 57–76. https://doi.org/10.1145/1297027.1297033
  — Several runs and a confidence interval rather than one number or the best of N.
- **[Kalibera 2013]** T. Kalibera, R. Jones. Rigorous Benchmarking in Reasonable Time. *ISMM* 2013, 63–74.
  https://doi.org/10.1145/2464157.2464160
  — How many runs a measure needs, and where the variation comes from.
- **[Zeller 2002]** A. Zeller, R. Hildebrandt. Simplifying and Isolating Failure-Inducing Input. *IEEE Transactions on
  Software Engineering* 28(2), 183–200, 2002. https://doi.org/10.1109/32.988498
  — Delta debugging: shrink a failing case until every part of it is needed; the double sale shrunk to two buyers,
  one seat and one view.
- **[Mytkowicz 2009]** T. Mytkowicz, A. Diwan, M. Hauswirth, P. F. Sweeney. Producing Wrong Data Without Doing
  Anything Obviously Wrong! *ASPLOS* 2009, 265–276. https://doi.org/10.1145/1508244.1508275
  — Measurement bias from an innocent change of the set-up: the threats to validity of the case.

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
  — The throughput of group commit, $\lambda = N / W$.
- **[Gray 1994]** J. Gray, P. Sundaresan, S. Englert, K. Baclawski, P. J. Weinberger. Quickly Generating
  Billion-Record Synthetic Databases. *SIGMOD* 1994, 243–252. https://doi.org/10.1145/191839.191886
  — Zipf-distributed keys for the traces of the cache study.
- **[Cooper 2010]** B. F. Cooper, A. Silberstein, E. Tam, R. Ramakrishnan, R. Sears. Benchmarking Cloud Serving
  Systems with YCSB. *SoCC* 2010, 143–154. https://doi.org/10.1145/1807128.1807152
  — The Zipf exponent 0.99 of YCSB, used for the traces.
