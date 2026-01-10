将中文字体（TTF）放到该目录，以便监督检查 PDF 文书正确显示中文。

当前实现采用“离线内嵌字体”的方式，避免中文显示方块/乱码。

必需文件（推荐使用开源 Noto Sans SC，免授权风险）：

方案 A（推荐，更容易下载）：
- NotoSansSC-Regular.ttf
- NotoSansSC-Bold.ttf

方案 B（单文件，可变字体，体积更大）：
- NotoSansSC-VF.ttf

下载方式（任选其一）：
- Google Fonts 下载 zip（通常最稳定）：
	- https://fonts.google.com/download?family=Noto%20Sans%20SC
	- 解压后从 `static/` 目录取出 `NotoSansSC-Regular.ttf` / `NotoSansSC-Bold.ttf`
- jsDelivr CDN（推荐，适合 GitHub/Google Fonts 受限环境，方案 B）：
	- https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf
	- 下载后重命名为 `NotoSansSC-VF.ttf`
- GitHub raw（方案 B，网络允许时可用）：
	- https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf
- noto-cjk Releases（也可）：
	- https://github.com/notofonts/noto-cjk/releases

放置位置：
- assets/fonts/NotoSansSC-Regular.ttf
- assets/fonts/NotoSansSC-Bold.ttf
或：
- assets/fonts/NotoSansSC-VF.ttf

注意：
- `pdf` 生成库无法自动使用系统字体，必须把字体文件作为 assets 打包进应用。
- 如果缺少该字体资源，监督检查 PDF 生成会直接报错并提示补齐。
