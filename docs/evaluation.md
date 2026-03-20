# WE Evaluation Framework

## 1. Overview

WE evaluates quality across four layers, each targeting a different component of the ambient-voice and meeting-transcription pipeline. Evaluating layers independently allows precise attribution of errors.

```
Input Audio
  |
  +---> [Layer A] Transcription Quality (SpeechAnalyzer standalone)
  |         Metric: CER (Character Error Rate)
  |
  +---> [Layer B] Speaker Diarization (FluidAudio standalone)
  |         Metric: DER (Diarization Error Rate)
  |
  +---> [Layer C] L2 Polish Model (post-processing quality)
  |         Metrics: Fix% / Break% / CER / Latency
  |
  +---> [Layer D] Training Data Quality (LLM-as-Judge)
            Metrics: Correctness / Fidelity / Naturalness / Suitability
```

- **Layer A** measures how accurately Apple SpeechAnalyzer transcribes speech to text.
- **Layer B** measures how accurately FluidAudio identifies "who spoke when."
- **Layer C** measures whether the L2 polish model (Qwen, Gemini, or fine-tuned variants) improves or degrades transcription quality.
- **Layer D** measures the quality of distilled training pairs used to fine-tune the on-device L2 model.

All benchmarks were run on a **Mac Mini M4 (10-core CPU, 16GB RAM), macOS 26**.

---

## 2. Layer A: Transcription Quality

### What

Evaluate Apple SpeechAnalyzer CER on Chinese meeting audio, using the `inputAudioFile` API (file-based transcription, no streaming). This establishes the raw transcription baseline before any L1/L2 post-processing.

### Script

```
server/eval/benchmarks/run_transcription.sh
```

The script:
1. Builds `transcription-bench` (a Swift CLI tool using SpeechAnalyzer's file input API)
2. Runs batch transcription on all audio files listed in a manifest
3. Computes CER using `jiwer` (standard tool) against ground-truth references

### Dataset

**AliMeeting Eval set** (far-field, channel 0)

- Source: [OpenSLR 119](https://www.openslr.org/119/) (AliMeeting / M2MeT)
- License: CC BY-SA 4.0
- Language: Chinese
- 8 meetings, 2-4 speakers per meeting, 26-37 minutes each
- Overlap ratio: >30%
- Audio: 8-channel circular microphone array, single channel extracted (no beamforming)

### How to Reproduce

```bash
# Prerequisites
pip install jiwer

# Build the transcription bench tool
cd server/eval/transcription-bench && swift build -c release && cd ..

# Prepare dataset: place AliMeeting Eval mono WAVs and reference JSONs under
#   server/eval/datasets/Eval_Ali/ref/manifest.jsonl
#   server/eval/datasets/Eval_Ali/ref/*.json  (ground truth per meeting)

# Run
cd server/eval/benchmarks
./run_transcription.sh
```

Results are saved to `server/eval/results/alimeeting_transcription/cer_summary.json`.

### Results (2026-03-18)

Far-field (8ch array ch0, no beamforming):

| Meeting ID    | CER %  | Ref Chars | Hyp Chars | RTFx  |
|---------------|--------|-----------|-----------|-------|
| R8009_M8018   | 24.2   | 9,545     | 8,436     | 116.6 |
| R8009_M8020   | 24.7   | 10,091    | 8,925     | 127.1 |
| R8009_M8019   | 30.9   | 9,814     | 7,793     | 139.6 |
| R8003_M8001   | 33.7   | 11,731    | 9,168     | 121.3 |
| R8008_M8013   | 37.0   | 10,185    | 7,778     | 146.7 |
| R8007_M8011   | 38.5   | 12,844    | 8,916     | 126.3 |
| R8001_M8004   | 51.7   | 12,099    | 7,056     | 106.6 |
| R8007_M8010   | 62.1   | 17,028    | 7,349     | 137.8 |
| **Overall**   | **40.0** | 93,337  | 65,421    |       |

Near-field (per-speaker headset mic, 25 speaker files):

| Meeting Group   | Avg CER % | Speakers |
|-----------------|-----------|----------|
| R8008_M8013     | 17.8      | 3        |
| R8001_M8004     | 22.8      | 4        |
| R8009_M8019     | 23.7      | 2        |
| R8009_M8018     | 24.0      | 2        |
| R8007_M8010     | 25.9      | 4        |
| R8007_M8011     | 27.4      | 4        |
| R8009_M8020     | 39.3      | 2        |
| R8003_M8001     | 110.1     | 4 (2 speakers with severe hallucination, outlier) |
| **Overall**     | **34.0**  |          |
| **Excl. outlier** | **~25%** |        |

---

## 3. Layer B: Speaker Diarization

### What

Evaluate FluidAudio's offline diarization accuracy (DER) on two standard datasets: AMI (English) and AliMeeting (Chinese).

### Scripts

| Script | Dataset | Tool |
|--------|---------|------|
| `server/eval/benchmarks/run_diarization.sh` | AMI 1.6.2 test set | `fluidaudiocli diarization-benchmark` (built-in DER) |
| `server/eval/benchmarks/run_alimeeting_diarization.sh` | AliMeeting Eval far-field | `fluidaudiocli process` + `spyder` (external DER) |

### Datasets

**AMI Corpus 1.6.2**
- Source: [AMI Corpus Download](https://groups.inf.ed.ac.uk/ami/download/)
- License: CC BY 4.0
- 16 meetings (test set), English, 3-4 speakers, 14-50 min each
- Audio: headset-mix WAV 16kHz 16-bit
- RTTM via [pyannote AMI-diarization-setup](https://github.com/pyannote/AMI-diarization-setup)
- FluidAudio CLI has built-in AMI support (`--dataset ami-sdm --auto-download`)

**AliMeeting (M2MeT) Eval**
- Source: [OpenSLR 119](https://www.openslr.org/119/)
- License: CC BY-SA 4.0
- 8 meetings (eval set), Chinese, 2-4 speakers, 26-37 min each
- Overlap ratio: >30% (highest among all datasets used)
- Audio: 8-channel circular array, channel 0 extracted
- RTTM annotations provided

### How to Reproduce

**AMI:**

```bash
# Build FluidAudio CLI (if not already present)
cd /tmp && git clone --depth 1 https://github.com/FluidInference/FluidAudio.git
cd FluidAudio && swift build -c release

# Run benchmark (auto-downloads AMI data)
cd server/eval/benchmarks
./run_diarization.sh              # all 16 meetings
./run_diarization.sh ES2004a      # single meeting
```

**AliMeeting:**

```bash
# Prerequisites
pip install spy-der

# Prepare data: extract mono WAVs to server/eval/datasets/Eval_Ali/mono/
# Place reference RTTMs in server/eval/datasets/Eval_Ali/rttm/

cd server/eval/benchmarks
./run_alimeeting_diarization.sh
```

### Test Conditions

- Mode: offline (full-file processing, not streaming)
- DER collar: 0.25s (standard forgiveness window at segment boundaries)
- AMI: ignoreOverlap=True (FluidAudio built-in benchmark default)
- AliMeeting: spyder default settings (collar=0.25s, evaluates all regions including overlap)

### Results (2026-03-18)

**AMI Test Set (16 meetings, English)**

| Meeting  | DER %  | JER %  | Miss % | FA %  | SE %   | Spk (det/gt) | RTFx  |
|----------|--------|--------|--------|-------|--------|---------------|-------|
| IS1009c  | 7.7    | 39.9   | 2.7    | 2.0   | 3.0    | 6/4           | 132.6 |
| IS1009b  | 7.7    | 27.2   | 2.3    | 1.6   | 3.8    | 5/4           | 130.9 |
| TS3003b  | 9.9    | 28.7   | 3.5    | 3.8   | 2.6    | 5/4           | 130.6 |
| ES2004b  | 10.4   | 42.1   | 2.5    | 2.6   | 5.3    | 6/4           | 131.1 |
| ES2004c  | 11.0   | 32.3   | 2.0    | 3.4   | 5.6    | 5/4           | 130.8 |
| TS3003c  | 11.6   | 31.1   | 5.9    | 2.0   | 3.7    | 5/4           | 129.4 |
| IS1009d  | 12.3   | 33.7   | 3.2    | 2.8   | 6.3    | 5/4           | 131.6 |
| EN2002c  | 13.9   | 40.2   | 4.8    | 0.9   | 8.3    | 4/3           | 126.8 |
| ES2004a  | 14.5   | 37.2   | 7.6    | 1.7   | 5.2    | 5/4           | 135.3 |
| IS1009a  | 17.7   | 55.1   | 3.6    | 3.0   | 11.1   | 6/4           | 135.1 |
| TS3003a  | 21.2   | 78.2   | 11.7   | 1.4   | 8.1    | 2/4           | 133.8 |
| EN2002b  | 24.0   | 47.7   | 3.3    | 2.2   | 18.5   | 4/4           | 126.9 |
| EN2002d  | 25.4   | 46.9   | 3.8    | 2.0   | 19.7   | 4/4           | 131.6 |
| TS3003d  | 41.2   | 72.7   | 9.5    | 2.4   | 29.4   | 3/4           | 127.6 |
| ES2004d  | 69.4   | 91.3   | 4.2    | 2.8   | 62.4   | 2/4           | 129.2 |
| EN2002a  | 72.6   | 88.4   | 13.5   | 0.0   | 59.1   | 4/4           | 131.1 |
| **Average** | **23.2** | **49.5** |   |       |        |               | **130.9** |

DER range: 7.7% - 72.6%. Worst cases (ES2004d, EN2002a) are dominated by speaker confusion error (>59%).

**AliMeeting Eval Far-field (8 meetings, Chinese)**

| Meeting     | Duration (s) | Miss % | FA %  | Conf. % | DER %  |
|-------------|-------------|--------|-------|---------|--------|
| R8009_M8020 | 1,869       | 8.4    | 2.7   | 4.9     | 16.1   |
| R8009_M8018 | 1,611       | 8.2    | 4.4   | 9.5     | 22.2   |
| R8009_M8019 | 1,908       | 11.8   | 3.0   | 30.1    | 44.9   |
| R8001_M8004 | 2,049       | 28.0   | 2.2   | 17.0    | 47.1   |
| R8003_M8001 | 2,266       | 17.8   | 3.9   | 29.6    | 51.2   |
| R8008_M8013 | 2,351       | 15.4   | 4.7   | 32.6    | 52.7   |
| R8007_M8010 | 3,252       | 44.1   | 0.6   | 19.6    | 64.3   |
| R8007_M8011 | 2,326       | 22.7   | 1.6   | 43.6    | 67.8   |
| **Overall** | **17,633**  | **21.6** | **2.7** | **24.1** | **48.5** |

Note: AliMeeting DER is evaluated on all regions (including overlap), which significantly inflates the number compared to AMI's ignoreOverlap=True convention. The >30% overlap ratio in AliMeeting is the primary contributor to high miss and confusion rates.

**Memory Usage (diarization offline):**

| Meeting (duration, speakers) | RSS    | Peak Memory |
|------------------------------|--------|-------------|
| R8001_M8004 (26min, 4spk)   | 437 MB | 750 MB      |
| R8009_M8018 (28min, 2spk)   | 457 MB | 728 MB      |
| R8008_M8013 (37min, 3spk)   | 495 MB | 756 MB      |
| ES2004b/AMI (39min, 4spk)   | 508 MB | 929 MB      |

Conclusion: 30-40 minute meetings use <1GB peak memory. 8GB devices are not constrained.

---

## 4. Layer C: L2 Polish Model

### What

Compare different L2 polish models on ASR post-processing: given raw SpeechAnalyzer output, does the model improve or degrade the text relative to a ground-truth reference? Metrics: Fix% (improved samples), Break% (degraded samples), average CER, and latency.

### Script

```
server/eval/scripts/eval_l2_model.py
```

Supports both `ollama` and OpenAI-compatible API backends. Can evaluate single or multiple models side-by-side.

### How to Run

```bash
# Against user corrections (highest-quality ground truth)
python3 server/eval/scripts/eval_l2_model.py \
    --test-data ~/.we/corrections.jsonl \
    --test-type corrections \
    --endpoint http://100.64.0.3:11434 \
    --api ollama \
    --model qwen3.5:4b \
    --output results/eval_l2_qwen3.5_4b.json

# Against voice-history (polishedText as reference)
python3 server/eval/scripts/eval_l2_model.py \
    --test-data ~/.we/voice-history.jsonl \
    --test-type voice-history \
    --endpoint http://127.0.0.1:8045 \
    --api openai \
    --model gemini-3-flash \
    --output results/eval_l2_gemini3flash.json

# Compare multiple models
python3 server/eval/scripts/eval_l2_model.py \
    --test-data ~/.we/corrections.jsonl \
    --test-type corrections \
    --endpoint http://100.64.0.3:11434 \
    --api ollama \
    --models qwen3:0.6b,qwen3.5:0.8b,qwen3.5:4b
```

### Results (2026-03-19)

**Test set: corrections.jsonl (37 samples, human-corrected ground truth)**

| Model           | N  | CER Raw % | CER Polished % | Delta CER | Fix %  | Break % | Latency |
|-----------------|----|-----------|----------------|-----------|--------|---------|---------|
| qwen3.5:4b      | 37 | 153.5     | 83.7           | +69.8     | 100.0  | 0.0     | 1.12s   |
| gemini-3-flash   | 37 | 153.5     | 81.2           | +72.3     | 78.4   | 18.9    | 2.29s   |

**Test set: voice-history.jsonl (104 samples, polishedText as reference)**

| Model           | N   | CER Raw % | CER Polished % | Delta CER | Fix %  | Break % | Latency |
|-----------------|-----|-----------|----------------|-----------|--------|---------|---------|
| qwen3.5:4b      | 104 | 71.4      | 11.6           | +59.8     | 85.6   | 6.7     | 3.03s   |
| gemini-3-flash   | 104 | 71.1      | 208.4          | -137.3    | 57.7   | 26.0    | 6.20s   |

Notes:
- Delta CER > 0 means the model improved CER (higher is better).
- Fix% = proportion of samples where polishing reduced CER. Break% = proportion where it increased CER.
- qwen3.5:4b achieves 100% fix rate on corrections with 0% break rate, and strong performance on voice-history.
- gemini-3-flash shows severe degradation on voice-history (CER polished 208% vs 71% raw), likely due to hallucination or over-editing on short informal utterances.

---

## 5. Layer D: Training Data Quality

### What

Use an LLM-as-Judge (strong model) to score each training pair in the merged dataset. This catches bad distillation outputs before they enter the fine-tuning pipeline.

### Script

```
server/eval/scripts/judge_data_quality.py
```

### Scoring Dimensions

| Dimension       | Range | Description |
|-----------------|-------|-------------|
| **correctness** | 0-1   | Did the output correctly fix ASR errors without introducing new ones? |
| **fidelity**    | 0-1   | Does the output preserve the original meaning without over-editing? |
| **naturalness** | 0-1   | Is the output natural, fluent written language with proper punctuation? |
| **suitable**    | bool  | Is this pair suitable for training? (false if output is worse than input, truncated, or identical despite errors) |

### How to Run

```bash
python3 server/eval/scripts/judge_data_quality.py \
    --data /path/to/merged-pairs.jsonl \
    --endpoint http://127.0.0.1:8045 \
    --api-key sk-xxx \
    --model gpt-4o \
    --output results/data_quality_full.json
```

### Results (2026-03-19)

Judge model: gemini-3.1-pro. Dataset: 122 merged training pairs.

**Overall:**

| Metric          | Value       |
|-----------------|-------------|
| Total pairs     | 122         |
| Suitable        | 30 (24.6%)  |
| Unsuitable      | 92 (75.4%)  |
| Conflicts       | 44 (36.1%)  |
| Avg Correctness | 0.423       |
| Avg Fidelity    | 0.549       |
| Avg Naturalness | 0.532       |

**By Source:**

| Source   | N  | Suitable | Correctness | Fidelity | Naturalness |
|----------|----|----------|-------------|----------|-------------|
| human    | 37 | 1 / 37   | 0.172       | 0.188    | 0.331       |
| whisper  | 48 | 7 / 48   | 0.430       | 0.580    | 0.532       |
| gemini   | 37 | 22 / 37  | 0.664       | 0.869    | 0.731       |

Key finding: Gemini-distilled pairs have the highest quality (59% suitable). Human corrections scored lowest, likely because the judge model evaluates against different quality expectations than user-intended corrections. Whisper-distilled pairs sit in the middle. The high unsuitable rate (75.4% overall) indicates significant data cleaning is needed before fine-tuning.

---

## 6. Results Summary

### Transcription (Layer A)

| Condition                 | Overall CER % | Notes |
|---------------------------|---------------|-------|
| Far-field (AliMeeting ch0) | 40.0         | 8ch array single channel, no beamforming, >30% overlap |
| Near-field (headset mic)   | 34.0 (~25% excl. outlier) | Per-speaker headset, single speaker audio |

### Diarization (Layer B)

| Dataset         | DER %  | Condition | RTFx  |
|-----------------|--------|-----------|-------|
| AMI test set    | 23.2   | collar=0.25s, ignoreOverlap=True | 130.9 |
| AliMeeting Eval | 48.5   | collar=0.25s, all regions (incl. overlap) | ~131 |

### L2 Polish Model (Layer C)

| Model         | Test Set     | CER Raw % | CER Polished % | Fix % | Break % | Latency |
|---------------|-------------|-----------|----------------|-------|---------|---------|
| qwen3.5:4b    | corrections  | 153.5     | 83.7           | 100.0 | 0.0     | 1.12s   |
| qwen3.5:4b    | voice-history | 71.4     | 11.6           | 85.6  | 6.7     | 3.03s   |
| gemini-3-flash | corrections  | 153.5     | 81.2           | 78.4  | 18.9    | 2.29s   |
| gemini-3-flash | voice-history | 71.1     | 208.4          | 57.7  | 26.0    | 6.20s   |

### Training Data Quality (Layer D)

| Source  | N  | Suitable % | Avg Correctness | Avg Fidelity | Avg Naturalness |
|---------|----|-----------:|-----------------|--------------|-----------------|
| gemini  | 37 | 59.5       | 0.664           | 0.869        | 0.731           |
| whisper | 48 | 14.6       | 0.430           | 0.580        | 0.532           |
| human   | 37 | 2.7        | 0.172           | 0.188        | 0.331           |

### Performance

| Metric               | Value        |
|----------------------|--------------|
| Diarization RTFx     | ~131x        |
| Diarization Peak Mem | 728-929 MB   |
| Transcription RTFx   | 107-147x     |
| L2 Latency (qwen3.5:4b, ollama) | 1-3s |

---

## 7. Prerequisites

### System

- macOS 26 (Tahoe) with Apple Silicon
- Swift 6.2 toolchain (for building transcription-bench and FluidAudio CLI)
- Python 3.10+

### Python Packages

```bash
pip install jiwer       # CER/WER computation (Layer A)
pip install spy-der     # DER computation (Layer B, AliMeeting)
```

### Tools

| Tool | Purpose | Installation |
|------|---------|-------------|
| `transcription-bench` | SpeechAnalyzer file-input CLI | `cd server/eval/transcription-bench && swift build -c release` |
| `fluidaudiocli` | Speaker diarization CLI | `cd /tmp && git clone --depth 1 https://github.com/FluidInference/FluidAudio.git && cd FluidAudio && swift build -c release` |
| ollama | L2 model serving (local/remote) | [ollama.com](https://ollama.com) |

### Datasets

| Dataset | Size | Download |
|---------|------|----------|
| AMI 1.6.2 | ~5 GB (test set headset-mix) | Auto-downloaded by `fluidaudiocli --auto-download` |
| AliMeeting Eval | ~10 GB (eval subset) | [OpenSLR 119](https://www.openslr.org/119/) |

### Data Preparation (AliMeeting)

AliMeeting audio needs preprocessing before evaluation:

1. Extract mono channel from 8-channel array WAVs (use `server/eval/scripts/extract_mono.py`)
2. Convert TextGrid annotations to RTTM (use `server/eval/scripts/textgrid_to_rttm.py`)
3. Convert TextGrid annotations to reference text (use `server/eval/scripts/textgrid_to_ref.py`)
4. Place outputs in `server/eval/datasets/Eval_Ali/mono/` and `server/eval/datasets/Eval_Ali/rttm/`
