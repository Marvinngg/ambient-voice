#!/usr/bin/env python3
"""
生成微调训练数据
基于用户私有词典，为每个术语生成多种 SA 误识别变体 + 多个句子上下文
"""

import json
import random
import argparse

# === 纠错词典：SA误识别 → 正确词 ===
# 每个术语包含多种可能的误识别方式
CORRECTION_MAP = {
    # 工具/产品
    "Claude": ["克劳德", "Cloud", "cloude", "拗的"],
    "Claude Code": ["Cloudcode", "Cloud Code", "cloud con", "克劳德 code", "扣的扣的"],
    "Claude Agent SDK": ["Cloud Agent SDK", "克劳德 Agent SDK", "Cloud agent STK"],
    "Anthropic": ["安卓pick", "anthropik", "安斯若pick"],
    "Opus": ["欧帕斯", "open", "哦怕死"],
    "Sonnet": ["桑内特", "sones", "so net"],
    "Haiku": ["海酷", "hi cool", "嗨酷"],
    "MCP": ["ICP", "NCP", "没cp", "MC屁", "MTP"],
    "MCP Server": ["ICP server", "MCP service", "没cp server"],
    "Skill": ["skile", "skil", "scile", "死Q", "斯Q"],
    "Agent": ["agent", "阿真特", "a真特", "艾真特"],
    "Agent Teams": ["agent teams", "阿真特teams", "agent team"],
    "ollama": ["all llama", "哦拉马", "欧拉马", "o llama"],
    "Whisper": ["Whistle", "为死per", "whistle"],
    "Gemini": ["Gmm", "杰米尼", "gemmy", "杰迷你"],
    "Gemini Flash": ["Gemini flash", "杰米尼 flash", "Gmm flash"],
    "Qwen": ["queen", "Q问", "全", "去问"],
    "Tailscale": ["tail scale", "太尔scale", "尾巴scale"],
    "Headscale": ["head scale", "黑的scale"],
    "Ghostty": ["Gostay", "Goston", "ghost体", "go stay"],
    "Docker": ["多克", "docker", "到克"],
    "CUDA": ["酷达", "cool达", "库达"],
    "GitHub": ["get hub", "给他hub", "git hub"],
    "Xcode": ["X code", "叉code"],
    "SwiftUI": ["swift UI", "思维付UI"],
    "CoreML": ["core ML", "核ML", "口ML"],
    "Bash": ["bach", "巴士", "八十"],

    # 李继刚 Skill
    "ljg-rank": ["LJG rank", "LJG-rank", "力继刚rank", "降秩"],
    "ljg-word": ["LJG word", "力继刚word"],
    "ljg-card": ["LJG card", "力继刚card"],
    "ljg-invest": ["LJG invest", "力继刚invest"],
    "ljg-paper": ["LJG paper", "力继刚paper"],
    "ljg-learn": ["LJG learn", "力继刚learn"],
    "ljg-travel": ["LJG travel", "力继刚travel"],
    "ljg-plain": ["LJG plain", "力继刚plain"],
    "降秩": ["将持", "降至", "降值", "讲吃"],
    "秩": ["值", "至", "质"],
    "生成器": ["生成期", "声称器"],

    # Agent 概念
    "Meta-Agent": ["meta agent", "没他agent", "meta 阿真特"],
    "认知内核": ["认识内核", "认之内核"],
    "进化协议": ["进化写意", "进化鞋议"],
    "能力接口": ["能力节口", "能力借口"],
    "Orchestrator": ["or开strator", "奥克斯traitor"],
    "Domain Agent": ["domain agent", "domain 阿真特"],

    # AI/ML 概念
    "蒸馏": ["针馏", "蒸流", "真流", "针流"],
    "微调": ["为调", "未调", "威调"],
    "推理": ["退理", "推力", "堆理"],
    "训练": ["寻练", "训炼"],
    "LoRA": ["Laura", "劳拉", "lora", "罗拉"],
    "QLoRA": ["Q Laura", "Q 劳拉", "q lora", "Q罗拉"],
    "GGUF": ["GGF", "GGOF", "GG UF"],
    "Fine-tune": ["fine tune", "fine-tune", "fine2"],
    "System Prompt": ["sistam prom", "system prompt", "系统 prompt", "系统提示词"],
    "Token": ["投肯", "头肯"],
    "Embedding": ["in bedding", "嵌入"],
    "API": ["AP1", "a pi", "API"],
    "SDK": ["SDP", "STK", "SD开"],
    "CLI": ["COI", "CRI", "C离"],
    "SSH": ["SSA", "SS8"],

    # 项目专有
    "ambient-voice": ["ambient voice", "环境voice"],
    "voice-history": ["voice history", "voice 历史"],
    "contextualStrings": ["contextual strings", "上下文strings"],
    "SpeechAnalyzer": ["speech analyzer", "语音analyzer"],
    "TextInjector": ["text injector", "text注入"],
    "Building in Public": ["building public", "building in public"],
    "数据飞轮": ["数据非轮", "数据废轮", "数据飞论"],

    # 中文高频易错
    "纠错": ["交错", "纠措", "就错"],
    "转录": ["转路", "转入", "砖路"],
    "部署": ["不署", "布署", "步署"],
    "同步": ["筒步", "桶步", "通步"],
    "执行": ["自行", "只行", "植行"],
    "架构": ["价格", "价够", "驾构"],
    "评估": ["拼估", "凭估"],
    "舆情": ["鱼情", "于情", "鱼除"],
    "一致": ["理智", "一至", "一质"],
}

# === 句子模板 ===
# {term} 会被替换成术语（正确或错误版本）
SENTENCE_TEMPLATES = [
    # 开发/架构
    "我们用{term}来做这个功能",
    "这个{term}的配置需要调整一下",
    "{term}这个方案你觉得怎么样",
    "帮我看看{term}是不是有问题",
    "我想了解一下{term}的具体实现",
    "把{term}的部分重新设计一下吧",
    "目前{term}已经跑通了",
    "{term}的效果还不错",
    "先测试一下{term}能不能正常工作",
    "你用过{term}吗怎么样",
    "我们接下来要做的是{term}",
    "这个{term}的文档有没有",
    "我觉得{term}这个思路是对的",
    "{term}那边有什么进展吗",
    "关于{term}我有几个问题想问",

    # 技术讨论
    "具体到{term}这块怎么做",
    "我们的{term}方案需要优化",
    "{term}的性能表现怎么样",
    "从{term}的角度来看",
    "然后就是{term}的问题",
    "核心是用{term}去实现",
    "看看{term}有没有更好的替代方案",
    "这个跟{term}有什么关系",
    "我在研究{term}的最佳实践",
    "{term}是我们这个项目的关键",
]


def generate_training_pairs(
    correction_map: dict,
    templates: list[str],
    pairs_per_term: int = 5,
    seed: int = 42
) -> list[dict]:
    """为每个纠错词生成多条训练对"""
    random.seed(seed)
    pairs = []

    for correct_term, wrong_variants in correction_map.items():
        # 为每个错误变体生成句子
        selected_templates = random.sample(
            templates, min(pairs_per_term * len(wrong_variants), len(templates))
        )

        template_idx = 0
        for wrong in wrong_variants:
            # 每个错误变体生成 pairs_per_term 条
            for _ in range(min(pairs_per_term, len(templates) - template_idx)):
                if template_idx >= len(selected_templates):
                    break
                tmpl = selected_templates[template_idx]
                template_idx += 1

                input_text = tmpl.format(term=wrong)
                output_text = tmpl.format(term=correct_term)

                # 只保留有实际改动的
                if input_text != output_text:
                    pairs.append({
                        "input": input_text,
                        "output": output_text,
                        "source": "synthetic",
                        "correct_term": correct_term,
                        "wrong_variant": wrong
                    })

    random.shuffle(pairs)
    return pairs


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic training data")
    parser.add_argument("--output", default="training_data.jsonl", help="Output JSONL path")
    parser.add_argument("--pairs-per-term", type=int, default=3, help="Pairs per error variant")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--stats", action="store_true", help="Print statistics")
    args = parser.parse_args()

    pairs = generate_training_pairs(CORRECTION_MAP, SENTENCE_TEMPLATES, args.pairs_per_term, args.seed)

    with open(args.output, "w") as f:
        for p in pairs:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")

    print(f"Generated {len(pairs)} training pairs → {args.output}")
    print(f"Unique correct terms: {len(CORRECTION_MAP)}")
    print(f"Total error variants: {sum(len(v) for v in CORRECTION_MAP.values())}")

    if args.stats:
        from collections import Counter
        terms = Counter(p["correct_term"] for p in pairs)
        print(f"\nTop 10 terms by pair count:")
        for term, count in terms.most_common(10):
            print(f"  {term}: {count}")


if __name__ == "__main__":
    main()
