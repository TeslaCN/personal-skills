# 质量校验

压缩完必须验，不能只看"文件变小了"。

## 1. 结构校验

```bash
scripts/verify.sh out.mp4 --max-bytes 70MB --expect-duration 61.6
```

或手工：

```bash
ffprobe -v error -show_entries \
  format=duration,size,bit_rate:stream=codec_name,profile,width,height,pix_fmt,\
r_frame_rate,avg_frame_rate,codec_tag_string,sample_rate,channels \
  -of default=nw=1 out.mp4
```

关注：分辨率是否与源一致、`pix_fmt=yuv420p`、HEVC 是否 `hvc1`、有没有音轨、帧率是否合理。

## 2. 整片解码

```bash
ffmpeg -v error -xerror -i out.mp4 -f null -
```

`-xerror` 让 ffmpeg 遇到第一个错误就退出。没有输出=没有错误。这一步能抓出编码中断、时间戳错乱、参考帧缺失。

## 3. 1:1 目视（最关键）

```bash
# 抽帧
ffmpeg -v error -ss 10 -i out.mp4 -frames:v 1 -q:v 2 /tmp/f10.jpg

# 按原始像素裁关键区域，再放大看
ffmpeg -v error -ss 10 -i out.mp4 -frames:v 1 \
  -vf "crop=800:450:2400:1000,scale=1200:675:flags=neighbor" /tmp/crop.png
```

**一定要用最近邻放大（`flags=neighbor`）**，双线性会让图像自己变糊，掩盖压缩瑕疵。

看什么：
- 文字/车牌边缘是否还完整（最关键）；
- 暗部有没有块状/色带；
- 平坦区域（天空、墙面）有没有 8×8 块效应；
- 快速运动处有没有拖影。

同一位置从源片也裁一份，并排对比最直观。

## 4. 客观指标（可选）

```bash
ffmpeg -t 10 -i out.mp4 -t 10 -i src.mp4 -lavfi "[0:v][1:v]ssim" -f null -
ffmpeg -t 10 -i out.mp4 -t 10 -i src.mp4 -lavfi "[0:v][1:v]psnr" -f null -
```

**SSIM 的陷阱**：低码率版本通常会把传感器噪声抹掉，而 SSIM 会把"噪声没了"判为误差，分数明显下降——但主观上画面更干净。所以：

- SSIM 只用来横向比较同一种处理方式的两个版本（比如两个码率），不要用来判定"能不能交付"；
- 判定交付以 1:1 目视 + 关键目标可读性为准。

有 VMAF 的话优先 VMAF（更贴近主观），但 4K 全片计算很慢，抽 10–20 秒足够。

## 5. 播放与设备

- 手机相册能播放、能拖动进度条（faststart 生效）；
- 电脑上用 VLC 再放一遍；
- 如果要发微信/上传平台，先发给自己试一次。

## 交付前清单

- [ ] 体积 ≤ 目标
- [ ] 分辨率与源一致（或按约定缩放）
- [ ] `pix_fmt=yuv420p`，HEVC 带 `hvc1`
- [ ] 全片解码无错误
- [ ] 关键区域 1:1 目视通过
- [ ] 时长与源一致（±0.2s）
- [ ] 有音轨且音画同步（若源有音轨）
