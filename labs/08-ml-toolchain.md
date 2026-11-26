# 08 · ML 演示工具链（vec2text / embedding-inversion-demo）

> **所属**：`labs/` 实验环境部署 · **前置**：通用环境准备（Python / HF 镜像源）见 `00-prerequisites.md`
> **适用**：Ubuntu 20.04 / 22.04 / 24.04（x86_64）· Python 3.10+ · torch CPU 版

- **来源**：`vec2text-master.zip`、`embedding-inversion-demo-main.zip`
- **形态**：Python 库 / 研究代码（本地推理为主，不依赖云 API）
- **依赖**：Python 3.10+；torch（CPU 版即可）

## 1. 虚拟环境与 PyTorch（CPU）

```bash
python3 -m venv "$LAB_ROOT/venvs/ml"

# 先装 CPU 版 torch，避免默认 wheel 拉入整套 CUDA 依赖
"$LAB_ROOT/venvs/ml/bin/pip" install torch --index-url https://download.pytorch.org/whl/cpu

# 项目依赖（pip 走清华大学镜像源）
"$LAB_ROOT/venvs/ml/bin/pip" config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
"$LAB_ROOT/venvs/ml/bin/pip" install -r "$LAB_ROOT/src/vec2text-master/requirements.txt"
"$LAB_ROOT/venvs/ml/bin/pip" install -r "$LAB_ROOT/src/embedding-inversion-demo-main/requirements.txt"
```

> 老 CPU（无 AVX2，例如 Xeon X56xx）实测可安装并运行 torch 2.x，无需特殊处理。

## 2. vec2text

已知小坑：仓库 `vec2text/experiments.py` 缺少顶层 `import platform`，导入会报
`NameError: name 'platform' is not defined`。在构建副本中修复（保持 `src/` 上游源码零改动）：

```bash
[ -d "$LAB_ROOT/build/vec2text" ] || cp -a "$LAB_ROOT/src/vec2text-master" "$LAB_ROOT/build/vec2text"
grep -q '^import platform' "$LAB_ROOT/build/vec2text/vec2text/experiments.py" \
  || sed -i '1i import platform' "$LAB_ROOT/build/vec2text/vec2text/experiments.py"
cd "$LAB_ROOT/build/vec2text" && "$LAB_ROOT/venvs/ml/bin/python" -c "import vec2text; print('VEC2TEXT_OK')"
```

使用：按 README 示例从 `$LAB_ROOT/build/vec2text` 根目录运行脚本（模型经 HuggingFace 下载，见 §4）。

## 3. embedding-inversion-demo

研究性质代码（论文复现）：包含训练/评估脚本与 Web demo。
**仓库不含训练好的 checkpoint 与全部数据**，完整复现需自备：

1. 训练数据与 embedding 对；
2. 按 `configs/*.yaml` 指明的编码器训练 inversion 模型；
3. 启动 `demo_server.py`（默认 `0.0.0.0:8080`）。

快速自检（不训练）：

```bash
"$LAB_ROOT/venvs/ml/bin/python" -c \
  "import transformers, torch, yaml; print('DEPS_OK', torch.__version__, transformers.__version__)"
```

## 4. HuggingFace 镜像

```bash
export HF_ENDPOINT=https://hf-mirror.com     # 写入 ~/.bashrc 或启动脚本
```

直连 `huggingface.co` 失败不是模型不存在，先换端点再排查。

## 5. 资源预期

| 组件 | 建议资源 | 说明 |
|---|---|---|
| vec2text 推理 | 8 GB RAM / 20 GB 磁盘 | 依模型大小而异 |
| embedding-inversion 训练 | GPU 或大内存 CPU | README 宣称 A100 级训练 |

## 6. 注意事项

- 先装 CPU 版 torch 再装项目依赖，避免默认 wheel 拉入整套 CUDA 依赖（§1）。
- `embedding-inversion-demo` 不含训练好的 checkpoint 与全部数据，完整复现需自备（§3）。
- HuggingFace 直连失败先换 `HF_ENDPOINT=https://hf-mirror.com` 再排查模型是否存在（§4）。
- vec2text 的 `import platform` 补丁属上游缺陷，只在构建副本中处理（§2）。
