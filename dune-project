(lang dune 3.0)

(name code_examples)

(generate_opam_files true)

(package
 (name code_examples)
 (depends
  (core_unix
   (>= 0.15.0))
  (async
   (>= 0.15.0))
  yojson
  hex_encode))
