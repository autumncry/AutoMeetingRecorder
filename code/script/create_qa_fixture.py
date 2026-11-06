#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Create clearly labeled synthetic fixtures only in the project's Validation directory."""
from pathlib import Path
import json, math, struct, wave, uuid

root = Path(__file__).resolve().parents[2]
validation = root / "Validation"
fixtures = validation / "fixtures"
fixtures.mkdir(parents=True, exist_ok=True)
audio = fixtures / "synthetic-tone.wav"
with wave.open(str(audio), "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(16000)
    output.writeframes(b"".join(struct.pack("<h", int(0.12 * 32767 * math.sin(i * 440 * 2 * math.pi / 16000))) for i in range(32000)))
directory = validation / "Library" / "qa-synthetic-fixture"
directory.mkdir(parents=True, exist_ok=True)
(directory / "original.wav").write_bytes(audio.read_bytes())
version_id = "A39E9C49-632D-4769-87D4-CC2AB1B75191"
segments = [{"id": str(uuid.uuid4()), "start": 0, "end": 1, "text": "这是一段界面验收用的合成数据，不来自真实会议。", "speaker": "测试标记"}, {"id": str(uuid.uuid4()), "start": 1, "end": 2, "text": "English terms、Markdown 和时间跳转应正常显示。", "speaker": "测试标记"}]
transcript = {"text": "\n".join(s["text"] for s in segments), "segments": segments}
(directory / "transcript.qa.json").write_text(json.dumps(transcript, ensure_ascii=False), encoding="utf-8")
(directory / "transcript.qa.md").write_text("# 合成验收转写\n\n" + transcript["text"], encoding="utf-8")
(directory / "transcript.md").write_bytes((directory / "transcript.qa.md").read_bytes())
(directory / "summary.md").write_text("# 合成数据验收\n\n这是 **界面测试样本**，并非模型生成的真实会议纪要。\n\n## 验收项目\n\n- 中文与 English 混合阅读\n- Markdown 标题和列表\n- 两秒合成音频播放\n\n## 待办\n\n- [ ] 配置自己的内网 ASR\n- [ ] 授权后进行飞书实会验收\n", encoding="utf-8")
session = {"id": "5FC14789-2AF6-473D-83A3-9C81C97325F3", "createdAt": "2026-11-06T08:00:00Z", "title": "合成音频验收 · 非真实会议", "source": "界面测试夹具", "directory": directory.name, "status": "completed", "duration": 2, "audioFile": "original.wav", "transcriptVersions": [{"id": version_id, "createdAt": "2026-11-06T08:00:00Z", "profileName": "测试夹具（非模型调用）", "model": "fixture", "markdownFile": "transcript.qa.md", "jsonFile": "transcript.qa.json"}], "selectedTranscriptID": version_id, "summaryFile": "summary.md", "summaryTranscriptID": version_id, "notes": ["合成测试资料；没有调用 ASR 或 LLM。"]}
(directory / "meeting.json").write_text(json.dumps(session, ensure_ascii=False, indent=2), encoding="utf-8")
print(audio)
print(directory)
