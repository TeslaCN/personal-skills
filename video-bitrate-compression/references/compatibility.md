# 兼容性：profile / level / tag / 容器

"压缩后到处能播"主要靠这几项，跟码率无关。

## 编码与 profile

| 场景 | 推荐 |
|---|---|
| 最大兼容（默认） | **H.264 High** + AAC LC |
| 体积紧张但设备较新 | **HEVC Main**（8bit） |
| 老旧设备 / 老 Windows / 网页 | 只选 H.264 |

- H.264 level 按分辨率：1080p → 4.1；4K（≤4096 宽）→ 5.1。让 x264 自动选也行，但显式指定更稳。
- **HEVC 必须 `-tag:v hvc1`**。默认的 `hev1` 在 Apple 生态/QuickTime 里打不开。
- 不要输出 10bit（`yuv420p10le`）或 4:2:2——很多硬解直接不支持。统一 `-pix_fmt yuv420p`。

## 容器

- MP4 + `-movflags +faststart`：moov 前置，网页/IM 里能边下边播。
- 需要多音轨/字幕再考虑 MKV；日常分享一律 MP4。

## 音频

- AAC LC，44.1k 或 48k，立体声；128k 足够，纯人声 64k。
- 源轨道已经是 AAC 且参数正常 → `-c:a copy`，不重编码、不产生代际损失。
- 源是 AC3/DTS/Opus → 必须转 AAC，否则一半设备没声音。
- 完全静音的素材也建议保留一条 AAC，个别播放器对"无音轨"的 MP4 处理异常。

## 色彩

重编码时如果源带 BT.709 标记，输出要显式带上：

```bash
-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv
```

漏掉标记时，播放器可能按 BT.601 解释，出现偏色/发灰。用 `ffprobe` 查源的 `color_space / color_transfer / color_primaries`，有就照抄。

## 帧率

- 源是真 CFR → `-fps_mode passthrough`，原样保留时间戳。
- 源是 VFR 且目标播放器挑剔 → 才转 CFR（`-fps_mode cfr -r N`）。注意转换会产生 dup/drop，长时间视频可能累积音画偏移。
- 不要为了省码率随意降帧率，运动观感损失比体积收益更明显。

## 常见"播不了"排查顺序

1. `ffprobe` 看 `pix_fmt` 是不是 `yuv420p`；
2. HEVC 看 `codec_tag_string` 是不是 `hvc1`；
3. 看是否是 10bit / 4:2:2；
4. 看音轨是不是 AC3/DTS；
5. 换 VLC 播放 → 能放说明是设备解码能力问题，不是文件损坏。

## 元数据 / flag 不退化（重编码最容易被忽略的坑）

"兼容性不比原片差"不等于编码相同，而是要保证**输出没有引入原片没有的额外要求**。逐项对照：

| 项 | 源里有 | 输出应该 | 退化的后果 |
|---|---|---|---|
| `codec_tag_string` | `hvc1` | 保持 `hvc1` | 变成 `hev1` → Apple/QuickTime 打不开 |
| `profile` / `level` | Main / 5.0 | 不高于源 | level 变 6.0 → 部分硬解拒播 |
| `pix_fmt` | `yuv420p` | 8bit 4:2:0 | 变 10bit/4:2:2 → 老设备黑屏 |
| `color_primaries/transfer/space/range` | bt709 / tv | 原样标注 | 丢失 → 按 BT.601 解释，偏色发灰 |
| `sample_aspect_ratio` | 1:1 | 1:1 | 变非方形像素 → 画面被拉扁 |
| `rotation`（side data） | 有角度 | 保留或烧进画面 | 丢失 → 竖拍视频躺倒 |
| `field_order` | progressive | progressive | 变 interlaced → 拉丝 |
| 音频编码 | AAC LC | AAC LC | 变 AC3/DTS → 一半设备没声音 |

### 对照命令

```bash
# 逐字段对比源与输出
for k in codec_name profile level codec_tag_string pix_fmt color_space color_transfer color_primaries color_range sample_aspect_ratio; do
  a=$(ffprobe -v error -select_streams v:0 -show_entries stream=$k -of csv=p=0 src.mp4 | head -1)
  b=$(ffprobe -v error -select_streams v:0 -show_entries stream=$k -of csv=p=0 out.mp4 | head -1)
  printf '%-22s 源=%-10s 输出=%-10s %s\n' "$k" "$a" "$b" "$([ "$a" = "$b" ] || echo '⚠')"
done
```

`scripts/verify.sh out.mp4 --against src.mp4` 会自动做这件事。

### 一个反例

源片是 8bit H.264 的 1080p，手机相册播放正常。重编码时如果不写 `-pix_fmt yuv420p`，滤镜链可能输出 `yuv444p` 或 10bit——文件在电脑上能放，手机相册直接黑屏。这类问题**只看文件大小和 ffprobe 是否成功是发现不了的**，必须看 `pix_fmt` 和 tag。
