# 播放兼容性

拼接出来的画布常常"不是标准分辨率"，这是兼容性问题的主要来源。

## HEVC 层级与最大画面

MaxLumaPs（最大亮度采样数）决定了需要哪个 level：

| Level | 最大亮度像素数 | 典型对应 |
|---|---|---|
| 5.0 | 8,912,896 / 2 = 4,456,448 | 1080p60 |
| 5.1 | 8,912,896 | 4K30（3840×2160 = 8.29M） |
| 5.2 | 8,912,896 | 4K60 需另外的每帧率限制 |
| 6.0 | 35,651,584 | 8K / 超大画布 |

**判断方法**：`宽 × 高 > 8,912,896` 就至少要 level 6.0。

例：3840×2696 = 10,352,640 → level 6.0。这已经超出很多手机硬解的能力，即使编码器能输出，播放端也会拒播。

编码后看实际层级：

```bash
ffprobe -v error -show_entries stream=profile,level -of default=nw=1 out.mp4
# level=180 即 6.0（level = 30 × x.y）
```

## 设备上限经验值

- 中端 Android（骁龙 7 系、天玑 8000 级）：常见上限 4096×2304
- 旗舰 Android：8192×4320（可放行 6.0）
- iPhone / VideoToolbox：多数机型 4096×2304
- 桌面 VLC / mpv / 浏览器：软解或 NVDEC，基本不受限

**结论：画布高度 > 2304 就要准备兼容版。**

## 兼容版策略

同一个时间轴出两份：

| 版本 | 分辨率 | 用途 |
|---|---|---|
| 主交付 | 原始画布（如 3840×2696） | 存档、电脑上查看、放大取证 |
| 兼容版 | 高度 ≤2304，如 1920×1348 | 手机相册、微信转发 |

兼容版不要重新排版，直接把整张画布等比缩放（`scale=1920:-2:flags=lanczos`），保证两版画面内容完全一致、可直接对照。

## MP4 封装细节

- **`-tag:v hvc1`**：HEVC 在 Apple/QuickTime 里必须用 `hvc1`，`hev1` 会打不开。即使只在 Android 用，加上也无副作用。
- **`-movflags +faststart`**：把 moov 移到文件头。验证：

  ```bash
  ffprobe -v error -show_entries format=format_name out.mp4   # 只能看容器
  # 更直观：用 python 读 box 顺序，应为 ftyp, moov, ..., mdat
  ```

- **音轨**：没有音轨的 MP4 多数播放器能放，但部分分享渠道（微信、某些相册）会异常。原片是数字静音时也保留一条 AAC，代价 <1MB。
- **像素格式**：统一 `yuv420p`。`yuv420p10le` 在部分 Android 硬解上会退化到软解。

## 检查清单

```bash
ffprobe -v error -show_entries \
  stream=codec_name,profile,level,width,height,pix_fmt,codec_tag_string \
  -show_entries format=duration,size -of default=nw=1 out.mp4
```

- [ ] `codec_tag_string=hvc1`
- [ ] `pix_fmt=yuv420p`
- [ ] 宽高为偶数
- [ ] level 与目标设备的解码能力匹配
- [ ] 全片解码无报错：`ffmpeg -v error -i out.mp4 -f null -`
