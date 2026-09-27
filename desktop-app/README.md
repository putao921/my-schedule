# MySchedule 日程应用

本仓库包含 MySchedule 日程管理应用的两套前端代码：

- `web/` —— 纯静态 **PWA**（HTML / CSS / JS，**无构建步骤**）。线上分享链接由该目录发布，是本项目的主要交付物。
- 根目录的 `*.ps1` —— 桌面版（WPF / PowerShell）源码，与网页版相互独立。

---

## 给外部协作者（AI agent）的协作规范

如果你是被请来修改本仓库的 AI agent，请务必遵守以下规则，否则改动不会生效或会引入回归。

### 1. 通常只改 `web/` 目录
桌面版 PowerShell 源码除非被明确点名，请勿改动。

### 2. 改完 `web/` 后必须升级 Service Worker 缓存版本号（关键）
打开 `web/sw.js`，把顶部
```js
const CACHE = 'myschedule-vN';
```
中的 `N` **加 1**（例如 `v5` → `v6`）。
- 原因：PWA 靠 SW 缓存离线运行，版本号不变，用户端永远加载旧缓存，看不到你的更新。
- 如果你新增了顶层 JS / CSS 文件，必须同时把它加进 `sw.js` 的 `SHELL` 清单数组，否则新文件不会被缓存、首次加载即报错。

### 3. 发布前必须跑自测
任意静态服务器打开页面并附带 `?selftest=1`，例如：
```bash
cd web
python3 -m http.server 8000
# 浏览器打开 http://127.0.0.1:8000/index.html?selftest=1
```
页面会把结果写进 `document.title` 和 `#selftestReport`，格式为 `SELFTEST X/Y`。
- **要求：X == Y（全绿）** 才能继续。
- 专注计时相关用例以 `timer.*` 开头（正计时 `timer.countsUp`、滚轮 `timer.pickerOpens` 等），拖拽相关以 `drag.*` 开头。
- 若 `drag.*` 在 headless 合成手势环境下偶发失败，先确认 `drag.js` 与基线一致再判定是否真回归。

### 4. 发布在 WorkBuddy 内完成
本仓库的线上链接由 WorkBuddy「发布为应用」管理（目录 `desktop-app/web`），发布后链接不变、覆盖更新。不要在其他平台另行托管 `web/`。

---

## 标准更新流程

```
改 web/ 文件
  → 升 web/sw.js 的 CACHE 版本号（+1）
  → （若新增资源）加入 sw.js 的 SHELL 清单
  → index.html?selftest=1 确认 SELFTEST 全绿
  → git commit
  → 在 WorkBuddy 发布（覆盖同一链接）
```

## 推荐的 GitHub 协作闭环（外部 agent 在 GitHub 上干活）

```
fork / 新建分支 → 只改 web/ → 开 PR → 仓库所有者 review + merge
        ↓
本地 git pull → 升 sw.js 版本号 → 跑自测 → WorkBuddy 发布
```

> 历史说明：分支已从 `master` 改名为 `main`，默认分支为 `main`。
