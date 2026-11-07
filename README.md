# Cepheus

A database of facts, in OCaml. Everything is a fact `(thing, property, value)`; a write is a group of facts, all or
nothing, with who and why: the group is the event, kept for ever in an append-only journal. Reads take a view, the
exact state after some group, with no lock. A fork is a temporary state, written to like the database, never written
to disk: the base of unit tests and what-if questions.

- Build: `dune build`; tests: `dune test` (unit and property tests, the exhaustive crash enumeration, the
  deterministic simulation); the slow ones: `tools/test.sh`.
- Documentation: [docs/](docs/README.md): concepts, guarantees with their proofs and tests, theory and references, the
  API, operations, testing with forks, file formats, benchmarks.

No dependency but OCaml 5 (`unix`, `threads`), and no C.
