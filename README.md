# personal-skills

个人 Agent Skills 集合。每个子目录是一个独立 skill，入口都是 `SKILL.md`（YAML frontmatter + 正文），可附带 `references/`（详细文档）和 `scripts/`（可执行工具）。

## 包含的 skill

| Skill | 用途 |
|---|---|
| [`dashcam-video-stitching`](dashcam-video-stitching/SKILL.md) | 行车记录仪多视角视频无损拼接：ffmpeg 排版、体积预算、关键时段保车牌清晰、播放兼容性处理 |

## 使用方式

把需要的 skill 目录放到 Agent 的 skills 目录下，例如：

```bash
git clone <仓库地址> personal-skills
ln -s "$PWD/personal-skills/dashcam-video-stitching" ~/.agents/skills/dashcam-video-stitching
```

或者只拷贝单个目录。skill 之间互不依赖。

## 约定

- 每个 skill 只依赖系统里已有的命令行工具，依赖写在 frontmatter 的 `metadata.requires.bins`。
- 脚本里不写死绝对路径，路径一律通过参数或环境变量传入。
- 素材、输出、临时文件都在调用方指定的目录里，不污染 skill 目录。
