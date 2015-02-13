
module Makefile where

import Text.PrettyPrint

import Data.String.Utils

import Prelude hiding(all)

($\$) t = ((t <> text "\n") $$)
tab = text "\t"
all = text "all"
bench = text "bench"
clean = text "clean"
rm args = (text "rm -rf" <+> hsep args)
phony = text ".PHONY"
cc args = (text "$(CC)" <+> hsep args)
flags = text "$(FLAGS)"
bench_flags = text "$(BENCH_FLAGS)"
target = text "$(TARGET)"
inc = text "$(INC)"
lib = text "$(LIB)"
deps = text "$(DEPS)"
dSYM = text ".dSYM"
i = (text "-I" <+>)
o = (text "-o" <+>)
parent = text ".."

generateMakefile :: [String] -> String -> String -> String -> String -> String -> Doc
generateMakefile classFiles progName compiler ccFlags incPath libs =
    decl "CC" [compiler]
    $$
    decl "TARGET" [progName]
    $$
    decl "INC" [incPath]
    $$
    decl "LIB" [libs]
    $$
    decl "FLAGS" [ccFlags]
    $$
    decl "BENCH_FLAGS" [replace "-ggdb" "-O3" ccFlags]
    $$
    decl "DEPS" ("shared.c" : classFiles)
    $\$
    rule all target
         empty
    $\$
    rule target deps
         (cc [flags, i inc, i parent, lib, deps, lib, lib, o target])
    $\$
    rule bench deps
         (cc [bench_flags, i inc, i parent, lib, deps, lib, lib, o target])
    $\$
    rule clean empty
         (rm [target, target <> dSYM])
    $\$
    rule phony (all <+> bench <+> clean)
         empty
    where
      decl var rhs = text var <> equals <> hsep (map text rhs)
      rule target deps cmd
          | isEmpty cmd = target <> colon <+> deps
          | otherwise   = target <> colon <+> deps $$
                          tab <> cmd
