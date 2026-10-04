# Rovaca-fix

A community-patched build of **[ZephyRoy/Rovaca](https://github.com/ZephyRoy/Rovaca) v1.1.0** (a C++ re-implementation of GATK HaplotypeCaller), fixing **unbounded memory growth / OOM** on deep or complex genomes, and adding **CRAM input** and **CSI index** support — with no change to variant calls and no measurable slowdown.

> **中文摘要**：本仓库是 Rovaca v1.1.0 的修复版。核心修复是 Dijkstra 路径搜索里一个导致内存随 region 数无限增长的节点泄漏（一行代码），外加 Writer 积压落盘兜底（`--write-tmp`，默认开）、内存占用优化（大队列砍容量、malloc 调优、`--index=false` 可关索引省数 GB）、CRAM 输入、超长染色体自动 CSI 索引、以及每 5 分钟内存日志。实测 77Mb 染色体 8 线程：RSS 从"6.9G+ 不封顶"变为"3.7G 平台"，运行时间不变，200 万行 GVCF 输出与原版逐字节一致。提供全静态编译的单文件二进制（x86-64，无需 root/依赖）。

---

## Why this fork exists

Rovaca v1.1.0 reproduces GATK HaplotypeCaller results ~60x faster, but on real non-model genomes (deep WGS, pool-seq) its memory **grows linearly with runtime until the kernel OOM-killer stops it** ([issue #3](https://github.com/ZephyRoy/Rovaca/issues/3) — 48 GB → 256 GB was still not enough).

We profiled it end-to-end and fixed the root causes. All fixes are in this repository as ordinary source changes (see `rovaca-oom-fix.patch` for the equivalent unified diff).

## Headline results

Same machine, same data (Tm211, *Tamarix chinensis*, ~90x WGS), full chr12 (77 Mb), GVCF mode, 8 threads:

| Metric | v1.1.0 (original) | v1.1.0-fix (this repo) |
|---|---|---|
| RSS over the run | 2.9 → **6.9 GB, still climbing ~180 MB/min** | 3.1 → **3.7 GB, flat plateau** |
| Runtime | ~21 min | ~21 min (no regression) |
| GVCF output | baseline | **byte-identical (0 diffs in 2M+ lines)** |
| Projected whole-genome peak (63 contigs) | unbounded (OOM at 36-256 GB reported) | ~4-8 GB at 8-10 threads |

Memory stats are now observable at runtime: the writer logs `mem stats: rss=... backlog=... spilled=...` every 5 minutes.

## What was broken and what we fixed

### 1. The big one: per-region leak in the Dijkstra path finder (root cause of the OOM)

Found with [heaptrack](https://github.com/KDE/heaptrack) (2.19 GB of peak consumption traced to one allocation site).

- The best-path search loop in `hc_assemble_dijkstra_find_best_haplotypes` exits as soon as the result cap is reached, **leaving all remaining path nodes in the rb-tree queue**.
- The queue purge `hc_assemble_dijkstra_reset_tree` erased those nodes and freed their edge lists — **but never freed the path nodes themselves**.
- The underlying `mem_pool_fast` keeps its pages forever, so every leftover node was permanently retained. Complex regions (deep/pooled/non-model data) can leave thousands of nodes per region → arena grows linearly forever.

**Fix:** one line — return the erased node to the pool's free list in the purge loop (`hc_assemble_dijkstra_shortest_path.c`). Runtime unchanged; output byte-identical.

### 2. Writer backlog OOM protection was never wired up

The Writer must emit results in global `source_id` order; out-of-order results were buffered **without bound** — a single slow region could pile up tens of GB. v1.1.0 already had a spill-to-disk escape hatch, but:

- `--write-tmp` was defined but **never registered** in the option parser (passing it errored out), and the backing flag was an **uninitialized bool** → spill effectively disabled.
- The spill threshold counter was incremented on every pop but never decremented for in-order writes (broken semantics).
- If a temp-file write failed, the result was **silently dropped** from the output VCF.

**Fix:** `--write-tmp` registered and **on by default** (`--write-tmp=false` to disable); backlog counter now counts real backlog; write failures keep data in memory instead of losing it; read-back is verified; spill activity is logged. Writer memory is now bounded (~128 full result texts, rest goes to temp files next to the output, auto-cleaned).

### 3. Footprint reductions

- `result_queue` capacity 2048 → 128 (was the largest transient buffer: 2048 × multi-MB GVCF texts ≈ up to ~10 GB on heterozygous genomes).
- `mallopt(M_ARENA_MAX, 2)` + `M_MMAP_THRESHOLD=128K` at startup: big allocations go to mmap and are returned to the OS on free, instead of accumulating in per-thread glibc arenas.
- `--index=false`: skip the in-process tabix index build (htslib accumulates all index records in memory — several GB on large/heterozygous genomes). Rebuild afterwards with `tabix -p vcf out.vcf.gz`. (`--index` itself was also broken upstream: hidden from help and inverted; now fixed and documented.)

### 4. CSI index support (output side)

TBI cannot index contigs ≥ 2^29 bp — on such genomes the run would previously die mid-write after hours of compute. The writer now detects long contigs and **automatically switches to CSI** (`.csi`, tabix-compatible meta). Verified with `tabix -l` and region queries on VCF and GVCF output. BAM/CRAM input indexes (`.bai`/`.csi`/`.crai`) were already handled by htslib.

### 5. CRAM input support

The loader never passed the reference to htslib, so CRAM input could not decode. It now sets `-R` via `hts_set_fai_filename()` — `-I sample.cram` (+ `.crai`) works with the reference you already provide; no `REF_PATH`/network needed. Verified: CRAM vs BAM runs are byte-identical.

### 6. Build & portability

- `assemble_argument.h`: added missing `#include <cstdint>` (fails with GCC 13 + Boost 1.83 headers otherwise).
- New `ROVACA_STATIC` CMake option + `build_static.sh`: reproducible fully-static single-file binary (see below).

## Verification

- **Output equivalence**: 2M+-line GVCF diff of fixed vs. original build: **0 differences**. Static vs. dynamic builds show only a ±0.001 QUAL last-bit FP jitter at 2 sites (calls, genotypes, PLs identical — same class as GATK's native-vs-Java PairHMM note).
- **Regression suite** (synthetic diploid set, 48 designed SNPs/indels, 12 contigs): VCF/GVCF modes, CRAM input, TBI default, `--index=false`, help text — 9/9 pass.
- **Spill stress test** (threshold forced to 0): 250 results spilled → read back → output byte-identical, temp files cleaned.
- **Speed**: identical runtime on real-data chr12 (Rovaca's ~60x-vs-GATK performance is untouched).

## Usage

```bash
rovaca HaplotypeCaller \
  -I sample.bam -R ref.fa -O sample.g.vcf.gz \
  --emit-ref-confidence GVCF \
  --nthreads 10 \
  --index=false          # optional: save index memory; run `tabix -p vcf sample.g.vcf.gz` afterwards
```

Recommendations:

- `--max-reads-depth` defaults to 50, identical to GATK's `--max-reads-per-alignment-start` default — leave it alone for GATK-comparable results (and for your memory budget).
- 4-10 threads per job is plenty; memory now stays in single-digit GB.
- On very large/deep genomes, per-chromosome sharding with `-L chr.bed` remains a good practice (job arrays).
- Requirements: x86-64 Linux, CPU with AVX2 (AVX-512 preferred). BAM and CRAM input; TBI/CSI output indexes chosen automatically.

## Building

### Standard (dynamic) build

Prerequisites: GCC ≥ 9, CMake ≥ 3.16, Boost ≥ 1.69 headers + `program_options` library.

```bash
git clone https://github.com/xiekunwhy/Rovaca-fix.git
cd Rovaca-fix
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=../release ..
make -j$(nproc) && make install   # binary + bundled libs under release/lib/
```

If Boost headers are **not** in a standard location (`/usr/include`), point the compiler at them before `make` (some modules resolve them only via the include path):

```bash
export CPLUS_INCLUDE_PATH=/path/to/boost/include
```

Tip for root-less machines: running `bash build_static.sh` once also drops Boost headers into `third_lib/static-deps/include`, which both the static and the dynamic configure steps pick up automatically.

### Fully static build (single file, no root needed)

```bash
bash build_static.sh        # fetches deps into third_lib/static-deps (not committed)
# -> build/bin/rovaca       # statically linked, runs on kernel >= 3.2, glibc-independent
```

`build_static.sh` downloads zlib/bzip2/xz/Boost static archives and Boost headers via `apt download` (no root), builds htslib 1.18 statically, then configures with `-DROVACA_STATIC=ON`. On non-Debian systems, place the equivalent `.a` files and headers into `third_lib/static-deps/{lib,include}` first.

## Prebuilt binary

See [Releases](https://github.com/xiekunwhy/Rovaca-fix/releases): `rovaca` (x86-64, fully static, stripped, ~6 MB).

- sha256: `bab94004419028c6a3749451cefef18fac90d526b71562db84322407f3902124`
- Requirements: x86-64 Linux, kernel ≥ 3.2, CPU with AVX2 (AVX-512 preferred). No root, no shared libraries.
- `scp` it to your cluster, `chmod +x rovaca`, run.

## Known issues / notes for upstream

- ASan also flags a **stack-use-after-return** in the assembler: `hc_assemble_vertex_sequence_spliter.c:212` stores the address of the stack local `bottom` as a hash key, later read by `hash.c:165` (`memcmp`) after the function returned. Not fixed here — worth upstream attention.
- Several headers define non-`inline` functions (ODR violations); they make fully static linking depend on `-Wl,--allow-multiple-definition`. Marking them `inline` would be the clean fix.
- The remaining memory profile after the leak fix is dominated by static pre-allocation (≈ 2×N × 140 MB RegionResources) — expected and bounded.

## Credits & license

- Upstream: [ZephyRoy/Rovaca](https://github.com/ZephyRoy/Rovaca) (MIT), authors of the underlying GATK-HaplotypeCaller C++ re-implementation.
- Fixes, profiling and static build: [@xiekunwhy](https://github.com/xiekunwhy) with an AI pair-programming assistant, debugging together in [issue #3](https://github.com/ZephyRoy/Rovaca/issues/3).
- License: MIT (same as upstream).
