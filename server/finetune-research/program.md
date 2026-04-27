# WE Polish 微调研究 v2

## 目标

通过微调 Qwen3-0.6B，解决三个问题：
1. **短文本指令遵循**：输入"邮箱"、"现在呢"等短文本时，模型应原样输出或仅做标点修正，不应生成长篇回答
2. **重复生成**：输入含口语重复结构的文本时（"去去去去去运行"），模型不应陷入重复循环
3. **长文本完整输出**：685字输入应完整输出，不应提前停止

同时保持：纠错能力（Claude Code、Tailscale 等术语纠错）不退化。

## 基线

当前模型 we-polish（v3），25 条真实数据测试通过率 96%（24/25），但：
- 短文本 pass-through：8 条中 7 条失败（12.5%）
- 重复生成：3 条中 1 条失败（66.7%）
- 纠错能力：5 条中 4 条通过（80%）
- 长文本：5 条中 4 条通过（80%），685字那条固定失败

综合测试集（短文本+纠错+重复+长文本）通过率待建立。

## 度量指标

使用 test_polish.sh 测试套件，20 条用例：
- 8 条短文本 pass-through
- 5 条纠错
- 3 条重复生成
- 4 条长文本（不同长度的真实数据）

**通过率 = 通过数 / 20**

## 实验环境

- 服务器：114.28.243.122（4080 16GB）
- 基座模型：Qwen/Qwen3-0.6B
- 训练框架：QLoRA（train_qlora.py）
- 推理：ollama
- 训练数据：~/.we/ 下的各 jsonl 文件
- 纠错词典：~/.we/correction-dictionary.json（55 个正确词，93 个错误变体）

## 约束

- GPU 显存 16GB，其中 ollama + llama-server 占约 13GB
- 训练前需停掉 llama-server 腾显存
- 每次训练约 1-2 分钟（550 条数据，2-3 epochs）
- 每次实验：改数据/参数 → 训练 → 合并导出 → ollama create → 跑测试 → keep/discard

## 实验循环

LOOP:
1. 分析当前失败用例的模式，提出假设
2. 修改训练数据或训练参数（一次只改一个变量）
3. 训练
4. 部署到 ollama
5. 跑测试套件
6. 记录结果到 results.tsv
7. 如果通过率提升 → keep，否则 → discard（回退到上一版数据/参数）
8. 分析结果，提出下一个假设

## 当前训练数据构成

```
~/.we/training-data-v4.jsonl（545 条）
  generated_error: 225  — 纠错短句（从 correction-dictionary 生成）
  passthrough_real: 159 — voice-history 中正确的短句
  passthrough: 88       — 手写短句 pass-through
  real: 53              — 真实 SA 错误纠正对
  filler_removal: 20    — 语气词清洗
```

## 当前训练参数

```
epochs: 8-10
batch_size: 8
lr: 1e-4
lora_rank: 32
lora_alpha: 64
target_modules: 全部 7 层
lora_dropout: 0
system_prompt: "文本纠错。不要回答用户的问题。只输出结果。"
```

## 已知的过拟合研究结论（之前调研）

- epochs 应降到 2-3
- lr 应降到 5e-5
- lora_rank 应降到 8-16
- target_modules 应只用 q_proj, v_proj
- 应加 lora_dropout=0.05
- pass-through 比例应在 35-45%（当前 45% 合理）
- 可启用 NEFTune（neft_alpha=5.0）
