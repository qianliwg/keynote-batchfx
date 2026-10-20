# keynote-batchfx

Keynote 动效工坊：面向 Apple Keynote 的沿线动画、路线绘制同步和视频动效辅助工具。

当前版本是 P2 原型，重点解决“图片或群组沿曲线运动时，手动对齐耗时且难以重复”的问题。

## 当前能力

- 读取 Keynote 文稿并检查对象、嵌套群组和媒体引用。
- 生成经过媒体完整性校验的 Keynote 副本，不覆盖已有文件。
- P1 动效项目文件（`.kmotion.json`）保存来源文稿指纹、贝塞尔路线、图片内部锚点、朝向、分段时间和播放模式。
- 运动预览支持进度拖动、播放/暂停、单次、循环、往返、路线同步绘制和沿切线旋转。
- P2 可以从当前幻灯片的根级曲线读取真实控制点，选择根级目标对象，并把原生 Keynote 沿线动画写入一个经过媒体校验的新副本。
- 原有 1.1 沿线动画脚本保留在本地工作目录中，P0 原生 Keynote 样例和验证报告保存在本项目的 `Fixtures/` 与 `Docs/`。

## 目录

```text
App/             macOS SwiftUI 应用
MotionCore/      路线、弧长采样、时间线和项目模型
KeynoteAdapter/  隔离运行的 Keynote 文稿适配器
ProjectFormat/   项目 JSON Schema 和示例
Packaging/       内置 Python 运行时和 macOS app 打包脚本
Fixtures/        最小 Keynote 原生验证样例
Verification/    回归测试、探针和原生验证产物
Docs/            P0/P1 验证报告
```

## 本机运行

在 macOS 14 或更高版本、Apple Silicon Mac 上执行：

```bash
./Packaging/build.sh --runtime
```

构建脚本会编译 SwiftUI 应用、打包隔离的 CPython 运行时、执行运动自检，并把可分发的 ZIP 写入 `dist/`。同步文件夹可能给直接解包的 `.app` 添加 Finder 元数据，分发时优先使用 ZIP。

## 验证

```bash
python3 Verification/test_adapter.py
python3 -m unittest discover -s ../Keynote沿线动画工具/tests -p 'test_*.py'
```

P2 当前支持当前幻灯片的根级对象选择、曲线导入和动画写回；成组目标、跨组件对象和逐帧差异测量仍待后续阶段完成。

## License

仓库暂未指定开源许可证。公开仓库中的代码默认不授予第三方复制、修改或分发权；正式开源前请补充合适的 LICENSE 文件。
