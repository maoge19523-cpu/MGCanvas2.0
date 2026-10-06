# 来源与许可说明（CREDITS & LICENSE NOTICE）

## 本项目是什么

**猫歌映画（MGStudio）** 是基于开源项目 **NOVAI · Infinite Canvas** 二次开发的桌面应用。
我们在其基础上做了**品牌私有化换标**（软件名、标识、配色、安装包、桌面壳），
**功能逻辑未做修改**。

## 上游项目

| 项 | 值 |
|---|---|
| 项目名 | NOVAI / Infinite Canvas |
| 仓库 | https://github.com/invaders-2/NOVAI-Infinite-Canvas |
| 作者 | invaders-2 |
| 本分叉基线版本 | 1.0.123 |

## 许可（务必阅读）

上游 `LICENSE` 与 `LICENSE.nsi` 是一份**自定义非商业许可**，不是 MIT。
原文要点：

> * 禁止商业用途 / Commercial use is prohibited.
> * 可以自己使用和公司使用，禁止用于任何形式的修改封装成商业产品，商用须取得授权。
> * 根据代码二次开发的软件必须保持开源并注明来源作者。
> * Software developed based on this code must remain open source and the original author must be credited.

**对本项目的约束，翻译成可执行的规则：**

| 使用方式 | 是否允许 |
|---|---|
| 自己用 / 公司内部用 | ✅ 允许 |
| 修改、换标、改界面 | ✅ 允许（本仓库做的就是这件事） |
| 保持开源（本仓库公开可读） | ✅ 符合要求 |
| **把成品当商业产品出售 / 打包成商业产品** | ❌ **禁止，需先取得原作者授权** |
| 去掉来源署名后再分发 | ❌ **禁止** |

所以：

- 本仓库**不能标成 MIT**（上游 `desktop/package.json` 里写的 `"license": "MIT"` 与真实 `LICENSE` 冲突，属于上游笔误，我们已按真实许可改正）。
- 本仓库**不能闭源**。私有仓库（仅自己/团队可读）符合"保持开源"的精神；
  一旦对外分发，需要让使用者能拿到源码。
- 需要商业授权时，请自行联系上游作者。

## 本分叉的改动

- 品牌：NOVAI → **猫歌映画 / MGStudio**
- 标识与配色：全新黑橙（#FF6A00）标识，替换全套 ico / icns / png / svg
- 上游链路：三源更新检查与 electron-updater 发布配置改指本仓库
- 修复：打包后端二进制命名冲突、成品托盘图标缺失（`build.files` 补 `icons/**`）
- 版本：重置为 1.0.0

## 本项目维护者

**maoge19523-cpu** — https://github.com/maoge19523-cpu/MGCanvas2.0

## 同作者的另一个项目（许可不同，勿混）

**MGCanvas / 猫歌映画 Canvas** — https://github.com/maoge19523-cpu/MGCanvas
该项目基于 `basketikun/infinite-canvas`，采用 **AGPL-3.0**。
两个项目的上游、代码库、许可**互相独立**，请勿混用许可条款。
