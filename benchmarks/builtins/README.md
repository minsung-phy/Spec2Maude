# Builtin backend regression

Run `./run.sh` from any directory. It regenerates the main and builtin Maude
modules, checks the expected diagnostic classification, rejects every Maude
Warning/Advisory/Error, and executes the smoke term for every builtin registry
entry marked `IMPLEMENTED`.

The current source has one intentionally visible invalid inverse annotation:
`$fbits_` points at `$inv_ibits_` rather than the type-compatible
`$inv_fbits_`. The script therefore expects one Unsupported diagnostic while
still loading and testing the generated modules. The 19 nondeterministic or
search-like builtin entries remain obligations.
