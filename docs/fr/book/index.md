# Documentation de Cepheus

Lisez les pages dans cet ordre pour apprendre Cepheus ; allez aux pages de référence quand il vous faut une réponse
exacte.

**Commencer**
- [Démarrage rapide](quickstart.md) : construire Cepheus, lancer un serveur, et faire tourner un premier programme
  Cesia qui écrit et pose une question, en une dizaine de minutes.
- [En production](production.md) : un service systemd, une sauvegarde chaque nuit et un exercice de restauration, ce
  qu'il faut surveiller dans le status et le log (les temps des questions et des écritures, les lentes, Prometheus), les mises à jour, et que faire après une panne ou une coupure de
  courant.
- [Une vraie application](app.md) : des factures et des clients en Cesia, pas à pas, de `cesia new` jusqu'à la
  production : des listes par pages, une recherche pendant la frappe, un tableau de bord en direct, des utilisateurs
  dont un comptable avec un token qui ne lit que les factures, une règle et une contrainte, l'export CSV, des tests
  dans Firefox, et la vitesse de chaque page.
- [Tutoriels](tutorials.md) : des problèmes d'entreprise résolus pas à pas, PostgreSQL à côté : des numéros de
  facture sans trou, une file de jobs où chaque job est pris une seule fois, des données de test qui ne laissent rien,
  des pages qui ne sautent jamais une ligne, les clients sans facture cette année, `In` et `Or`, un stock qui ne
  descend jamais sous zéro, les factures payées en retard et des ranges de floats, les clients avec leur téléphone
  s'ils en ont un, un client qui a des factures gardé, un rapport mensuel dans le fuseau horaire de l'entreprise, la
  médiane des délais de paiement et les produits de chaque facture.

**Apprendre**
1. [Concepts](concepts.md) : les faits et le modèle entity–attribute–value, le schéma, les groupes (les transactions),
   les vues, l'isolation exactement, les questions, les forks, les bases de données.
2. [Comment ça marche](architecture.md) : le journal (un write-ahead log), le group commit, la recovery, le LSM-tree de
   runs en niveaux et ses merges, les grands groupes, le page cache et S3-FIFO, un seul writer et les domains, Generic
   Join, comment tout cela est testé.
3. [Le serveur](server.md) : `cepheus serve`, cluster.toml, les tokens et les droits, le wire protocol octet par octet,
   les sessions (une écriture appliquée une seule fois, G14), les lectures locales dans la mémoire même du programme
   (linearizable, G15), les droits (G16), sa vitesse à côté de PostgreSQL, serveur contre serveur.
4. [Cepheus depuis Cesia](cesia.md) : le client Cesia, un package natif : `Connect`, les kinds et leurs valeurs,
   `Insert`, `Get`, `Update`, `Write` avec `Expect` et `Incr`, les questions avec `Find`, les forks pour les tests, les lectures
   locales, beaucoup de fibers sur une seule connexion, ses erreurs et sa vitesse à côté du client OCaml et de
   PostgreSQL.
5. [Tester](testing.md) : les forks pour les tests d'une application, et comment Cepheus lui-même est testé.
6. [Règles](rules.md) : les règles Datalog tenues par le writer — les faits dérivés, la semi-naive evaluation,
   Backward/Forward pour les retraits, les contraintes, le budget, `why`, et ce que coûte une écriture avec des règles.
7. [Le vault de fichiers](vault.md) : des fichiers gardés dans la base de données : des chunks (des morceaux)
   découpés selon leur contenu (FastCDC), nommés par un BLAKE2b à clé et stockés une seule fois, compressés (LZ4 pour
   les fichiers tièdes, Zstandard pour les froids), scellés (AEGIS-256) sous la clé de leur propriétaire, lus par
   plages et vérifiés à chaque lecture ; l'effacement d'un propriétaire ; ce qui manque à une copie, grâce aux Merkle
   trees (des arbres de hachages).
8. [Un cas : ne jamais vendre deux fois la même place](case-seats.md) : un vrai problème résolu pas à pas, de son
   énoncé jusqu'à la preuve qu'il est résolu (un test, des ordonnancements générés, un modèle TLA+, kill -9 avec un
   vérificateur de l'historique, la vitesse à côté de SQLite et de PostgreSQL).

**Référence**
- [API](api.md) : chaque fonction et chaque type publics, avec ses paramètres, son résultat, ses erreurs et un exemple.
- [Erreurs](errors.md) : chaque message, d'où il vient, ce qu'il veut dire, ce qu'il faut faire.
- [Limites et valeurs par défaut](limits.md) : chaque borne et chaque valeur par défaut, et l'endroit où elle est fixée.
- [Garanties](guarantees.md) : G1 à G24 (G14 à G16 celles du serveur, G17 à G20 celles des règles, G21 celle des
  questions vivantes, G22 à G24 celles du vault), sous quelles pannes, leurs conditions exactes, leurs preuves et
  leurs tests.
- [Exploitation](operations.md) : les fichiers, l'ouverture et la recovery, les dommages et les erreurs du disque, la
  sauvegarde, la vérification, la mémoire, l'espace disque, les outils.
- [Formats de fichier](formats.md) : les fichiers du journal et des runs, octet par octet.
- [Internes](internals.md) : les modules du moteur, pour les tests et les outils.

**Recherche et mesures**
- [Théorie](theory.md) : les mathématiques (la recovery, le group commit, les index, Generic Join, l'isolation, le
  cache, les merges) et la recherche qui les fonde.
- [Benchmarks](benchmarks.md) : la méthode, et Cepheus contre PostgreSQL 18.6 et SQLite 3.54 sur une même machine.
- [Comparaison](comparison.md) : les nombres mesurés à côté des conceptions publiées des géants (Oracle, Datomic,
  RocksDB, Neo4j, FoundationDB, CockroachDB), et là où chacun gagne.
- [Références](references.md) : chaque travail cité, vérifié, avec ce que Cepheus en a pris.
- [Glossaire](glossary.md) : chaque terme, en mots simples, avec sa page.

Chaque exemple OCaml de ces pages est un programme entier que `dune test` compile et exécute, en vérifiant la sortie
montrée en dessous.
