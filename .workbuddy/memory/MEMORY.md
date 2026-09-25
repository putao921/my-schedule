# 项目记忆 — 桌面小工具合集

## 项目位置
- 素材库：`C:\Users\lenovo\Desktop\小工具开发合集\桌面日程小工具\主题包\`
- 网页原型：`C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\schedule-widget\`
- **WPF 桌面版**：`C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app\`（交付包在 `dist\`）
- 验证工具：`desktop-app\verification\`（SyntaxCheck / ClosureScan / RunAudit `-Tag x -AutoClose 3` / RunAuditDist（跑 dist 副本）/ RunWeekDrag / RunShots7 / **RunShots8（最新，一次进程多场景截图，spec 串 `view:/theme:/weekrange:/size:/layout/tick/shot:/anchor:/taskshot:/focusshot:/audit/weekdrag`）**）

## 视觉规范（从主题包提取，复用于后续同类工具）
**配色（粉系像素风）**
```
--pink-100 #fbe9e6   --pink-200 #f7dedb   --pink-300 #f2c9c6
--pink-400 #e9aeae   --pink-800 #7d4550   （边框/描边主色）
--cream    #fffdf7   --cream-2 #fdf6e9    （面板底）
--ink      #3a2f2c   --ink-soft #6d5c58   --ink-faint #9a8884
--accent-event #c05a6c（事件/主按钮）  --accent-focus #f2b083（今日/专注）
--accent-task  #9fc4a4（任务卡）        --accent-holiday #e08a8a
```
**形态**：2px 实线深粉描边、圆角 7–12px、`box-shadow: 2px 2px 0` 硬阴影（非模糊）、按下位移 2px。
**字体**：像素英文用等宽，中文走系统字体（`PingFang SC` / `Microsoft YaHei`）。
**主题**：浅色为底，另有夜间变体（暗底浅字），通过 `:root[data-theme="night"]` 切换 CSS 变量。

## 约定
- 素材优先内联 SVG / canvas 重绘，不直接引用图片文件 —— 保证零依赖、可单文件分发。
- 所有模拟数据必须在代码中标注，并在 README 里写明替换点。
- 交付前必须用 CDP 在真实视口截图验证（`--window-size` 会被 headless 抬高，不可信）。

## 复用技巧
- 无头截图不要装 puppeteer：自写 ~60 行极简 WebSocket 客户端连 CDP 即可（见 2026-09-23 日志）。
- 多档断点验证要同时断言 `document.documentElement.scrollWidth === clientWidth`，防横向溢出。

## PowerShell + WPF 桌面版硬规则（踩过坑的，别再踩）
- **WPF 事件处理器回调时读不到创建函数的局部变量**（动态作用域+作用域销毁），StrictMode 下硬抛且常被 `catch{}` 吞成"点了没反应"。必须用 `$script:`（脚本顶层变量**不带限定名**也可见；`GetNewClosure()` 不可用，会隔离进新模块连函数都找不到）。静态验收工具：`verification\ClosureScan.ps1`。
- 参数名/变量名别用 `$Host`（只读自动变量）；别给 WPF 对象塞自定义属性（会抛"找不到属性"）。
- **StackPanel 不是 Control**（Panel→FrameworkElement→UIElement），参数类型声明要写 `FrameworkElement`。
- **主题切换 = 换皮不换窗**：重建 Window 再 `Show()` 会静默失败（IsLoaded 恒 false）；把新树 `Content` 过户给现有窗口，Window 级钩子用 `$script:LifecycleHooked` 只挂一次。
- `ShutdownMode` 显式 `OnExplicitShutdown`，退出统一走 Closed 处理器里的 `App.Shutdown()`；重建期间用 `$script:Rebuilding` 让旧窗口的 Closing/Closed 让路。
- 像素按钮底色在 ControlTemplate 的 `bd` 边框上，改 `Button.Background` 无效；要 `ApplyTemplate()` + `Template.FindName('bd',$b)`。
- 回归/截图一律独立时间戳数据目录（沙箱禁递归删除），结果写文件再 Read（stdout 会被吞）；WPF 一个进程只能 `Application.Run` 一次，多次运行要分开进程。

- **无边框透明 WPF 窗口要能鼠标缩放**：仅设 `ResizeMode=CanResize` 不够，因没有系统非客户区；用 `WindowChrome` 设置 `ResizeBorderThickness=10`、`CaptionHeight=0`，同时保留自定义标题栏 `DragMove`。
- **周视图表头与内容竖线对齐**：滚动条会只挤压 `ScrollViewer` 内容宽度；将纵向滚动条设为 `Visible`，并给固定表头预留 `SystemParameters.VerticalScrollBarWidth`，两边星号列即可同宽。
- **周视图日程块交互**：用 `Canvas` 覆盖层 + 15 分钟吸附；中心拖动改日期/时间，上/下 8px 命中区改起止时间，双击打开编辑窗。WPF `MouseButtonEventArgs.ClickCount` 在外部测试时需通过反射设值。
- **换皮不换窗必须连资源字典一起过户**：`Build-Window` 里只搬 `$w.Content` 会让 `Window.Resources`（隐式 `Style TargetType="..."` 的烘死色值）停在**首次启动**那一份 → 之后代码 new 出来的控件夜间变白底白字。正确顺序：先 `$reuse.Resources = <$w.Resources 的副本>`，再 `$reuse.Content = $w.Content`。
- **对话框（独立 Window）拿不到主窗口的隐式样式**：用 `$script:MainWindow.TryFindResource([类型])` 取回样式再显式赋 `Style` / `ItemContainerStyle`（`Apply-SharedComboStyle`），别复制第二份主题 XAML。
- **自定义 ComboBox 模板必须含 `TextBox Name="PART_EditableTextBox"` + `IsEditable` 触发器**：否则 `IsEditable=True` 的字段（重复/提醒/优先级）一个字都不显示。
- **外观断言读"真正画底色的模板元素"**：`ApplyTemplate()` 后 `Template.FindName('PART_Toggle', $x).Background`，并断言"文字色 ≠ 底色"；读控件自己的 `Background` 读不到真相。
- **周视图时段可调**（全天/常用/工作/上午/下午/晚间/自定义）：状态是 `$script:WeekStartHour` / `WeekEndHour`，映射用 `Week-MinuteToY` / `Get-WeekMinuteFromY`；刻度画在**独立轴层 `WeekAxis`**（换时段只重画轴，不能重建控件，否则 ComboBox 弹层被撕掉）。**拖动写入必须与视觉同夹到 `[Start,End]`**，否则 08:00–20:00 视图里往上拖会写回 00:00、事件直接消失。
- **六个弹窗共用一套 chrome**：`Get-EditorChrome` 返回 `@{Root;Bar;BarText;BtnClose}`，标题栏是 2 列 Grid（标题 + 34px 关闭位）。改弹窗外观**只改这一个函数**。语义：**右上角 × = 确认并关闭**（各弹窗把旧主按钮的处理器搬过去，校验逻辑不动），**Esc = 放弃修改**；底部不再放 Cancel/Save/Close。× 用独立模板（`New-PixBtn` 的 ContentPresenter 有 9px 内边距，26px 按钮放不下 10px 的 ×）。
- **从未 `Show()` 过的 Window 尺寸恒为 0**，`Window.UpdateLayout()` 修不好 → 无头断言要 `Measure-DialogContent`（内容根上手工 `Measure(∞)` + `Arrange(DesiredSize)`）。同族：非模态窗口赋 `DialogResult` 会抛，必须 `try` 包住（见 `Close-DialogWindow`）；判"控件在不在"别用 `IsVisible`（未 Show 恒 false），用 `Find-AllOfType`。
- **挂 `DragMove()` 的自定义标题栏要显式放行按钮**：`Test-ClickOnButton` 从 `OriginalSource` 往上走可视树（带 guard），碰到 `ButtonBase` 就 return，否则点按钮会进模态拖动循环。
- **按文字定位控件的辅助函数在换图标后静默返回 `$null`**：× 的 Content 是 Path，`Find-ButtonByText` 永远找不到 → 用 `Find-DialogClose`（按 `Name='DlgClose'`）。改 UI 文案/图标时 grep 一遍旧判据。
- **月视图分页**：`offset=([int]$first.DayOfWeek+6)%7`（周一=0）、`rows=Ceiling((offset+DaysInMonth)/7)`、下限 4；非本月格子用 `New-MonthPadCell`（`Panel` 底 + `Opacity 0.75` + `InkFaint` 日号，**不画**日程/角标/今天高亮），跨月边界用 `$first.AddDays($n-1)` 让 `DateTime` 自己进位。补齐格用独立 `kind='day-pad'`（单击跳那周、右键故意不响应），复用 `'day'` 会让"9 月页面右键 8/31 弹出 8/31 新建窗"。审计锚点 `$script:MonthDaysShown`（每格日号，空位 0）/ **`MonthPadDates` / `MonthPageInfo.Pads`** / `MonthGridRoot` 由 `Render-Month` 发布；`MonthDaysShown` 的"非本月记 0"语义不变，老断言才继续有效。
- **窄窗里的工具栏用 `WrapPanel`**（横向 `StackPanel` 会把右侧控件裁掉而断言全绿）；多档尺寸截图必须断言"几何在容器内"，不能只断言"元素存在"。
- **数组字面量 `@()` 里禁止做拼接/算术**：逗号优先级高于 `+`，`'anchor:' + $today` 会被切成两个元素。先算好存变量再放进数组。
- **`Set-StrictMode` 下读 PSCustomObject 的"不存在的属性"会抛异常**（不是返回 `$null`）。任务对象是"可选字段"结构，读 `$t.due` 这种一定要过安全读帮手（`Get-TaskField`），并且**渲染路径里的排序/过滤必须包 `try` + 失败标记**，否则一条脏数据会让整页渲染中断（表现为审计在某个块崩掉、后面几十条断言全不跑）。
- **`Sort-Object -Property` 里别混用两种 scriptblock 写法**：`{ param($t) … }` 拿不到管道对象（`$_` 才有），而同一个 `-Property` 数组里混着 `{ … $_ … }` 简写时，前者会静默拿到 `$null` / 报"找不到属性"。统一用 `$_` 简写。
- **`WindowStartupLocation='CenterOwner'` 会在 `Show()` 时静默覆盖手写的 `Left/Top`** → 要记住/恢复弹窗位置，必须配 `'Manual'`。`DragMove()` 是模态消息循环，**它后面那句就是"松手"时刻**，在那里落盘位置最自然；记忆值要按**虚拟屏幕**（含负坐标）校验并留可见边距，否则拔掉外接屏后窗口永久失踪。
- **余高要用 `*` / `Auto` 行"集中到两簇之间"**，而不是让 `Auto` 堆在最底下留个洞；断言要同时查"行号"和"那一行里装的是谁"（只数行数会在"行数对了但东西还留在可滚动的那簇里"时假绿）。
- **高度自适应要有"地板值"**：`HourHeight` 这类按可视高度反算的密度，下限钉在既有设计值（40），可保证新行为**只往"变大"方向触发**，回归尺寸的观感一模一样。
- **断言要连"机制"一起断，别只断"逻辑量"**：占位提示只断 `Visibility=Visible` 会假绿 —— 底色画回输入框上时提示被整块盖住，逻辑全过、界面全无。所以还要断"输入框背景 alpha = 0"这类物理量。
- **WPF 一个进程只能跑一个应用**：同一进程里第二次启动会在 `XamlReader.Load` 抛 NullReference、`elapsed` 只有 0.1s，而且**磁盘上留着的是上一次的旧截图**（看着像"改动没生效"）。诊断特征 = `elapsed` 异常小 + 只有 CATCH 没有 SHOT 行；每个 app run 独立进程。
- **给 `Write-AuditRow` 改名时，`catch` 里那一份也要改**：只改 `try` 里那份，崩了之后会打出一个已经不存在的旧名字，报告里表现为"少一行 + 多一行"，很难认。
- **函数参数名别取 `$args`**（与 `$Host` 同一类）：`$args` 是自动变量（未绑定参数数组），同名参数会在函数入口**被绑定器覆盖成 `@()`** —— 实参传进来了、函数体读到的却是空数组；`$Args.ClickCount` 在 StrictMode 2.0 下**直接抛**，被 `try/catch` 吞掉后静默降级成兜底值、测试全绿。实测（`verification\_args_probe.txt`）：`param($Args)` 读 `.ClickCount` 抛"在此对象上找不到属性"，`param($X)` 读同一对象得 `2`。本项目三个函数中招：`Get-MouseClickCount`（永远返回 1 → 所有双击分支死）、`Get-EventSourceOf`（永远走不到 `OriginalSource`）、`Test-ClickOnButton`（永远 `$false`）。统一改 `$Evt`，并已加进 `SyntaxCheck.ps1` 静态硬错误。
- **`.GetNewClosure()` 禁用**：它把脚本块复制进**新动态模块**，动态模块函数表只有 global 作用域 → 脚本作用域里的函数（`Get-Pal`/`New-Txt`）在闭包里一律 `CommandNotFoundException`。三个条件叠加才暴露（不展开走不到 / 只有双击才展开 / 抛出点在 `Fill-Tasks` 的 `Children.Clear()` **之后**），用户看到的是"双击没反应 + 整列任务消失"。同一作用域内同步 `&` 调用的脚本块**不需要**闭包。已加静态硬错误。
- **"先 `Children.Clear()` 再逐块重建"是错误放大模式**：局部异常会升级成"整页空白"。`Fill-Tasks` 已改成"先建进本地列表、整轮无异常再一次性换上"（原子替换）。凡这类渲染都该照此办理。
- **新加静态规则必须做负向测试**：故意把坏代码写回去，确认"报错且只报那一处"，再逐字节还原。`ClosureScan.ps1` 头注释早就写了"GetNewClosure 不能用"却没有断言拦着，同一个坑被写了第二次 —— **没被强制执行的知识等于不存在**。
- **每条旁路都要配一条"不走旁路"的断言**：任务卡双击测试一直靠 `$script:SyntheticClickCount` 注入 ClickCount，因此**从未执行**真实的 `$Args.ClickCount` 那一行，`$args` 冲突这个 bug 得以对 93 条断言完全免疫。
- **深层脚本块里的异常要记 `$_.ScriptStackTrace` 首帧**：只写 `Exception.Message` 只能看到"找不到某某函数"，定位不到是谁在调它；本次就是靠它钉死 `Views.ps1:1999`。
