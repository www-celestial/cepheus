# Références

Les travaux que Cepheus suit, auxquels il se mesure, ou qu'il prévoit de suivre, par sujet. Chaque entrée donne les
auteurs, le titre, le lieu de publication et l'année, un lien (un DOI quand il y en a un, sinon la page de l'éditeur
ou celle des auteurs), et ce que Cepheus en a pris. Chaque entrée a été vérifiée dans la notice de l'éditeur ou dans
DBLP (les auteurs dans l'ordre, le titre exact, le lieu, le volume et l'année) ; un travail qui n'a pas pu être vérifié
n'est pas listé. Les citations restent dans leur langue ; ce que Cepheus en a pris est en français. La documentation de
conception des autres bases de données (PostgreSQL, SQLite, Oracle, Datomic, RocksDB, Neo4j, FoundationDB, CockroachDB)
est citée dans la page [comparaison](comparison.md).

## Le stockage : les log-structured merge-trees

- **[O'Neil 1996]** P. O'Neil, E. Cheng, D. Gawlick, E. O'Neil. The Log-Structured Merge-Tree (LSM-Tree). *Acta
  Informatica* 33(4), 351–385, 1996. https://doi.org/10.1007/s002360050048
  — La structure du stockage : les changements dans un petit composant en mémoire, fusionnés en masse dans des
  composants triés sur le disque par un merge de runs triés (le "rolling merge" de C0 dans C1, puis de chaque composant
  dans le suivant) ; le coût d'un merge comme le size ratio plus un.
- **[Luo 2020]** C. Luo, M. J. Carey. LSM-based Storage Techniques: A Survey. *The VLDB Journal* 29(1), 393–418, 2020.
  https://doi.org/10.1007/s00778-019-00555-y
  — Le vocabulaire et les coûts du leveling et du tiering (write amplification $O(T \cdot L)$ et $O(L)$, runs visités
  par une lecture $L$ et $T \cdot L$), d'après lesquels est choisi le leveling de Cepheus avec un ratio de 4 (théorie,
  section 9).
- **[Dong 2017]** S. Dong, M. Callaghan, L. Galanis, D. Borthakur, T. Savor, M. Stumm. Optimizing Space Amplification
  in RocksDB. *CIDR* 2017. https://cidrdb.org/cidr2017/papers/p82-dong-cidr17.pdf
  — La space amplification et la write amplification dans RocksDB (avec des tailles de niveaux dynamiques et un size
  ratio de 10, la space amplification reste sous 1,111) ; avec l'option `bytes_per_sync` de RocksDB, la raison pour
  laquelle un merge force son fichier tous les 8 MiB pendant que les clients écrivent. Une copie complète de la base
  gardée à côté d'elle fait une space amplification de 2 : c'est pourquoi aucun run n'est gardé hors de la chaîne.
- **[Balmau 2019]** O. Balmau, F. Dinu, W. Zwaenepoel, K. Gupta, R. Chandhiramoorthi, D. Didona. SILK: Preventing
  Latency Spikes in Log-Structured Merge Key-Value Stores. *USENIX ATC* 2019, 753–766.
  https://www.usenix.org/conference/atc19/presentation/balmau
  — Des merges ordonnancés autour des écritures des clients ; une simple limite de débit a été essayée ici et n'a pas
  aidé (benchmarks).
- **[Brodal 2003]** G. S. Brodal, R. Fagerberg. Lower Bounds for External Memory Dictionaries. *SODA* 2003, 546–554.
  https://cs.au.dk/~gerth/papers/soda03.pdf
  — Le meilleur compromis possible entre le coût des écritures et celui des lectures sur le disque ; pourquoi une
  structure optimisée pour l'écriture (un LSM-tree ou un Bε-tree) est choisie pour un historique append-only.
- **[Bender 2015]** M. A. Bender, M. Farach-Colton, W. Jannen, R. Johnson, B. C. Kuszmaul, D. E. Porter, J. Yuan,
  Y. Zhan. An Introduction to Bε-trees and Write-Optimization. *;login:* 40(5), 22–28, 2015.
  https://www.usenix.org/publications/login/oct15/bender
  — L'autre structure optimisée pour l'écriture, mise en balance avec le LSM-tree dans la conception.
- **[Lu 2016]** L. Lu, T. S. Pillai, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau. WiscKey: Separating Keys from Values
  in SSD-Conscious Storage. *FAST* 2016, 133–148.
  https://www.usenix.org/conference/fast16/technical-sessions/presentation/lu
  — Garder les grandes valeurs hors des runs triés : les textes de Cepheus vivent dans un dictionnaire et les lignes
  contiennent leurs numéros.
- **[Dayan 2017]** N. Dayan, M. Athanassoulis, S. Idreos. Monkey: Optimal Navigable Key-Value Store. *SIGMOD* 2017,
  79–94. https://doi.org/10.1145/3035918.3064054
  — Des Bloom filters (de petites tables de bits qui disent « absent à coup sûr » ou « peut-être présent ») réglés par
  niveau font qu'une recherche ponctuelle d'une clé entière coûte environ la sonde d'un seul run ; pas construit : les
  lectures de Cepheus sont des intervalles courts et des comptes exacts, qui visitent chaque run pouvant contenir la clé
  (théorie, section 9).
- **[Dayan 2018]** N. Dayan, S. Idreos. Dostoevsky: Better Space-Time Trade-Offs for LSM-Tree Based Key-Value Stores
  via Adaptive Removal of Superfluous Merging. *SIGMOD* 2018, 505–520. https://doi.org/10.1145/3183713.3196927
  — Le leveling, le tiering et le lazy leveling (du tiering au-dessus, du leveling au dernier niveau) mis en balance
  selon le coût des écritures, des lectures ponctuelles, des lectures d'intervalles et de l'espace : la comparaison sur
  laquelle repose le choix du leveling par Cepheus.

## Le logging, la recovery et la crash consistency

- **[Mohan 1992]** C. Mohan, D. Haderle, B. Lindsay, H. Pirahesh, P. Schwarz. ARIES: A Transaction Recovery Method
  Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging. *ACM TODS* 17(1), 94–162, 1992.
  https://doi.org/10.1145/128765.128770
  — La règle write-ahead (le log est durable avant qu'un changement compte). Le journal de Cepheus est redo-only : il
  journalise des changements déjà résolus et n'en défait jamais un, donc la recovery est un replay dans l'ordre.
- **[DeWitt 1984]** D. J. DeWitt, R. H. Katz, F. Olken, L. D. Shapiro, M. R. Stonebraker, D. A. Wood. Implementation
  Techniques for Main Memory Database Systems. *SIGMOD* 1984, 1–8. https://doi.org/10.1145/602259.602261
  — Le group commit : les commits qui attendent pendant une écriture du log partagent la suivante.
- **[Helland 1987]** P. Helland, H. Sammer, J. Lyon, R. Carr, P. Garrett, A. Reuter. Group Commit Timers and High
  Volume Transaction Systems. *HPTS* 1987; Lecture Notes in Computer Science 359, Springer, 1989, 301–329.
  https://doi.org/10.1007/3-540-51085-0_52
  — Le group commit à fort volume ; Cepheus groupe sans minuterie : une frame contient ce qui est arrivé pendant le
  fsync précédent.
- **[Pillai 2014]** T. S. Pillai, V. Chidambaram, R. Alagappan, S. Al-Kiswany, A. C. Arpaci-Dusseau,
  R. H. Arpaci-Dusseau. All File Systems Are Not Created Equal: On the Complexity of Crafting Crash-Consistent
  Applications. *OSDI* 2014, 433–448. https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai
  — L'étude ALICE : les bugs de crash viennent de l'ordre des écritures, des fsyncs et des renames. Cepheus force un
  fichier avant son rename et un répertoire après le changement d'un nom, et son test exhaustif énumère chaque état de
  crash dans cet esprit.
- **[Rebello 2020]** A. Rebello, Y. Patel, R. Alagappan, A. C. Arpaci-Dusseau, R. H. Arpaci-Dusseau. Can Applications
  Recover from fsync Failures? *USENIX ATC* 2020, 753–767. https://www.usenix.org/conference/atc20/presentation/rebello
  — Après un fsync qui a échoué, ext4 et XFS marquent les pages clean et gardent leurs nouveaux octets en mémoire,
  Btrfs les défait ; retenter est faux, et la recovery doit reposer sur ce que contient le disque. Cepheus s'arrête et
  ne retente jamais (G10), coupe le journal jusqu'à sa dernière frame durable, et écrit de nouveau la frame la plus
  récente à la recovery pour que son fsync l'écrive vraiment, le conseil même de l'article (G13) ; son disque simulé
  fait ce que l'article a mesuré.
- **[Zheng 2013]** M. Zheng, J. Tucek, F. Qin, M. Lillibridge. Understanding the Robustness of SSDs under Power Fault.
  *FAST* 2013, 271–284. https://www.usenix.org/conference/fast13/technical-sessions/presentation/zheng
  — De vrais SSD perdent et déchirent des données à une coupure de courant : pourquoi le modèle de pannes inclut des
  secteurs déchirés et réordonnés, et pourquoi les disques de production ont besoin d'une power-loss protection (une
  protection contre la coupure de courant).
- **[Castagnoli 1993]** G. Castagnoli, S. Brauer, M. Herrmann. Optimization of Cyclic Redundancy-Check Codes with 24
  and 32 Parity Bits. *IEEE Transactions on Communications* 41(6), 883–892, 1993. https://doi.org/10.1109/26.231911
  — Le polynôme CRC-32C (0x1EDC6F41, réfléchi 0x82F63B78) de chaque frame et de chaque page.
- **[RFC 3720]** J. Satran, K. Meth, C. Sapuntzakis, M. Chadalapaka, E. Zeidner. Internet Small Computer Systems
  Interface (iSCSI). *RFC 3720*, IETF, April 2004. https://doi.org/10.17487/RFC3720
  — Le CRC-32C tel que le définit une norme (section 12.1 : le polynôme générateur 0x11EDC6F41, qui cite
  [Castagnoli 1993] ; les bits complémentés avant et après), et cinq exemples avec leurs CRC (annexe B.4), que vérifie
  `test/unit.ml`.
- **[Intel SDM]** Intel. Intel 64 and IA-32 Architectures Software Developer's Manual, volume 2A, "CRC32 — Accumulate
  CRC32 Value". https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html
  — L'instruction avec laquelle Cepheus calcule son CRC sur x86-64 : le polynôme 11EDC6F41H, 1, 2, 4 ou 8 octets par
  pas, présente quand CPUID.01H:ECX.SSE4_2 (le bit 20) est à 1, une faute invalid-opcode sinon.
- **[Arm ARM]** Arm. Arm Architecture Reference Manual for A-profile architecture (DDI 0487), the instructions CRC32CB
  to CRC32CX. https://developer.arm.com/documentation/ddi0487/latest; and Arm C Language Extensions (ACLE), "CRC32
  intrinsics". https://arm-software.github.io/acle/main/acle.html
  — Le côté arm64 : le même polynôme, facultatif dans Armv8.0 et obligatoire à partir d'Armv8.1 (FEAT_CRC32),
  accessible depuis le C par `__crc32cd` et `__crc32cb` ; Linux dit à un programme si le processeur les a
  (`HWCAP_CRC32`).
- **[x86-64 psABI]** System V Application Binary Interface, AMD64 Architecture Processor Supplement.
  https://gitlab.com/x86-psABIs/x86-64-ABI
  — Sa table "Micro-Architecture Levels" : x86-64-v2, c'est CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSE4_1, SSE4_2 et
  SSSE3.
- **[Koopman 2002]** P. Koopman. 32-Bit Cyclic Redundancy Codes for Internet Applications. *DSN* 2002, 459–468.
  https://doi.org/10.1109/DSN.2002.1028931
  — Ce que CRC-32C détecte à coup sûr (sa distance de Hamming selon la longueur) et avec quelle probabilité le reste
  passe.
- **[Alagappan 2018]** R. Alagappan, A. Ganesan, E. Lee, A. Albarghouthi, V. Chidambaram, A. C. Arpaci-Dusseau,
  R. H. Arpaci-Dusseau. Protocol-Aware Recovery for Consensus-Based Storage. *FAST* 2018, 15–32.
  https://www.usenix.org/conference/fast18/presentation/alagappan
  — Un seul secteur abîmé peut faire perdre des données confirmées dans des systèmes répliqués ; la règle prévue pour
  la réplication (une réplique abîmée ne vote pas, elle se répare), et pourquoi une seule machine refuse d'ouvrir
  plutôt que de couper.

## La gestion des buffers et le cache

- **[Crotty 2022]** A. Crotty, V. Leis, A. Pavlo. Are You Sure You Want to Use MMAP in Your Database Management
  System? *CIDR* 2022. https://vldb.org/cidrdb/2022/are-you-sure-you-want-to-use-mmap-in-your-database-management-system.html
  — Pourquoi la base est lue à travers le cache propre de Cepheus plutôt que mappée en mémoire : les erreurs arrivent
  comme des signaux, aucun contrôle de l'éviction, des blocages au-delà de la mémoire.
- **[Leis 2018]** V. Leis, M. Haubenschild, A. Kemper, T. Neumann. LeanStore: In-Memory Data Management beyond Main
  Memory. *ICDE* 2018, 185–196. https://doi.org/10.1109/ICDE.2018.00026
  — Un buffer pool qui a la vitesse d'une base en mémoire quand tout tient : les pages chaudes atteintes sans aucun
  lock.
- **[Neumann 2020]** T. Neumann, M. J. Freitag. Umbra: A Disk-Based System with In-Memory Performance. *CIDR* 2020.
  https://vldb.org/cidrdb/2020/umbra-a-disk-based-system-with-in-memory-performance.html
  — Des tailles de pages variables ; des pages de 64 KiB ont été mesurées ici et n'ont rien donné de plus que 16 KiB.
- **[Leis 2023]** V. Leis, A. Alhomssi, T. Ziegler, Y. Loeck, C. Dietrich. Virtual-Memory Assisted Buffer Management.
  *Proceedings of the ACM on Management of Data* 1(1), 1–25 (SIGMOD 2023). https://doi.org/10.1145/3588687
  — La base décide quoi lire et quoi évincer, même quand le mapping de la mémoire sert de table des pages.
- **[Harizopoulos 2008]** S. Harizopoulos, D. J. Abadi, S. Madden, M. Stonebraker. OLTP Through the Looking Glass, and
  What We Found There. *SIGMOD* 2008, 981–992. https://doi.org/10.1145/1376616.1376713
  — Dans un moteur classique, le locking, le latching, le logging et le buffer manager prennent la plus grande partie
  du temps : Cepheus a un seul writer (pas de locks) et des hits sans lock.
- **[Yang 2023]** J. Yang, Y. Zhang, Z. Qiu, Y. Yue, R. Vinayak. FIFO Queues are All You Need for Cache Eviction.
  *SOSP* 2023, 130–149. https://doi.org/10.1145/3600006.3613147
  — S3-FIFO, la politique d'éviction du cache : trois files FIFO, rien n'est déplacé sur un hit.
- **[Belady 1966]** L. A. Belady. A Study of Replacement Algorithms for a Virtual-Storage Computer. *IBM Systems
  Journal* 5(2), 78–101, 1966. https://doi.org/10.1147/sj.52.0078
  — La politique optimale hors ligne (évincer la page dont on aura besoin le plus tard), l'étalon de l'étude du cache.
- **[Johnson 1994]** T. Johnson, D. Shasha. 2Q: A Low Overhead High Performance Buffer Management Replacement
  Algorithm. *VLDB* 1994, 439–450. https://www.vldb.org/conf/1994/P439.PDF
  — Une des politiques simulées sur les traces enregistrées.
- **[Megiddo 2003]** N. Megiddo, D. S. Modha. ARC: A Self-Tuning, Low Overhead Replacement Cache. *FAST* 2003.
  https://www.usenix.org/conference/fast-03/arc-self-tuning-low-overhead-replacement-cache
  — Simulée sur les traces.
- **[Einziger 2017]** G. Einziger, R. Friedman, B. Manes. TinyLFU: A Highly Efficient Cache Admission Policy. *ACM
  Transactions on Storage* 13(4), article 35, 2017. https://doi.org/10.1145/3149371
  — W-TinyLFU, simulée sur les traces.
- **[Zhang 2024]** Y. Zhang, J. Yang, Y. Yue, Y. Vigfusson, K. V. Rashmi. SIEVE is Simpler than LRU: an Efficient
  Turn-Key Eviction Algorithm for Web Caches. *NSDI* 2024, 1229–1246.
  https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo
  — Simulée sur les traces.
- **[Corbató 1968]** F. J. Corbató. A Paging Experiment with the Multics System. MIT Project MAC Memorandum MAC-M-384,
  1968; in *In Honor of Philip M. Morse*, H. Feshbach and K. U. Ingard (eds.), MIT Press, 1969, 217–228.
  https://multicians.org/paging-experiment.pdf
  — CLOCK, le bit de référence et l'aiguille ; la file principale de S3-FIFO garde une page de la même façon.
- **[Linux cgroup v2]** The Linux Kernel documentation, Control Group v2, section "Memory Ownership".
  https://docs.kernel.org/admin-guide/cgroup-v2.html
  — Une page du page cache reste comptée au control group qui l'a amenée ; `POSIX_FADV_DONTNEED` la rend. Pourquoi les
  mesures plus grandes que la mémoire retirent les pages des fichiers avant chaque côté
  ([benchmarks](benchmarks.md#runs-et-journal-compressés-2026-11-09-à-10-millions-de-faits)).

## Les index et la compression

- **[Weiss 2008]** C. Weiss, P. Karras, A. Bernstein. Hexastore: Sextuple Indexing for Semantic Web Data Management.
  *PVLDB* 1(1), 1008–1019, 2008. https://doi.org/10.14778/1453856.1453965
  — Des triplets dans tous les ordres ; Cepheus garde deux ordres, parce que des numéros de chose denses font de « par
  chose » un tableau.
- **[Neumann 2008]** T. Neumann, G. Weikum. RDF-3X: a RISC-style Engine for RDF. *PVLDB* 1(1), 647–659, 2008.
  https://doi.org/10.14778/1453856.1453927
  — Des ordres de triplets triés, compressés ; le troisième ordre (propriété, chose) est mis en balance pour des données
  plus grandes que la mémoire.
- **[Goldstein 1998]** J. Goldstein, R. Ramakrishnan, U. Shaft. Compressing Relations and Indexes. *ICDE* 1998,
  370–379. https://doi.org/10.1109/ICDE.1998.655800
  — Le frame of reference : les valeurs d'une page rangées à partir de la plus petite, chacune sur les bits que demande
  son étendue, chacune décodable seule. Chaque bloc d'un run de format 7 et chaque colonne du format 2 du journal est
  codé ainsi.
- **[Zukowski 2006]** M. Zukowski, S. Héman, N. Nes, P. Boncz. Super-Scalar RAM-CPU Cache Compression. *ICDE* 2006, 59.
  https://doi.org/10.1109/ICDE.2006.150
  — PFOR et PFOR-DELTA : le frame of reference par blocs de 128 valeurs pour des colonnes, décodé en quelques cycles
  par valeur, les rares valeurs hors norme corrigées à part. Cepheus prend les blocs de 128 et le frame of reference,
  sans correction (une valeur se lit en $O(1)$, jamais en parcourant les exceptions), et des deltas là où ils codent
  plus court.
- **[Lemire 2015]** D. Lemire, L. Boytsov. Decoding Billions of Integers per Second through Vectorization. *Software:
  Practice and Experience* 45(1), 1–29, 2015. https://doi.org/10.1002/spe.2203
  — Le binary packing par blocs, ses décodeurs scalaires et vectorisés mesurés : les champs de Cepheus se lisent de la
  façon scalaire, un chargement non aligné de 8 octets, un décalage et un masque (OCaml n'a pas de SIMD), comme le fait
  leur binary packing non vectorisé.
- **[Kuschewski 2023]** M. Kuschewski, D. Sauerwein, A. Alhomssi, V. Leis. BtrBlocks: Efficient Columnar Compression
  for Data Lakes. *Proc. ACM Manag. Data* 1(2), article 118 (SIGMOD 2023). https://doi.org/10.1145/3589263
  — Le codage choisi par bloc selon ce qui le rend le plus court : les colonnes du journal prennent un frame of
  reference ou des deltas bloc par bloc, les row blocks leurs choses à partir de la plus petite ou par gaps.
- **[Ailamaki 2001]** A. Ailamaki, D. J. DeWitt, M. D. Hill, M. Skounakis. Weaving Relations for Cache Performance.
  *VLDB* 2001, 169–180. http://www.vldb.org/conf/2001/P169.pdf
  — PAX : à l'intérieur d'une page, les valeurs de chaque attribut ensemble. Mesuré pour les thing blocks (une colonne
  par propriété dans un bloc de 128 choses) : chercher une chose touchait une cache line par propriété. Les blocs
  gardent un record par chose pour les propriétés que chaque chose a au plus une fois (le row store auquel PAX se
  compare) et des colonnes seulement pour les autres ; l'ordre par propriété, ce sont les colonnes.
- **[Vigna 2013]** S. Vigna. Quasi-Succinct Indices. *WSDM* 2013, 83–92. https://doi.org/10.1145/2433396.2433409
  — Le codage d'Elias-Fano d'une liste triée de $n$ valeurs inférieures à $u$ en au plus
  $2 + \lceil \log_2(u/n) \rceil$ bits chacune : la borne qui sert à mesurer l'ordre par propriété contre l'information
  contenue dans les données (théorie, section 11).
- **[Vigna 2016]** S. Vigna. An Experimental Exploration of Marsaglia's xorshift Generators, Scrambled. *ACM
  Transactions on Mathematical Software* 42(4), article 30, 2016. https://arxiv.org/abs/1402.6246 (the extended
  version)
  — Son multiplicateur M32 = 2685821657736338717 (0x2545F4914F6CDD1D, table IV, celui de xorshift64*) est la constante
  du hash des textes des dictionnaires des runs.
- **[Neumann 2011]** T. Neumann, G. Moerkotte. Characteristic Sets: Accurate Cardinality Estimation for RDF Queries
  with Multiple Joins. *ICDE* 2011, 984–994. https://doi.org/10.1109/ICDE.2011.5767868
  — Des choses groupées selon l'ensemble des propriétés qu'elles ont : une façon, pas encore prise, de découper les
  thing blocks par sorte de chose pour qu'un bloc de factures ne contienne aucun champ absent.
- **[Binnig 2009]** C. Binnig, S. Hildenbrand, F. Färber. Dictionary-based Order-preserving String Compression for
  Main Memory Column Stores. *SIGMOD* 2009, 283–296. https://doi.org/10.1145/1559845.1559877
  — Un dictionnaire qui garde l'ordre permettrait des intervalles et des préfixes sur les textes ; les dictionnaires
  des runs trouvent un texte par une table de hachage et ne gardent aucun ordre (la liste triée d'ids du format 6 est
  partie avec le format 7).

- **[Jacobson 1989]** G. Jacobson. Space-efficient Static Trees and Graphs. *FOCS* 1989, 549–554.
  https://doi.org/10.1109/SFCS.1989.63533
  — Le rank directory : un vecteur de bits avec des comptes rangés tous les quelques mots répond à « combien de 1 avant
  la position i » en temps constant. Chaque partie d'un run en garde un par chose (des bits de présence pour 32 ids de
  chose et le compte avant eux, un quart d'octet par id de chose).
- **[Knuth 1998]** D. E. Knuth. *The Art of Computer Programming, Volume 3: Sorting and Searching*, 2nd edition.
  Addison-Wesley, 1998. ISBN 0-201-89685-0.
  — La section 6.4, le hachage avec linear probing (en cas de collision, on essaie le slot suivant) : les tables de
  textes des runs, remplies au plus à moitié (environ 1,5 sonde pour un texte qui s'y trouve, 2,5 pour un texte qui n'y
  est pas). La section 5.2.5, le tri par distribution : le counting sort et le radix sort stable par le chiffre le moins
  significatif d'abord, qui trient les faits d'un grand groupe (par chose, par propriété, puis par valeur à l'intérieur
  de chaque propriété, avec des chiffres de 11 bits).
- **[Leis 2014]** V. Leis, P. Boncz, A. Kemper, T. Neumann. Morsel-Driven Parallelism: A NUMA-Aware Query
  Evaluation Framework for the Many-Core Age. *SIGMOD* 2014, 743–754. https://doi.org/10.1145/2588555.2610507
  — Un travail découpé en petits morceaux ("morsels") que des threads de travail prennent à tour de rôle chez un
  répartiteur partagé, pour que la charge s'équilibre d'elle-même sans plan. Les chunks d'un grand groupe sont pris
  ainsi par les domains, comme les slices de la première variable d'une question (`Query.fold`).
- **[Bentley 1976]** J. L. Bentley, A. C.-C. Yao. An Almost Optimal Algorithm for Unbounded Searching. *Information
  Processing Letters* 5(3), 82–87, 1976. https://doi.org/10.1016/0020-0190(76)90071-5
  — La recherche exponentielle (galloping) : les sauts de la leapfrog intersection (`Query.gallop`) : des pas de 1, 2,
  4, ... depuis la dernière place, puis une recherche dichotomique, $O(\log d)$ pour une place $d$ plus loin. Jusqu'au
  format 7, un merge plaçait aussi de cette façon les textes des autres runs dans la liste triée du plus grand run.

- **[Abadi 2007]** D. J. Abadi, A. Marcus, S. R. Madden, K. Hollenbach. Scalable Semantic Web Data Management Using
  Vertical Partitioning. *VLDB* 2007, 411–422. https://www.vldb.org/conf/2007/papers/research/p411-abadi.pdf
  — Le vertical partitioning des triplets : une table à deux colonnes (sujet, objet) par propriété, triée par sujet. Le
  column order du run format 8 : les lignes de chaque propriété à part, dans l'ordre des choses, donc une recherche lit
  les octets d'une seule propriété et les triangles ne lisent que `follows` (2,2 MB d'un run de 70 MB).

## Les joins

- **[Atserias 2008]** A. Atserias, M. Grohe, D. Marx. Size Bounds and Query Plans for Relational Joins. *FOCS* 2008,
  739–748. https://doi.org/10.1109/FOCS.2008.43 ; *SIAM Journal on Computing* 42(4), 1737–1767, 2013.
  https://doi.org/10.1137/110859440
  — L'AGM bound : la plus grande réponse d'une conjunctive query d'après les tailles de ses entrées ($N^{1{,}5}$ pour un
  triangle).
- **[Ngo 2012]** H. Q. Ngo, E. Porat, C. Ré, A. Rudra. Worst-case Optimal Join Algorithms. *PODS* 2012, 37–48.
  https://doi.org/10.1145/2213556.2213565 ; *Journal of the ACM* 65(3), 2018. https://doi.org/10.1145/3180143
  — Le premier algorithme de join qui atteint l'AGM bound, et la preuve que les plans de binary joins ne le peuvent pas.
- **[Ngo 2013]** H. Q. Ngo, C. Ré, A. Rudra. Skew Strikes Back: New Developments in the Theory of Join Algorithms. *ACM
  SIGMOD Record* 42(4), 5–16, 2013. https://doi.org/10.1145/2590989.2590991
  — Generic Join, l'algorithme de chaque question, et l'argument de sa borne.
- **[Veldhuizen 2014]** T. L. Veldhuizen. Leapfrog Triejoin: A Simple, Worst-Case Optimal Join Algorithm. *ICDT* 2014,
  96–106. https://doi.org/10.5441/002/icdt.2014.13
  — La leapfrog intersection des slices triées d'un niveau (les valeurs d'une chose, les choses d'une valeur) : les
  itérateurs dans l'ordre des clés, chacun cherchant à son tour la plus grande clé ; les colonnes du run format 8
  donnent les slices dans l'ordre (`Query.leapfrog`). La borne, avec des sauts, à un facteur logarithmique près de
  l'AGM bound ; le moteur ne lit une slice que quand elle fait au plus 8 fois la plus petite, donc la borne testée reste
  à une constante près de celle de Generic Join.
- **[Aberger 2016]** C. R. Aberger, S. Tu, K. Olukotun, C. Ré. EmptyHeaded: A Relational Engine for Graph Processing.
  *SIGMOD* 2016, 431–446. https://doi.org/10.1145/2882903.2915213
  — Un moteur worst-case optimal pour les requêtes sur des graphes.
- **[Freitag 2020]** M. J. Freitag, M. Bandle, T. Schmidt, A. Kemper, T. Neumann. Adopting Worst-Case Optimal Joins in
  Relational Database Systems. *PVLDB* 13(11), 1891–1904, 2020. https://doi.org/10.14778/3407790.3407797
  — En pratique, c'est l'ordre des variables qui compte le plus.
- **[Mhedhbi 2019]** A. Mhedhbi, S. Salihoglu. Optimizing Subgraph Queries by Combining Binary and Worst-Case Optimal
  Joins. *PVLDB* 12(11), 1692–1704, 2019. https://doi.org/10.14778/3342263.3342643
  — Le choix de l'ordre des variables d'après les coûts.
- **[Wang 2023]** Y. R. Wang, M. Willsey, D. Suciu. Free Join: Unifying Worst-Case Optimal and Traditional Joins.
  *Proceedings of the ACM on Management of Data* 1(2), 1–23 (SIGMOD 2023). https://doi.org/10.1145/3589295
  — Le mélange de binary joins et de joins worst-case optimal ; Cepheus garde une seule façon, Generic Join.

## Les transactions et l'isolation

- **[Papadimitriou 1979]** C. H. Papadimitriou. The Serializability of Concurrent Database Updates. *Journal of the
  ACM* 26(4), 631–653, 1979. https://doi.org/10.1145/322154.322158
  — La définition de la serializability que prouve G4.
- **[Kung 1981]** H. T. Kung, J. T. Robinson. On Optimistic Methods for Concurrency Control. *ACM TODS* 6(2), 213–226,
  1981. https://doi.org/10.1145/319566.319567
  — L'optimistic concurrency control avec validation en arrière : `Expect`, vérifié par le writer à la fin.
- **[Herlihy 1990]** M. P. Herlihy, J. M. Wing. Linearizability: A Correctness Condition for Concurrent Objects. *ACM
  TOPLAS* 12(3), 463–492, 1990. https://doi.org/10.1145/78969.78972
  — L'ordre du temps réel qui rend l'historique des groupes strictly serializable.
- **[Berenson 1995]** H. Berenson, P. Bernstein, J. Gray, J. Melton, E. O'Neil, P. O'Neil. A Critique of ANSI SQL
  Isolation Levels. *SIGMOD* 1995, 1–10. https://doi.org/10.1145/223784.223785
  — La snapshot isolation définie, et son write skew ; le vocabulaire de la section sur l'isolation.
- **[Adya 1999]** A. Adya. Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed
  Transactions. PhD thesis, MIT, 1999. https://hdl.handle.net/1721.1/149899
  — Les anomalies comme des cycles dans le dependency graph (G0, G1, G2) : aucun ne peut se former entre des groupes.
- **[Fekete 2005]** A. Fekete, D. Liarokapis, E. O'Neil, P. O'Neil, D. Shasha. Making Snapshot Isolation
  Serializable. *ACM TODS* 30(2), 492–528, 2005. https://doi.org/10.1145/1071610.1071615
  — Pourquoi la snapshot isolation n'est pas serializable, et "materialize the conflict" : la façon de protéger un
  ensemble avec `Expect`.
- **[Cahill 2008]** M. J. Cahill, U. Röhm, A. D. Fekete. Serializable Isolation for Snapshot Databases. *SIGMOD* 2008,
  729–738. https://doi.org/10.1145/1376616.1376690
  — La serializable snapshot isolation, telle que l'implémente le SERIALIZABLE de PostgreSQL.
- **[Ports 2012]** D. R. K. Ports, K. Grittner. Serializable Snapshot Isolation in PostgreSQL. *PVLDB* 5(12),
  1850–1861, 2012. https://doi.org/10.14778/2367502.2367523
  — L'implémentation de PostgreSQL, à laquelle la page de comparaison se compare.
- **[Thomson 2012]** A. Thomson, T. Diamond, S.-C. Weng, K. Ren, P. Shao, D. J. Abadi. Calvin: Fast Distributed
  Transactions for Partitioned Database Systems. *SIGMOD* 2012, 1–12. https://doi.org/10.1145/2213836.2213838
  — Des transactions dans un ordre fixé d'avance, sans locks : le writer unique, et le plan pour plusieurs machines.

## Les structures persistantes et les forks

- **[Driscoll 1989]** J. R. Driscoll, N. Sarnak, D. D. Sleator, R. E. Tarjan. Making Data Structures Persistent.
  *Journal of Computer and System Sciences* 38(1), 86–124, 1989. https://doi.org/10.1016/0022-0000(89)90034-2
  — Chaque version gardée en copiant un chemin : ce qui rend les vues et les forks gratuits.
- **[Okasaki 1998]** C. Okasaki. Purely Functional Data Structures. Cambridge University Press, 1998.
  https://doi.org/10.1017/CBO9780511530104
  — Les arbres équilibrés persistants, les maps du delta.
- **[Kemper 2011]** A. Kemper, T. Neumann. HyPer: A Hybrid OLTP&OLAP Main Memory Database System Based on Virtual
  Memory Snapshots. *ICDE* 2011, 195–206. https://doi.org/10.1109/ICDE.2011.5767867
  — Un snapshot cohérent par un `fork()` du processus : le même besoin, satisfait plutôt par la persistance.
- **[Rodeh 2008]** O. Rodeh. B-trees, Shadowing, and Clones. *ACM Transactions on Storage* 3(4), 1–27, 2008.
  https://doi.org/10.1145/1326542.1326544
  — Les B-trees copy-on-write (btrfs, le système de fichiers de la machine de test).

## Les règles : Datalog, la matérialisation et sa maintenance

- **[Abiteboul 1995]** S. Abiteboul, R. Hull, V. Vianu. *Foundations of Databases*. Addison-Wesley, 1995. Free copy:
  http://webdam.inria.fr/Alice/
  — Datalog, son least model et son évaluation (partie D, chapitres 12-13, la semi-naive evaluation parmi eux) : la
  sémantique des règles de Cepheus (G17).
- **[Bancilhon 1986]** F. Bancilhon, R. Ramakrishnan. An Amateur's Introduction to Recursive Query Processing
  Strategies. *SIGMOD* 1986, 16–52. https://doi.org/10.1145/16894.16859
  — La semi-naive evaluation (§3.2.2 : la différence au lieu du tout à chaque pas) : l'évaluation des conséquences de
  chaque groupe.
- **[Ramakrishnan 1990]** R. Ramakrishnan, D. Srivastava, S. Sudarshan. Rule Ordering in Bottom-Up Fixpoint
  Evaluation of Logic Programs. *VLDB* 1990, 359–371.
  — La propriété semi-naive, chaque inférence faite exactement une fois : la borne du travail du raisonnement d'un
  groupe.
- **[Feeley 1987]** M. Feeley, G. Lapalme. Using Closures for Code Generation. *Computer Languages* 12(1), 47–66, 1987.
  https://doi.org/10.1016/0096-0551(87)90012-9
  — Du code compilé en closures sans générer de code : chaque règle compilée une fois en ses plans.
- **[Gupta 1993]** A. Gupta, I. S. Mumick, V. S. Subrahmanian. Maintaining Views Incrementally. *SIGMOD* 1993,
  157–166. https://doi.org/10.1145/170035.170066
  — Le counting (pour les vues non récursives) et DRed : les deux algorithmes auxquels B/F a été préféré ; le counting
  montré faux ici sur les propriétés inverses.
- **[Motik 2015]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Incremental Update of Datalog Materialisation: the
  Backward/Forward Algorithm. *AAAI* 2015, 1560–1568. https://doi.org/10.1609/aaai.v29i1.9409
  — B/F, l'algorithme de retrait, et ses gains mesurés sur DRed.
- **[Motik 2019]** B. Motik, Y. Nenov, R. Piro, I. Horrocks. Maintenance of Datalog Materialisations Revisited.
  *Artificial Intelligence* 269, 76–136, 2019. https://doi.org/10.1016/j.artint.2018.12.004
  — Le counting rendu correct sur les règles récursives, et FBF : les raffinements ultérieurs, à mesurer avant d'être
  pris.
- **[Motik 2014]** B. Motik, Y. Nenov, R. Piro, I. Horrocks, D. Olteanu. Parallel Materialisation of Datalog Programs
  in Centralised, Main-Memory RDF Systems. *AAAI* 2014, 129–137. https://doi.org/10.1609/aaai.v28i1.8730
  — RDFox : la table de triplets avec des index de hachage et des chaînes que suit le working set ; ses débits
  publiés, l'étalon des benchmarks.
- **[Urbani 2016]** J. Urbani, C. Jacobs, M. Krötzsch. Column-Oriented Datalog Materialization for Large Knowledge
  Graphs. *AAAI* 2016, 258–264. https://doi.org/10.1609/aaai.v30i1.9993
  — VLog : la matérialisation sur des colonnes triées ; son débit publié sur un thread, à côté du nôtre.
- **[Scholz 2016]** B. Scholz, H. Jordan, P. Subotić, T. Westmann. On Fast Large-Scale Program Analysis in Datalog.
  *CC* 2016, 196–206. https://doi.org/10.1145/2892208.2892226
  — Soufflé, du Datalog compilé en C++ : ses temps publiés, à côté des nôtres.
- **[Zhao 2020]** D. Zhao, P. Subotić, B. Scholz. Debugging Large-scale Datalog: A Scalable Provenance Evaluation
  Strategy. *ACM TOPLAS* 42(2), 2020. https://doi.org/10.1145/3379446
  — La provenance stockée par fait (règle et hauteur de preuve) pour un temps d'exécution publié de 1,31× : l'autre voie
  que le `why` de Cepheus, calculé quand on le demande.
- **[Hu 2019]** P. Hu, B. Motik, I. Horrocks. Modular Materialisation of Datalog Programs. *AAAI* 2019, 2859–2866.
  https://doi.org/10.1609/aaai.v33i01.33012859
  — Des modules pour les propriétés transitives et symétriques : le module de clôture de la prochaine étape.
- **[Henzinger 2015]** M. Henzinger, S. Krinninger, D. Nanongkai, T. Saranurak. Unifying and Strengthening Hardness
  for Dynamic Problems via the Online Matrix-Vector Multiplication Conjecture. *STOC* 2015, 21–30.
  https://doi.org/10.1145/2746539.2746609
  — Des bornes inférieures conditionnelles pour la clôture transitive décrémentale : pourquoi aucun algorithme de
  retrait n'est bon marché dans le pire cas.
- **[Guo 2005]** Y. Guo, Z. Pan, J. Heflin. LUBM: A Benchmark for OWL Knowledge Base Systems. *Journal of Web
  Semantics* 3(2–3), 158–182, 2005. https://doi.org/10.1016/j.websem.2005.06.005
  — La forme des données du benchmark (universités, départements, personnes, cours) et son ontologie.
- **[Budiu 2023]** M. Budiu, T. Chajed, F. McSherry, L. Ryzhyk, V. Tannen. DBSP: Automatic Incremental View
  Maintenance for Rich Query Languages. *PVLDB* 16(7), 1601–1614, 2023. https://doi.org/10.14778/3587136.3587137
  — Les règles delta des joins, prévues pour les questions vivantes (des abonnements) et les agrégats des règles.

## La réplication et plusieurs machines (prévu)

- **[Ongaro 2014]** D. Ongaro, J. Ousterhout. In Search of an Understandable Consensus Algorithm. *USENIX ATC* 2014,
  305–319. https://www.usenix.org/conference/atc14/technical-sessions/presentation/ongaro
  — Raft, choisi pour la réplication, avec sa spécification TLA+ publique.
- **[Verbitski 2017]** A. Verbitski, A. Gupta, D. Saha, M. Brahmadesam, K. Gupta, R. Mittal, S. Krishnamurthy,
  S. Maurice, T. Kharatishvili, X. Bao. Amazon Aurora: Design Considerations for High Throughput Cloud-Native
  Relational Databases. *SIGMOD* 2017, 1041–1052. https://doi.org/10.1145/3035918.3056101
  — "The log is the database" (le log est la base de données) : le journal est la seule chose à répliquer.
- **[Antonopoulos 2019]** P. Antonopoulos, A. Budovski, C. Diaconu, A. Hernandez Saenz, J. Hu, H. Kodavalla,
  D. Kossmann, S. Lingam, U. F. Minhas, N. Prakash, V. Purohit, H. Qu, C. S. Ravella, K. Reisteter, S. Shrotri,
  D. Tang, V. Wakade. Socrates: The New SQL Server in the Cloud. *SIGMOD* 2019, 1743–1756.
  https://doi.org/10.1145/3299869.3314047
  — Le log, les pages et le calcul séparés : le plan pour le stockage sur des object stores.
- **[Ammar 2018]** K. Ammar, F. McSherry, S. Salihoglu, M. Joglekar. Distributed Evaluation of Subgraph Queries Using
  Worst-case Optimal Low-Memory Dataflows. *PVLDB* 11(6), 691–704, 2018. https://doi.org/10.14778/3184470.3184473
  — BiGJoin : Generic Join sur beaucoup de machines, prévu.

## Le serveur

- **[Ongaro 2014b]** D. Ongaro. Consensus: Bridging Theory and Practice. PhD dissertation, Stanford University, 2014.
  https://web.stanford.edu/~ouster/cgi-bin/papers/OngaroPhD.pdf
  — La section 6.3, les sessions des clients : "Each server's state machine maintains a session for each client ...
  latest serial number processed ... along with the associated response" ; la table des sessions du serveur (G14), avec
  un floor pour que beaucoup d'écritures d'une session soient en cours à la fois.
- **[Terry 1994]** D. B. Terry, A. J. Demers, K. Petersen, M. J. Spreitzer, M. M. Theimer, B. B. Welch. Session
  Guarantees for Weakly Consistent Replicated Data. *PDIS* 1994, 140–149. https://doi.org/10.1109/PDIS.1994.331722
  — "Read your writes" et "monotonic writes" : ce que gardent les requêtes d'une même connexion.
- **[RFC 4648]** S. Josefsson. The Base16, Base32, and Base64 Data Encodings. RFC 4648, 2006.
  https://www.rfc-editor.org/rfc/rfc4648
  — La section 5, base64url : le texte d'un token.
- **[RFC 7693]** M-J. Saarinen, J-P. Aumasson. The BLAKE2 Cryptographic Hash and Message Authentication Code (MAC).
  RFC 7693, 2015. https://www.rfc-editor.org/rfc/rfc7693
  — BLAKE2b-256, le hash sous lequel un token est gardé (le `Digest.BLAKE256` d'OCaml).
- **[PostgreSQL 11.2]** PostgreSQL Global Development Group. Release notes of PostgreSQL 11.2 (and 10.7, 9.6.12,
  9.5.16, 9.4.21), 14 February 2019. https://www.postgresql.org/docs/release/11.2/
  — Un fsync qui a échoué arrête le serveur (PANIC) au lieu d'être retenté (`data_sync_retry` à off) : le serveur
  s'arrête de la même façon sur un disque qui a échoué.
- **[RFC 8446]** E. Rescorla. The Transport Layer Security (TLS) Protocol Version 1.3. RFC 8446, 2018.
  https://www.rfc-editor.org/rfc/rfc8446
  — La seule version de TLS qu'acceptent le serveur et ses clients.
- **[Kaloper-Meršinjak 2015]** D. Kaloper-Meršinjak, H. Mehnert, A. Madhavapeddy, P. Sewell. Not-Quite-So-Broken TLS:
  Lessons in Re-Engineering a Security Protocol Specification and Implementation. *USENIX Security* 2015.
  https://www.usenix.org/conference/usenixsecurity15/technical-sessions/presentation/kaloper-mersinjak
  — ocaml-tls, le TLS en OCaml mis en balance avec OpenSSL (ses algorithmes de chiffrement sont en C eux aussi ; pas un
  projet d'OSS-Fuzz) : OpenSSL a été gardé.
- **[sd_notify]** systemd. sd_notify(3), le protocole de readiness (le signal « prêt ») : un seul datagramme
  (`READY=1`) sur `$NOTIFY_SOCKET`.
  https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
- **[Lamport 1986]** L. Lamport. On Interprocess Communication. Part I: Basic Formalism; Part II: Algorithms.
  *Distributed Computing* 1(2), 77–85 and 86–101, 1986. https://doi.org/10.1007/BF01786227,
  https://doi.org/10.1007/BF01786228
  — Les registres safe, regular et atomic : un registre regular laisse deux lectures, l'une après l'autre, voir une
  nouvelle valeur puis l'ancienne ; un registre atomic, non. Les lectures locales sont atomiques (G15) ; le premier
  lease de la conception donnait un registre regular.
- **[Gray 1989]** C. G. Gray, D. R. Cheriton. Leases: An Efficient Fault-Tolerant Mechanism for Distributed File Cache
  Consistency. *SOSP* 1989, 202–210. https://doi.org/10.1145/74850.74870
  — Le lease, un droit qui prend fin de lui-même après un temps : ce que la conception proposait d'abord pour les
  lectures locales, laissé au profit du numéro de visibilité sur une seule machine ; il revient entre machines.
- **[Moraru 2014]** I. Moraru, D. G. Andersen, M. Kaminsky. Paxos Quorum Leases: Fast Reads Without Sacrificing
  Writes. *SoCC* 2014. https://doi.org/10.1145/2670979.2671001
  — Le détenteur d'un lease ne lit en local qu'après avoir évalué "whether an update to any of the leased objects is
  ongoing (i.e., in the process of being committed), and if not" : les lectures par des leases fondés sur des messages
  ont besoin de cette attente pour être linearizable ; la mémoire partagée d'une seule machine la supprime. La voie
  prévue pour les lecteurs sur d'autres machines (étape 7).
- **[unix(7)]** The Linux man-pages project. unix(7): `SCM_RIGHTS`, "Send or receive a set of open file descriptors
  from another process". https://man7.org/linux/man-pages/man7/unix.7.html
  — Comment le serveur passe à un lecteur local ses fichiers de runs et sa page de visibilité
  (`server/fdpass_stubs.c`).
- **[mmap(2)]** The Linux man-pages project. mmap(2): `MAP_SHARED`, "Updates to the mapping are visible to other
  processes mapping the same region". https://man7.org/linux/man-pages/man2/mmap.2.html
  — La page de visibilité, mappée par le serveur et, en lecture seule (`PROT_READ`), par chaque lecteur local.
- **[socket(7)]** The Linux man-pages project. socket(7): `SO_RCVTIMEO` and `SO_SNDTIMEO`, the timeouts of a socket's
  reads and writes. https://man7.org/linux/man-pages/man7/socket.7.html
  — Comment un thread de connexion bloqué se réveille pour appliquer la limite d'inactivité.

## Les tests et la vérification

- **[Zhou 2021]** J. Zhou, M. Xu, A. Shraer, B. Namasivayam, A. Miller, E. Tschannen, S. Atherton, A. J. Beamon,
  R. Sears, J. Leach, D. Rosenthal, X. Dong, W. Wilson, B. Collins, D. Scherer, A. Grieser, Y. Liu, A. Moore,
  B. Muppana, X. Su, V. Yadav. FoundationDB: A Distributed Unbundled Transactional Key Value Store. *SIGMOD* 2021,
  2653–2666. https://doi.org/10.1145/3448016.3457559
  — Le deterministic simulation testing : tout le système sur un temps et des disques simulés, un échec rejoué à partir
  de sa seed.
- **[Bornholt 2021]** J. Bornholt, R. Joshi, V. Astrauskas, B. Cully, B. Kragl, S. Markle, K. Sauri, D. Schleit,
  G. Slatton, S. Tasiran, J. Van Geffen, A. Warfield. Using Lightweight Formal Methods to Validate a Key-Value Storage
  Node in Amazon S3. *SOSP* 2021, 836–850. https://doi.org/10.1145/3477132.3483540
  — Le vrai système comparé à un modèle de référence simple sur des opérations et des crashs aléatoires : les tests de
  propriétés.
- **[Claessen 2000]** K. Claessen, J. Hughes. QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs.
  *ICFP* 2000, 268–279. https://doi.org/10.1145/351240.351266
  — Le property-based testing (des tests qui vérifient une propriété sur des entrées générées au hasard).
- **[Steele 2014]** G. L. Steele Jr., D. Lea, C. H. Flood. Fast Splittable Pseudorandom Number Generators. *OOPSLA*
  2014, 453–472. https://doi.org/10.1145/2660193.2660195
  — SplitMix64, le générateur à seed de chaque test aléatoire (`Rng`).
- **[Lamport 2002]** L. Lamport. Specifying Systems: The TLA+ Language and Tools for Hardware and Software Engineers.
  Addison-Wesley, 2002. https://lamport.azurewebsites.net/tla/book.html
  — TLA+, le langage de `spec/Journal.tla` et de `spec/Merge.tla`.
- **[Yu 1999]** Y. Yu, P. Manolios, L. Lamport. Model Checking TLA+ Specifications. *CHARME* 1999, LNCS 1703, 54–66.
  https://doi.org/10.1007/3-540-48153-2_6
  — TLC, le model checker que lance `tools/tlc.sh`.
- **[Newcombe 2015]** C. Newcombe, T. Rath, F. Zhang, B. Munteanu, M. Brooker, M. Deardeuff. How Amazon Web Services
  Uses Formal Methods. *Communications of the ACM* 58(4), 66–73, 2015. https://doi.org/10.1145/2699417
  — Le model checking trouve des bugs de protocole que les tests manquent ; TLC en a trouvé un ici dans la règle de
  recovery du journal.
- **[Kingsbury 2020]** K. Kingsbury, P. Alvaro. Elle: Inferring Isolation Anomalies from Experimental Observations.
  *PVLDB* 14(3), 268–280, 2020. https://doi.org/10.14778/3430915.3430918
  — Le vérificateur d'isolation de Jepsen ; le test bank suit celui de Jepsen, Elle viendra avec la réplication.

- **[Serebryany 2012]** K. Serebryany, D. Bruening, A. Potapenko, D. Vyukov. AddressSanitizer: A Fast Address Sanity
  Checker. *USENIX ATC* 2012, 309–318. https://www.usenix.org/conference/atc12/technical-sessions/presentation/serebryany
  — Le vérificateur de mémoire sous lequel le fichier C du CRC est fuzzé : une lecture d'un seul octet hors de son bloc
  arrête l'exécution.
- **[libFuzzer]** The LLVM Project. libFuzzer – a library for coverage-guided fuzz testing.
  https://llvm.org/docs/LibFuzzer.html
  — Le fuzzer de `test/fuzz_crc32c.c` et de `test/fuzz_tls.c` : des entrées modifiées vers de nouveaux chemins du code,
  chacune vérifiée contre le CRC calculé bit par bit, ou contre ce qu'a écrit l'autre côté d'une conversation TLS.

## La méthode : résoudre et mesurer

- **[Pólya 1945]** G. Pólya. *How to Solve It: A New Aspect of Mathematical Method*. Princeton University Press, 1945.
  https://press.princeton.edu/books/paperback/9780691164076/how-to-solve-it
  — "Understanding the problem" (comprendre le problème) d'abord : l'inconnue, les données, la condition ; le premier
  pas du [cas des places](case-seats.md).
- **[Heilmeier]** G. H. Heilmeier. The Heilmeier Catechism, the questions DARPA asks of every proposed research
  program. https://www.darpa.mil/about/heilmeier-catechism
  — Qu'essayez-vous de faire, comment est-ce fait aujourd'hui, qu'est-ce qui est nouveau, comment saurez-vous que vous
  avez réussi : le cadre de l'énoncé du problème.
- **[Jain 1991]** R. Jain. *The Art of Computer Systems Performance Analysis: Techniques for Experimental Design,
  Measurement, Simulation, and Modeling*. Wiley, 1991. ISBN 0-471-50336-3.
  — Une expérience énonce sa charge, sa métrique et ses facteurs avant de tourner ; la baseline du cas.
- **[Georges 2007]** A. Georges, D. Buytaert, L. Eeckhout. Statistically Rigorous Java Performance Evaluation.
  *OOPSLA* 2007, 57–76. https://doi.org/10.1145/1297027.1297033
  — Plusieurs exécutions et un intervalle de confiance plutôt qu'un seul nombre ou le meilleur de N.
- **[Kalibera 2013]** T. Kalibera, R. Jones. Rigorous Benchmarking in Reasonable Time. *ISMM* 2013, 63–74.
  https://doi.org/10.1145/2464157.2464160
  — Combien d'exécutions une mesure demande, et d'où vient la variation.
- **[Zeller 2002]** A. Zeller, R. Hildebrandt. Simplifying and Isolating Failure-Inducing Input. *IEEE Transactions on
  Software Engineering* 28(2), 183–200, 2002. https://doi.org/10.1109/32.988498
  — Le delta debugging : réduire un cas qui échoue jusqu'à ce que chacune de ses parties soit nécessaire ; la double
  vente réduite à deux acheteurs, une place et une vue.
- **[Mytkowicz 2009]** T. Mytkowicz, A. Diwan, M. Hauswirth, P. F. Sweeney. Producing Wrong Data Without Doing
  Anything Obviously Wrong! *ASPLOS* 2009, 265–276. https://doi.org/10.1145/1508244.1508275
  — Le biais de mesure dû à un changement innocent du montage : les menaces sur la validité du cas.

## Le benchmarking et les statistiques

- **[Raasveldt 2018]** M. Raasveldt, P. Holanda, T. Gubner, H. Mühleisen. Fair Benchmarking Considered Difficult:
  Common Pitfalls in Database Performance Testing. *DBTest* 2018, 1–6. https://doi.org/10.1145/3209950.3209955
  — Les règles d'équité de la comparaison : les mêmes données, les mêmes réponses, chaque côté réglé comme le ferait un
  expert.
- **[Hoefler 2015]** T. Hoefler, R. Belli. Scientific Benchmarking of Parallel Computing Systems: Twelve Ways to Tell
  the Masses when Reporting Performance Results. *SC* 2015, article 73. https://doi.org/10.1145/2807591.2807644
  — Des médianes avec des intervalles de confiance sans hypothèse sur la distribution, le nombre d'exécutions énoncé.
- **[Le Boudec 2010]** J.-Y. Le Boudec. Performance Evaluation of Computer and Communication Systems. EPFL Press, 2010.
  https://leboudec.github.io/perfeval/
  — Le théorème 2.1 : l'intervalle de confiance d'une médiane à partir de deux statistiques d'ordre, utilisé par
  `bench/stats.ml`.
- **[Tene 2015]** G. Tene. How NOT to Measure Latency. Talk, Strange Loop 2015, St. Louis.
  https://www.youtube.com/watch?v=lJ8ydIuPFeU ; HdrHistogram, http://hdrhistogram.org/ ; wrk2,
  https://github.com/giltene/wrk2
  — La coordinated omission et les charges en open loop ; des histogrammes log-linéaires de chaque latence
  (`Histogram`).
- **[Little 1961]** J. D. C. Little. A Proof for the Queuing Formula: L = λW. *Operations Research* 9(3), 383–387,
  1961. https://doi.org/10.1287/opre.9.3.383
  — Le throughput (le débit) du group commit, $\lambda = N / W$.
- **[Gray 1994]** J. Gray, P. Sundaresan, S. Englert, K. Baclawski, P. J. Weinberger. Quickly Generating
  Billion-Record Synthetic Databases. *SIGMOD* 1994, 243–252. https://doi.org/10.1145/191839.191886
  — Des clés distribuées selon une loi de Zipf pour les traces de l'étude du cache.
- **[Cooper 2010]** B. F. Cooper, A. Silberstein, E. Tam, R. Ramakrishnan, R. Sears. Benchmarking Cloud Serving
  Systems with YCSB. *SoCC* 2010, 143–154. https://doi.org/10.1145/1807128.1807152
  — L'exposant de Zipf 0,99 de YCSB, utilisé pour les traces.
