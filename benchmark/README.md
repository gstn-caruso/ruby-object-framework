# Reproducing the runtime comparison

Build Ruby 4.0.8 with YJIT and ZJIT available, then run:

```sh
ruby benchmark/compare.rb 20000 3 > benchmark/results.json
```

Each mode runs in a separate process. Each sample first performs 2,000 warmup
calls, then measures 20,000 application invocations. The operation constructs
scoped collaborators, calculates an integer result, and materializes an
independent value. The script verifies that the requested JIT is actually
enabled and that all processes produce the same checksum. Output includes raw
samples, elapsed time, allocations, Ruby build, and measurement date.

The checked-in run measured medians of approximately 0.091 seconds for the
interpreter, 0.050 for YJIT, and 0.061 for ZJIT. These are measurements of one
small framework workload on the development machine. They do not predict
network, storage, warmup, memory, or production application performance. Run
the comparison on representative workloads before choosing a deployment mode.
