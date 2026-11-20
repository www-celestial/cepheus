#!/bin/sh
# surface.sh REV: the public surface of Cepheus at git REV, one line per item, sorted within each section.
# Run from the repository. Diff two outputs to find what changed.
rev=$1
show() { git show "$rev:$1" 2>/dev/null; }
echo "## OCaml API (src/cepheus.mli, above the internals)"
show src/cepheus.mli | awk '/Internals, for the tests and tools/{exit} {print}' | sed 's/(\*\*.*\*)//' | grep -E '^(val|type|exception|module|  val|  type|  \|)|^ *\| [A-Z]' | sed 's/[[:space:]]\+/ /g'
echo "## OCaml API internals (modules re-exported, may change)"
show src/cepheus.mli | awk 'f{print} /Internals, for the tests and tools/{f=1}' | grep -E '^(val|module)'
echo "## Cesia package cepheus (cesia/cepheus/cepheus.ce)"
show cesia/cepheus/cepheus.ce | grep -E '^(defn )?[A-Z][A-Za-z0-9]*[( =]' | sed 's/ *=.*//; s/^defn //'
echo "## Cesia package owl (cesia/cepheus/owl/owl.ce)"
show cesia/cepheus/owl/owl.ce | grep -E '^(defn )?[A-Z][A-Za-z0-9]*[( =]' | sed 's/ *=.*//; s/^defn //'
echo "## Native interface (cesia.toml natives)"
show cesia.toml | grep '^natives' | tr -d '[]" ' | sed 's/natives=//' | tr ',' '\n'
echo "## Keys the native binding reads or gives (cesia/native/*.ml string literals)"
for f in cesia/native/binding.ml cesia/native/conn.ml; do show $f | grep -o '"[A-Z][A-Za-z]*"'; done | sort -u
echo "## Wire and peer protocol constants"
for f in server/wire.ml server/replica.ml server/raft.ml server/raftlog.ml server/follower.ml server/fdpass.ml; do
  show $f | grep -E '^let (version|oldest|header|max_frame|k_[a-z_]+|f_[a-z_]+|[a-z_]*magic|p_[a-z_]+|t_[a-z_]+) = ' | sed "s|^|$f: |"
done
echo "## On-disk format constants"
for f in src/journal.ml src/wal.ml src/snapshot.ml src/engine.ml vault/vault.ml server/sessions.ml server/replica.ml server/raftlog.ml server/tokens.ml src/disk.ml; do
  show $f | grep -E '^let ([a-z_]*magic|format|[a-z_]*_format|header|page|block|seg_[a-z]+|tmp_suffix) = ' | sed "s|^|$f: |"
done
echo "## Run and journal file names"
show src/snapshot.ml | grep -E '^let (name|tmp_suffix)'
show src/journal.ml | grep -E '^let (seg_name|name)' 
echo "## CLI (bin/main.ml string literals)"
show bin/main.ml | grep -o '"[a-z-]\{2,\}"' | sort -u | tr '\n' ' '; echo
echo "## Server config keys (server/config.ml, server/tokens.ml string literals)"
for f in server/config.ml server/tokens.ml; do show $f | grep -o '"[a-z_]\{2,\}"' | sort -u | tr '\n' ' ' | sed "s|^|$f: |"; echo; done
echo "## Error type constructors (src/engine.ml type error) and the message texts"
show src/engine.ml | awk '/^type error =/{f=1} f{print} f&&/^$/{exit}' | grep -E '^\s*\|' | sed 's/(\*.*//; s/[[:space:]]\+/ /g'
echo "## Guarantees (docs/book/guarantees.md headings)"
show docs/book/guarantees.md | grep -E '^## G[0-9]+'
