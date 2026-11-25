---
name: video-bitrate-compression
version: 1.0.0
description: "视频码率压缩（ffmpeg）：在体积上限内把视频压小，同时保持分辨率与播放兼容性。当用户提出「压到 X MB 以内」「保持分辨率/清晰度压小」「能到处播放的兼容格式」「两遍编码」「码率/CRF 怎么选」时使用。不涉及多路拼接。"
metadata:
  requires:
    bins: ["ffmpeg", "ffprobe"]
---

# 视频码率压缩

目标通常是三个约束同时成立：**体积 ≤ 上限**、**分辨率不变**、**到处能播**。三者会互相挤占，先把账算清楚再编码，比反复试压快得多。

## 快速开始

```bash
scripts/inspect.sh in.mp4                          # 1. 量素材 + 给建议
scripts/compress.sh -i in.mp4 -o out.mp4 --target 70MB      # 2. 硬上限，两遍编码
scripts/compress.sh -i in.mp4 -o out.mp4 --crf 22                # 3. 质量优先（编码默认跟源一致）
scripts/verify.sh out.mp4 --max-bytes 70MB         # 4. 校验
```

## 方法：四步

### 1. 先量，不要猜

```bash
ffprobe -v error -show_entries \
  format=duration,size,bit_rate:stream=codec_name,profile,width,height,pix_fmt,\
r_frame_rate,avg_frame_rate,bit_rate,sample_rate,channels,color_space,color_transfer \
  -of default=nw=1 in.mp4
```

必须确认：分辨率、**真实帧率**（`nb_frames / duration` 比 `r_frame_rate` 可靠）、时长、编码、像素格式（10bit 要转 8bit）、音轨、色彩标记。

### 2. 算预算

```
视频码率(bps) = (目标字节数 × 8 × 0.92) / 时长秒 − 音频码率
```

- 用户说的 MB 按**十进制**理解（70MB = 70,000,000 字节），留 8% 余量给封装和编码器超采样。
- 音频：AAC 128k 足够；纯人声 64k；原轨已是 AAC 且兼容就直接 `-c:a copy`（省时且无损）。
- 例：70MB / 105s → 总 5.3 Mbps → 视频约 5.2 Mbps。

### 3. 判断可行性：每像素码率（bpp）

```
bpp = 视频码率 / (宽 × 高 × 帧率)
```

这是唯一能跨分辨率比较"够不够"的指标。经验区间（H.264）：

| bpp | 观感 |
|---|---|
| < 0.01 | 明显糊，小字/车牌会丢 |
| 0.02–0.035 | 手机上看没问题，放大能看出软 |
| 0.05–0.08 | 质量不错，日常投影也够 |
| > 0.10 | 接近透明（看不出重编码痕迹） |

**HEVC 在同等观感下大约只要 H.264 的 55–70%**。

**默认策略：保持与源相同的编码家族。** 源是 HEVC 就出 HEVC、源是 H.264 就出 H.264——源片能播的设备，输出也能播，兼容性一定不比原片差，而且不用重新评估设备能力。只有明确要"给老旧设备/老 Windows/某些网页用"时，才改用 H.264（此时同码率观感会下降，或者需要更大体积）。

bpp 低于 0.02 时优先 HEVC（同体积质量更高）；预算宽松时两者差别不大，按"跟源一致"来选即可。

实测参考（可直接对数）：

| 素材 | 编码 | 码率 | bpp | 结论 |
|---|---|---|---|---|
| 3840×1696 30fps 行车记录 | HEVC | 21.4 Mbps | 0.109 | 源片，接近透明 |
| 同上 | HEVC | 8.7 Mbps | 0.044 | 几乎看不出差别 |
| 同上 | H.264 | 8.5 Mbps | 0.043 | 车牌清晰，暗部略平滑 |
| 3840×2696 30fps 夜景 | HEVC | 3.9 Mbps | 0.012 | 可看，细节软 |
| 同上 | HEVC | 11.6 Mbps | 0.036 | 车牌清晰可取证 |

**如果算出来的 bpp 低于 0.012，先别硬压**：确认用户是否接受降分辨率、降帧率、或轻度降噪，这些比死磕码率有效得多。

### 4. 编码

- **硬上限** → 两遍 ABR（`-b:v`，两遍），体积可预测。
- **质量优先、体积有区间** → 单遍 CRF（`-crf`），会按内容自动分配。
- **不要同时给 `-crf` 和 `-b:v`**，ABR 会覆盖 CRF，结果不可预测。
- 帧率：源是真 CFR 就 `-fps_mode passthrough`；源是 VFR 而播放端挑剔才转 CFR（`-fps_mode cfr -r N`），但要注意 dup/drop。

## 兼容性封装（"到处能播"）

兼容性 = **编码规格** + **容器/元数据 flag**。第二项最容易被忽略：重编码后 tag 从 `hvc1` 变 `hev1`、色彩标记丢失、旋转信息丢失，文件都能"正常生成"，但在某些设备上就是放不了或显示不对。**输出不应该比原片要求更高**（profile/level 不升、bit depth 不变、flag 不丢）。详见 `references/compatibility.md`。

| 项 | 建议 |
|---|---|
| 编码 | H.264 **High**，1080p 用 Level 4.1、4K 用 Level 5.1；需要更小体积再考虑 HEVC |
| 像素格式 | `-pix_fmt yuv420p`（10bit/422 很多设备直接不支持） |
| 尺寸 | 宽高必须是偶数 |
| 色彩 | 显式打标 `-color_primaries bt709 -color_trc bt709 -colorspace bt709`（缺标记时播放器可能按 BT.601 解释，偏色） |
| 容器 | MP4 + `-movflags +faststart`（moov 前置，网页/聊天软件能边下边播） |
| HEVC 专用 | `-tag:v hvc1`（Apple 生态必需，`hev1` 打不开） |
| 音频 | AAC LC；原轨兼容就 copy |
| 帧率 | 保持源帧率最保险；不要为了"变小"随意降帧 |

## 校验（必做）

```bash
scripts/verify.sh out.mp4 --max-bytes 70MB
```

1. `ffprobe` 核对：时长、分辨率、帧率、体积、音轨、`pix_fmt`。
2. 整片解码无错：`ffmpeg -v error -xerror -i out.mp4 -f null -`。
3. **1:1 裁切目视**：抽 2–3 帧，按原始像素裁出关键区域（车牌、人脸、文字），用最近邻放大 2–4 倍再看。缩小浏览会掩盖压缩痕迹。
4. 可选量化：`ffmpeg -i out.mp4 -i src.mp4 -lavfi ssim -f null -`。注意 SSIM 对"去噪"很敏感——低码率版本把噪点抹掉后 SSIM 会明显下降，但主观可能更干净，别只看数字。

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 体积超了 10%+ | 编码器实际码率高于请求 | 预算乘 0.9；或两遍编码后校验，超出就用 0.92× 码率重编一次 |
| 颜色发灰/偏色 | 没打色彩标记 | 用源片的 `color_primaries/transfer` 显式标注 |
| 苹果设备打不开 | HEVC 用了 `hev1` | `-tag:v hvc1` |
| 某些播放器黑屏 | 10bit / yuv422 | 统一 `yuv420p` |
| 音画不同步 | VFR 源强行转 CFR | `-fps_mode passthrough`，或先确认源是真 VFR |
| 压缩后车牌糊 | bpp 太低 | 提高码率、换 HEVC、或对关键片段单独提码率 |
| 转码后体积反而变大 | 源码率本来就低 | 先看 bpp；低于 0.05 再压收益很小，可能只剩重编码损失 |

## 相关文档

- `references/bitrate-budget.md` — 预算公式、bpp 表、编码器效率对比
- `references/compatibility.md` — profile/level/tag、容器、音频、色彩
- `references/quality-check.md` — 校验流程与主观/客观指标
