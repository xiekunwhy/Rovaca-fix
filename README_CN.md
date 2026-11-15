# Rovaca-fix（中文版说明）

本仓库是 **[ZephyRoy/Rovaca](https://github.com/ZephyRoy/Rovaca) v1.1.0**（GATK HaplotypeCaller 的 C++ 重写）的社区修复版：修复了在深度/复杂基因组上的**内存无限增长直至 OOM** 的问题，新增 **CRAM 输入**与**超长染色体 CSI 索引**支持，**变异结果与原版完全一致、速度无回退**。

> English version: see [README.md](README.md).

---

## 这个仓库为什么存在

Rovaca v1.1.0 能以约 60 倍于 GATK 的速度复现 HaplotypeCaller 结果，但在真实的非模式物种数据（深度 WGS、pool-seq）上，它的**内存会随运行时间线性增长，直到被系统 OOM-killer 杀掉**（见上游 [issue #3](https://github.com/ZephyRoy/Rovaca/issues/3)——从 48G 一路加到 256G 依然不够）。

我们用 heaptrack / LeakSanitizer / ASan 对整条流水线做了画像，找到并修复了根因。所有修复都以普通源码改动形式包含在本仓库中（`rovaca-oom-fix.patch` 为等效 unified diff）。

## 修复前后对比

同一台机器、同一份数据（Tm211，柽柳 *Tamarix chinensis*，~90x WGS），完整 chr12（77Mb），GVCF 模式，8 线程：

| 指标 | v1.1.0 原版 | 本仓库修复版 |
|---|---|---|
| 运行期 RSS | 2.9 → **6.9 GB，仍以 ~180 MB/分钟上涨** | 3.1 → **3.7 GB，平台期不再增长** |
| 运行时间 | ~21 分钟 | ~21 分钟（无回退） |
| GVCF 输出 | 基线 | **逐字节一致（200 万+ 行零差异）** |
| 全基因组峰值预估（63 条 contig） | 无上限（issue 报告 36~256G 仍 OOM） | 8-10 线程约 **4-8 GB** |

Writer 现在每 5 分钟输出一行 `mem stats: rss=... backlog=... spilled=...`，内存行为可直接观测。

## 修了什么

### 1. 核心元凶：Dijkstra 路径搜索的 per-region 内存泄漏（OOM 根因）

heaptrack 把 2.19 GB 峰值内存归因到同一个分配点：

- `hc_assemble_dijkstra_find_best_haplotypes` 的主循环在结果数达到上限时**带着满队列退出**；
- 队列清理函数 `hc_assemble_dijkstra_reset_tree` 擦除节点时只释放了边的链表项，**路径节点本身从未归还**；
- 底层 `mem_pool_fast` 内存池只进不出，遗留节点被永久驻留。复杂区域（深度/pool-seq/高杂合非模式基因组）每个 region 可遗留数千节点 → arena 线性无限增长。

**修复**：一行代码——在清理循环里把节点归还内存池 free list（`hc_assemble_dijkstra_shortest_path.c`）。速度不变，输出逐字节一致。

### 2. Writer 积压 OOM 兜底从未接线

Writer 必须按全局 `source_id` 顺序写出，乱序结果**无上限**地在内存中堆积——一个卡住的复杂区域就能堆出几十 GB。v1.1.0 其实写了落盘逃生门，但：

- `--write-tmp` 定义了常量却**从未注册进参数解析**（传参会报错），对应的标志位还是**未初始化变量** → 落盘实际从未生效；
- 落盘阈值计数器每次 pop 都 +1，但顺序写出的任务从不 -1（语义失效）；
- 临时文件写失败时会**静默丢弃**该段变异记录。

**修复**：`--write-tmp` 注册并**默认开启**（`--write-tmp=false` 关闭）；积压计数改为只统计真实积压；写失败改为保留在内存而不是丢数据；回读做完整性校验；落盘活动打日志。Writer 内存由此封顶（内存中最多约 128 份结果文本，其余落到输出文件旁的临时文件，写完自动清理）。

### 3. 内存占用优化

- `result_queue` 容量 2048 → 128（原来是最瞬时缓冲：2048 × 数 MB GVCF 文本，高杂合基因组上可达 ~10 GB）；
- 启动时 `mallopt(M_ARENA_MAX, 2)` + `M_MMAP_THRESHOLD=128K`：大块分配走 mmap，free 后立即归还 OS，不再堆积在 glibc 的 per-thread arena 里；
- `--index=false`：跳过进程内 tabix 索引构建（htslib 会把所有索引记录攒在内存直到运行结束，大/高杂合基因组上好几个 GB），跑完用 `tabix -p vcf out.vcf.gz` 补索引即可。（`--index` 本身在原版也是坏的：帮助里隐藏且语义反转，已修复并写进文档。）

### 4. CSI 索引（输出侧）

TBI 索引单条 contig 上限 2^29 bp（512Mb）——超过就会在算了几个小时之后建索引时报错退出。Writer 检测到长 contig 会**自动切换为 CSI**（`.csi`）。fix.5 中，TBI/CSI 统一走 htslib 自己的 `hts_idx_tbi_name()` tid/meta 路径（与 `vcf_write` 相同），删除了此前自定义的 CSI tid/meta 构建。已用官方 `tabix` 验证真实 SNP 和高坐标 GVCF 记录、多 contig header、40 线程、BAM CSI 与 CRAM CRAI 输入、BAI/TBI 输出，并确认开启/关闭索引的 VCF 正文完全一致；ASan 在 SNP→CSI 写入/查询路径未发现内存错误。索引测试不能替代对你自己的 >512Mb contig 做变异呼叫验证。

### 5. CRAM 输入

原版没有给 htslib 传参考序列，CRAM 无法解码。现在会通过 `hts_set_fai_filename()` 把 `-R` 指定的参考传给解码器——`-I sample.cram`（配 `.crai`）直接可用，无需设置 REF_PATH、无需联网。已验证：同一份数据的 CRAM 与 BAM 输出逐字节一致。

### 6. 两个顺手修掉的正确性/工程问题

- **stack-use-after-return**（ASan 检出）：组装图哈希表把调用者栈上变量的地址存为 key（`hc_assemble_vertex_sequence_spliter.c:212` 等 3 处），函数返回后再次被 `memcmp` 读取，属未定义行为。现在 `assemble_graph_hash_insert*` 会把 key 内容复制到节点自有存储，ASan 复跑干净。
- **头文件 ODR 违规**：40+ 处头文件中的非 inline 函数定义（`downsampler_hc.h`、`valid_file.h`、`ring_mem_pool.hpp`、`reads_filter_hc.h`、`reads_filter_lib.h`、`rovaca_tool.hpp`、`rovaca_tool_args.h`）已全部补 `inline`，静态链接**不再需要** `-Wl,--allow-multiple-definition` 遮羞布。

### 7. 多倍体支持（`--ploidy N`，1-20）

引擎里本来就埋着任意倍性基因分型的框架（`HomogeneousPloidyModel`、`GenotypeLikelihoodCalculator(ploidy, ...)`），但被作者人为锁住（`ploidy != 2` 直接退出），且多处多倍体代码从未被真实跑过、全是 bug。本轮把整条链路打通，修复的全部是上游 bug：

- `GenotypeAlleleCounts::next()` 把"定位拷贝"错写成"追加"，基因型表在倍性 ≥3 时指数膨胀（启动即 bad_alloc）；
- `many_component_genotype_likelihood_by_read` 读取空向量而非基因型的等位计数（多等位位点直接 out_of_range）；
- `MathUtils::approximate_log10sum_log10(values, begin, end)` 在**整个 buffer**（而非 `[begin,end)` 区间）上取最大值——未使用的 0 值槽位让所有 ≥3 等位组分的基因型"最可能"，PL 全部退化为 0、位点被错判为 hom-ref；
- 输出层的二倍体硬编码：GT 数组（`genotype2bcf`）、GVCF hom-ref 块 GT、`RefVsAnyResult` 似然容量、`TWO_PLOIDY_LIKELIHOOD_CAPACITY`、只按二倍体构建的 `GenotypeLikelihoodsCache`；
- 活性区域检测的倍性接线（`HcActiveBase`）+ 新增 `--ploidy` 命令行参数（默认 2，与 GATK `--ploidy` 兼容）。

验证：合成四倍体数据（60x，设计等位基因频率 0.25/0.5/0.75/1.0）——GT 判定为 `0/0/0/1`、`0/0/1/1`、`0/1/1/1`、`1/1/1/1`，VCF 与 GVCF 两种模式下 PL 区分度、MLEAC/MLEAF 均正确；二倍体输出在合成与真实数据回归集上与上一版**逐字节一致**。

### 8. 缺失 `@RG` / `SM` 导致段错误（fix.6）

创建 VCF header 时，原代码使用 `strstr(strstr(bam_hdr->text, "@RG"), "SM")` 提取样本名，但未检查空指针。BAM 没有 read group，或 read group 缺少 `SM` 时，会在输出索引的启动日志之后立即段错误。现在引擎与 Writer 统一通过 htslib 读取 tag，不再直接对字符串搜索结果解引用。缺失 `RG`、缺失 `SM` 两种输入均已通过 VCF/GVCF、40 线程和 ASan 验证；正常 `@RG/SM` 输入的 VCF 变异记录保持不变。fix.7 新增 `--sample-name`，最终回退样本名改为输入文件名，不再统一叫 `sample`。

### 9. 整合的健壮性改进（fix.7）

- Writer 固定 128 MB 的乱序数组改为稀疏表：省去预分配，并消除 `source_id` 超过旧数组大小后的越界风险；重复 source ID 会明确报错。
- 空 GVCF 区域的 GT/PL 按请求倍性输出，不再写死为二倍体。
- 新增 `--sample-name`、`--heterozygosity`、`--indel-heterozygosity`；默认先验仍为 GATK 兼容的 `0.001` 和 `0.000125`。样本名默认按 `SM` → `ID` → 输入文件名解析，显式参数可覆盖。
- `--inspect-reads` 在 BAM 未声明 read group 时不再误过滤全部 reads。
- genotype 偏移计算改用 `int64_t` 并传播溢出标记，计算器入口在分配前拒绝溢出；似然数量静态缓存直接覆盖 1–20 倍性。
- read-group 解析和每个输入文件的 HTS 线程池/缓存初始化得到加固，不改变呼叫算法。

对方提出的 `max-genotype-count` 等位基因剪枝重写**没有并入**：它会改变变异结果，且尚未完整保留 GVCF 等位与注释信息。fix.7 未改变任何等位剪枝行为。

## 验证情况

- **结果一致性**：修复版与原版同构建输出 200 万+ 行 GVCF **零差异**；静态版与动态版之间仅有 2 个位点 QUAL 相差 0.001（浮点末位抖动，基因型/PL 完全一致——与 GATK 官方文档中 native vs Java PairHMM 的说明同类）。
- **回归套件**（合成二倍体数据：12 条 contig、48 个设计 SNP/Indel）：VCF/GVCF、CRAM 输入、默认 TBI、`--index=false`、帮助文本——9/9 通过。
- **落盘压力测试**（阈值强制为 0）：250 个结果落盘 → 回读 → 输出与正常跑逐字节一致，临时文件零残留。
- **速度**：真实数据 chr12 运行时间与原版相同（Rovaca 对 GATK 约 60 倍的性能不受影响）。
- **fix.7 整合验证**：正常二倍体 VCF 正文与 fix.6 完全一致；缺失 RG/ID 和样本名覆盖检查通过；无 RG 的 `--inspect-reads` 过滤数为 0；四倍体空块包含 4 个 GT 等位和 5 个 PL；199 个乱序 Writer 任务中 71 个落盘，最终 200 条记录顺序正确且临时文件零残留；相同四线程测试的峰值 RSS 从 1,834,716 KB 降至 1,703,988 KB（约 127.7 MiB）。

## 使用方法

```bash
rovaca HaplotypeCaller \
  -I sample.bam -R ref.fa -O sample.g.vcf.gz \
  --emit-ref-confidence GVCF \
  --nthreads 10 \
  --index=false          # 可选：省索引内存；跑完用 tabix -p vcf sample.g.vcf.gz 补索引
```

建议：

- `--max-reads-depth` 默认 50，与 GATK 的 `--max-reads-per-alignment-start` 默认值一致——想和 GATK 基线对齐就别动它（对内存预算也最友好）；
- 每个作业 4-10 线程足够，内存稳定在个位数 GB；
- 特别大/特别深的基因组，仍建议按染色体 `-L chr.bed` 分片跑 job array；
- 运行要求：x86-64 Linux，CPU 支持 AVX2（推荐 AVX-512）；输入 BAM/CRAM 均可；输出索引 TBI/CSI 自动选择。

## 编译

### 普通（动态链接）构建

依赖：GCC ≥ 9、CMake ≥ 3.16、Boost ≥ 1.69 头文件 + `program_options` 库。

```bash
git clone https://github.com/xiekunwhy/Rovaca-fix.git
cd Rovaca-fix
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=../release ..
make -j$(nproc) && make install   # 二进制与依赖库在 release/lib/ 下
```

Boost 头文件不在标准位置（`/usr/include`）时，编译前先导出（部分模块只认头文件路径）：

```bash
export CPLUS_INCLUDE_PATH=/path/to/boost/include
```

免 root 小技巧：先跑一遍 `bash build_static.sh`，它会把 Boost 头文件一并放进 `third_lib/static-deps/include`，静态/动态两种 configure 都能自动找到。

### 全静态构建（单文件、免 root、免依赖）

```bash
bash build_static.sh        # 依赖自动获取到 third_lib/static-deps（不入库）
# -> build/bin/rovaca       # 全静态，内核 >= 3.2 即可，与宿主 glibc 无关
```

`build_static.sh` 通过 `apt download`（无需 root）获取 zlib/bzip2/xz/Boost 静态库与 Boost 头文件，静态编译 htslib 1.18，然后以 `-DROVACA_STATIC=ON` 配置编译。非 Debian 系系统请先手工把对应的 `.a` 与头文件放到 `third_lib/static-deps/{lib,include}`。

## 预编译二进制

见 [Releases](https://github.com/xiekunwhy/Rovaca-fix/releases)：`rovaca`（x86-64、全静态、strip 后约 6 MB）。

- sha256：`d66fde6b1c144e2e19db15f62cf636cfd94fd8a822c82c8e655a1cfe28eb577e`
- 要求：x86-64 Linux，内核 ≥ 3.2，CPU 支持 AVX2（推荐 AVX-512）；免 root、无动态库依赖
- `scp` 到集群 → `chmod +x rovaca` → 直接运行

## 遗留说明（给上游）

- 泄漏修复后，剩余内存主要是静态预分配（约 2×N × 140 MB 的 RegionResource），属设计内的有界占用；
- 哈希 key 悬空指针、头文件 ODR 两个上游问题**已在本仓库修复**（见上文第 6 节），欢迎上游参考。

## 致谢与协议

- 上游：[ZephyRoy/Rovaca](https://github.com/ZephyRoy/Rovaca)（MIT），GATK HaplotypeCaller C++ 重写的原作者；
- 修复、画像分析与静态构建：[@xiekunwhy](https://github.com/xiekunwhy) 与 AI 结对编程助手，调试过程见 [issue #3](https://github.com/ZephyRoy/Rovaca/issues/3)；
- 协议：MIT（与上游一致）。
