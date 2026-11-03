"""Vendored subset of gnnid's parse+resolve logic for the streaming flow
resolver (see ../flow_resolver.py).

Why vendored instead of `pip install gnnid`: gnnid's own package declares
torch/torch-geometric/gensim/xgboost as hard dependencies (needed for its
offline training pipeline), none of which the resolver path touches. Pulling
the full package onto a bare Kafka broker VM would mean installing all of
that for nothing. `schema.py`/`resolve.py`/`hubble.py` here are straight
copies of gnnid's `src/gnnid/{schema,resolve,ingest/hubble}.py` with the
pandas-only helpers dropped — stdlib only.

If gnnid ever splits its parse/resolve code into its own dependency-light
package, this directory should be deleted in favor of depending on that
package directly. Until then, keep these in sync by hand when gnnid's
resolve.py/hubble.py/schema.py change.
"""
