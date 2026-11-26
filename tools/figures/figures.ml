(* The figures of the book, made again from the repository's root:

     dune exec tools/figures/figures.exe -- docs

   Each is a small SVG of its own (draw.ml): the mechanisms drawn from the answers the engine gives (windows.ml,
   model.ml: every row and number in them is the engine's), the parts of the server and the vault (machine.ml: the
   vault's chunks cut by the vault's own chunker), and the measures beside PostgreSQL and SQLite (bench.ml: read from
   the tables of docs/book/benchmarks.md and docs/book/server.md, so that a figure says what its table says). A figure
   with words is written in English into docs/book/images and in French into docs/fr/book/images. *)

let () =
  let docs = if Array.length Sys.argv > 1 then Sys.argv.(1) else "docs" in
  Windows.draw docs;
  Model.draw docs;
  Machine.draw docs;
  Bench.draw docs
