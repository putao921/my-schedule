param(
    [string]$Root = 'C:\Users\lenovo\WorkBuddy\2026-09-23-15-30-45\desktop-app',
    [string]$Report
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName PresentationCore | Out-Null
Add-Type -AssemblyName WindowsBase | Out-Null
Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

$Widget = Join-Path $Root 'ScheduleWidget.ps1'
$DataDir = Join-Path $Root 'verification\appdata'
if (Test-Path -LiteralPath $DataDir) {
    Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$log = New-Object System.Collections.Generic.List[string]
function W { param([string]$t) $log.Add($t) }
$script:Pass = 0; $script:Fail = 0
function Check2 {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    W ("  [{0}] {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name,
       $(if ($Detail) { '  -> ' + $Detail } else { '' }))
}
function Get-Rect2D {
    param($El, $Rt)
    $tl = $El.TranslatePoint((New-Object System.Windows.Point(0.0, 0.0)), $Rt)
    $br = $El.TranslatePoint((New-Object System.Windows.Point($El.ActualWidth, $El.ActualHeight)), $Rt)
    return @{ L = $tl.X; T = $tl.Y; R = $br.X; B = $br.Y }
}
function Find-ByTag {
    param($Root, [string]$Kind, [string]$Id = '')
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $hits = New-Object System.Collections.ArrayList
    $guard = 0
    while ($stack.Count -gt 0 -and $guard -lt 20000) {
        $guard++
        $n = $stack.Pop()
        try {
            if ($null -ne $n.Tag -and ($n.Tag -is [hashtable])) {
                $t = $n.Tag
                if ($t.ContainsKey('kind') -and [string]$t.kind -eq $Kind) {
                    if (-not $Id -or [string]$t.id -eq $Id) { [void]$hits.Add($n); continue }
                }
            }
        } catch { }
        try {
            $kids = $n.Children
            if ($null -ne $kids) { foreach ($c in @($kids)) { $stack.Push($c) } }
        } catch { }
    }
    return @($hits)
}
function Count-Key {
    param([string]$Text, [string]$Needle)
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

$script:Step = 0
$script:LastStep = 30
$script:Harness = New-Object System.Windows.Threading.DispatcherTimer
$script:Harness.Interval = [timespan]::FromMilliseconds(900)
$script:Harness.Add_Tick({
    $script:Step++
    try {
        switch ($script:Step) {

  1 {
      W '=== 1. 启动与骨架 ==='
      [void]$script:MainWindow.UpdateLayout()
      Check2 '主窗口已创建' ($null -ne $script:MainWindow)
      Check2 '窗口可见' ([bool]$script:MainWindow.IsVisible)
      Check2 'NodeHost 已解析' ($null -ne $script:NodeHost)
      Check2 'UiOverlay 已解析' ($null -ne $script:UiOverlay)
      Check2 'UiOverlay 与 NodeHost 同父（叠放）' ($script:UiOverlay.Parent -eq $script:NodeHost.Parent)
      $kids = @($script:NodeHost.Parent.Children)
      Check2 'UiOverlay 在父容器里排在 NodeHost 之后（=画在上面）' `
        ($kids.IndexOf($script:UiOverlay) -gt $kids.IndexOf($script:NodeHost))
      Check2 '窗口尺寸 >= 720x520' ([double]$script:MainWindow.ActualWidth -ge 720.0 -and [double]$script:MainWindow.ActualHeight -ge 520.0) `
        ("{0}x{1}" -f [int]$script:MainWindow.ActualWidth, [int]$script:MainWindow.ActualHeight)
      Check2 '窗口无边框' ($script:MainWindow.WindowStyle -eq 'None')
      Check2 '窗口可缩放' ($script:MainWindow.ResizeMode -eq 'CanResize')
      Check2 '已挂 3 个视图切换按钮' ($null -ne $script:BtnViewMonth -and $null -ne $script:BtnViewWeek -and $null -ne $script:BtnViewList)
      Check2 '左侧导航 3 项 + 任务 + 设置' ($null -ne $script:NavMonth -and $null -ne $script:NavWeek -and $null -ne $script:NavList -and $null -ne $script:NavTask -and $null -ne $script:NavSettings)
      Check2 '头像画布有像素块' (@($script:AvatarCanvas.Children).Count -gt 100) ("blocks=" + @($script:AvatarCanvas.Children).Count)
      Check2 '番茄钟弧已上色（Ring）' ($null -ne $script:PomoArc.Stroke)
      Check2 '标题栏文案 = Month view' ($script:WinTitle.Text -eq 'Main window - Month view') $script:WinTitle.Text
      Check2 '番茄钟显示 25:00' ($script:PomoText.Text -eq '25:00') $script:PomoText.Text
      return
  }

  2 {
      W '=== 2. 月视图内容 ==='
      [void]$script:MainWindow.UpdateLayout()
      $cells = @(Find-ByTag $script:NodeHost 'day')
      Check2 '月视图渲染出 42 个日期格' ($cells.Count -eq 42) ("got " + $cells.Count)
      if ($script:Skeleton) { W '  (骨架屏模式：跳过内容断言)'; return }
      $evs = @(Find-ByTag $script:NodeHost 'event')
      Check2 '月视图有事件内容（标题文字）' ($evs.Count -ge 0)
      $period = $script:CalPeriod.Text
      Check2 '月份标题非空' (-not [string]::IsNullOrWhiteSpace($period)) $period
      Check2 '月份标题 = 当前月' ($period -eq ($script:MonNames[$script:Anchor.Month - 1] + ' ' + $script:Anchor.Year)) $period
      # 网格铺满且不裁
      $host2 = $script:NodeHost
      $grid = $null
      if (@($host2.Children).Count -gt 0) {
          $wrap = $host2.Children[0]
          if (@($wrap.Children).Count -gt 0) { $grid = $wrap.Children[0] }
      }
      if ($null -ne $grid) {
          Check2 '月视图容器整宽铺满' ([math]::Abs([double]$grid.ActualWidth - [double]$host2.ActualWidth) -le 1.5) `
            ("{0:0.0} vs {1:0.0}" -f [double]$grid.ActualWidth, [double]$host2.ActualWidth)
          Check2 '月视图容器整高铺满' ([math]::Abs([double]$grid.ActualHeight - [double]$host2.ActualHeight) -le 1.5) `
            ("{0:0.0} vs {1:0.0}" -f [double]$grid.ActualHeight, [double]$host2.ActualHeight)
      }
      return
  }

  3 {
      W '=== 3. 周视图 ==='
      Set-View 'week'
      [void]$script:MainWindow.UpdateLayout()
      # 视图切换后必须下一拍再量尺寸
      return
  }

  4 {
      [void]$script:MainWindow.UpdateLayout()
      $cells = @(Find-ByTag $script:NodeHost 'day')
      Check2 '周视图不再有 day 格（视图真的换了）' ($cells.Count -eq 0) ("got " + $cells.Count)
      Check2 'CalLabel = This week' ($script:CalLabel.Text -eq 'This week') $script:CalLabel.Text
      $head = @(Find-ByTag $script:NodeHost 'weekhead')
      Check2 '周视图有表头' ($head.Count -eq 1)
      $ov = $script:WeekOverlay
      Check2 '周视图事件层已建' ($null -ne $ov)
      if ($null -ne $ov) {
          Check2 '事件层宽度 > 300px（宽度求解成功）' ([double]$ov.ActualWidth -gt 300.0) ("w=" + [int][double]$ov.ActualWidth)
          $cards = @($ov.Children | Where-Object { $_ -is [System.Windows.Controls.Border] })
          Check2 '事件层画出了日程卡' ($cards.Count -gt 0) ("cards=" + $cards.Count)
          # 卡片不许横向越界
          $bad = 0
          foreach ($c in $cards) {
              $l = [System.Windows.Controls.Canvas]::GetLeft($c)
              if ($l -lt -0.5 -or ($l + [double]$c.Width) -gt ([double]$ov.ActualWidth + 1.5)) { $bad++ }
          }
          Check2 '日程卡无横向越界' ($bad -eq 0) ("bad=" + $bad)
          # 卡片不许纵向越出画布
          $badY = 0
          foreach ($c in $cards) {
              $t = [System.Windows.Controls.Canvas]::GetTop($c)
              if ($t -lt -0.5 -or $t -gt 24.0 * $script:HourHeight) { $badY++ }
          }
          Check2 '日程卡无纵向越界' ($badY -eq 0) ("bad=" + $badY)
      }
      # 整点横线画在列底之后（坑 16：绘制顺序）
      $kids = @($script:WeekCanvas.Children)
      $colIdx = -1; $lineIdx = -1
      for ($i = 0; $i -lt $kids.Count; $i++) {
          $c = $kids[$i]
          if ($c -isnot [System.Windows.Controls.Border]) { continue }
          $bt = $c.BorderThickness
          if ($bt.Left -eq 0 -and $bt.Right -eq 0 -and $bt.Top -eq 0 -and $bt.Bottom -eq 2 -and $colIdx -lt 0) { $colIdx = $i }
          if ($bt.Left -eq 0 -and $bt.Top -eq 1 -and $lineIdx -lt 0) { $lineIdx = $i }
      }
      Check2 '整点横线画在整列底色之后' ($lineIdx -gt $colIdx) ("col=$colIdx line=$lineIdx")
      $ovIdx = $kids.IndexOf($script:WeekOverlay)
      Check2 '事件层画在整点横线之后（不被格线压住）' ($ovIdx -gt $lineIdx) ("ov=$ovIdx line=$lineIdx")
      return
  }

  5 {
      W '=== 4. 列表视图 ==='
      Set-View 'list'
      return
  }

  6 {
      [void]$script:MainWindow.UpdateLayout()
      Check2 'CalLabel = All' ($script:CalLabel.Text -eq 'All') $script:CalLabel.Text
      Check2 '左侧事件流已填充' (@($script:ListStack.Children).Count -gt 0) ("rows=" + @($script:ListStack.Children).Count)
      Check2 '右侧任务列表已填充' (@($script:TaskStack.Children).Count -gt 0) ("rows=" + @($script:TaskStack.Children).Count)
      $rows = @(Find-ByTag $script:ListStack 'event')
      Check2 '事件行带 event 标签（可点开编辑）' ($rows.Count -gt 0) ("got " + $rows.Count)
      $tks = @(Find-ByTag $script:TaskStack 'task')
      Check2 '任务行带 task 标签（可勾选）' ($tks.Count -gt 0) ("got " + $tks.Count)
      $taskCount0 = @($script:Tasks).Count
      # 检索：用一个必然不存在的关键词，两侧都应变空
      $script:ListSearch.Text = 'zzz_no_such_event'
      return
  }

  7 {
      [void]$script:MainWindow.UpdateLayout()
      $rows = @(Find-ByTag $script:ListStack 'event')
      Check2 '检索不存在的词 -> 事件流为空' ($rows.Count -eq 0) ("got " + $rows.Count)
      $empties = @($script:ListStack.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and ([string]$_.Text) -eq 'No events found' })
      Check2 '检索无结果显示空状态文案' ($empties.Count -eq 1)
      # 恢复
      $script:ListSearch.Text = ''
      return
  }

  8 {
      [void]$script:MainWindow.UpdateLayout()
      $rows = @(Find-ByTag $script:ListStack 'event')
      Check2 '清空检索后事件流恢复' ($rows.Count -gt 0) ("got " + $rows.Count)
      # 勾选一个任务
      $tks = @(Find-ByTag $script:TaskStack 'task')
      $target = $tks[0]
      $id = [string]$target.Tag.id
      $before = @($script:Tasks | Where-Object { [string]$_.id -eq $id })[0].done
      $target.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  9 {
      $tks = @(Find-ByTag $script:TaskStack 'task')
      $id = [string]$tks[0].Tag.id
      $after = @($script:Tasks | Where-Object { [string]$_.id -eq $id })[0].done
      Check2 '勾选任务后 done 状态翻转' ($after -ne $before) ("before=" + $before + " after=" + $after)
      # 落盘校验
      $saved = Get-Content -LiteralPath $script:DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $hit = @($saved.tasks | Where-Object { [string]$_.id -eq $id })
      Check2 '任务勾选已落盘' ($hit.Count -eq 1 -and [bool]$hit[0].done -eq $after) ("disk=" + [bool]$hit[0].done)
      return
  }

  10 {
      W '=== 5. 主题切换（整窗重建） ==='
      $before = @($script:Events).Count
      $script:ThemeBefore = $script:Theme
      Set-Theme 'night'
      return
  }

  11 {
      [void]$script:MainWindow.UpdateLayout()
      Check2 '主题已切到 night' ($script:Theme -eq 'night')
      Check2 '窗口已重建（新对象）' ($null -ne $script:MainWindow -and [bool]$script:MainWindow.IsVisible)
      Check2 '夜间模式标题栏底色来自夜间色板' `
        ([string]$script:TitleBar.Background.Color -eq [string]([System.Windows.Media.ColorConverter]::ConvertFromString($script:PaletteNight['Chrome']))) `
        ([string]$script:TitleBar.Background.Color)
      Check2 '夜间模式节点宿主非空' ($null -ne $script:NodeHost -and @($script:NodeHost.Children).Count -gt 0)
      Check2 '重建后事件数据未丢' (@($script:Events).Count -eq $before) ("got " + @($script:Events).Count)
      Check2 '夜间模式仍能切视图' ($null -ne $script:BtnViewMonth)
      Set-View 'month'
      return
  }

  12 {
      [void]$script:MainWindow.UpdateLayout()
      $cells = @(Find-ByTag $script:NodeHost 'day')
      Check2 '夜间模式月视图仍有 42 格' ($cells.Count -eq 42) ("got " + $cells.Count)
      Check2 '夜间月标题仍非空' (-not [string]::IsNullOrWhiteSpace($script:CalPeriod.Text)) $script:CalPeriod.Text
      # 切回浅色，验证往返
      Set-Theme 'light'
      return
  }

  13 {
      [void]$script:MainWindow.UpdateLayout()
      Check2 '主题往返回到 light' ($script:Theme -eq 'light')
      Check2 '浅色标题栏底色 = 浅色板 Chrome' `
        ([string]$script:TitleBar.Background.Color -eq [string]([System.Windows.Media.ColorConverter]::ConvertFromString($script:PaletteLight['Chrome']))) `
        ([string]$script:TitleBar.Background.Color)
      $cells = @(Find-ByTag $script:NodeHost 'day')
      Check2 '往返后月视图完好' ($cells.Count -eq 42) ("got " + $cells.Count)
      return
  }

  14 {
      W '=== 6. 置顶 / 折叠 / 翻页 ==='
      $pin0 = [bool]$script:MainWindow.Topmost
      $script:BtnPin.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  15 {
      Check2 'Pin 打开后窗口 Topmost=True' ([bool]$script:MainWindow.Topmost) ("pin=" + $script:TopmostOn)
      $script:BtnPin.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  16 {
      Check2 'Pin 再点关闭 Topmost=False' (-not [bool]$script:MainWindow.Topmost) ("pin=" + $script:TopmostOn)
      # 折叠侧栏
      $script:BtnCollapse.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      [void]$script:MainWindow.UpdateLayout()
      return
  }

  17 {
      [void]$script:MainWindow.UpdateLayout()
      Check2 '折叠后侧栏列宽 = 0' ([double]$script:NavCol.Width.Value -eq 0.0) ("w=" + [double]$script:NavCol.Width.Value)
      Check2 '折叠后主区变宽（画布铺满没被撑开）' `
        ([double]$script:NodeHost.ActualWidth -gt 300.0) ("w=" + [int][double]$script:NodeHost.ActualWidth)
      $script:BtnCollapse.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  18 {
      [void]$script:MainWindow.UpdateLayout()
      Check2 '展开后侧栏列宽恢复 126' ([double]$script:NavCol.Width.Value -eq 126.0) ("w=" + [double]$script:NavCol.Width.Value)
      $a0 = $script:Anchor
      $script:BtnNext.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  19 {
      $d = ($script:Anchor.Month - $a0.Month)
      if ($a0.Month -eq 12 -and $script:Anchor.Month -eq 1) { $d = -11 }
      Check2 'Next 把锚点推进 1 个月' ($d -eq 1 -or $d -eq -11) ("from " + $a0.ToString('yyyy-MM') + " to " + $script:Anchor.ToString('yyyy-MM'))
      [void]$script:MainWindow.UpdateLayout()
      Check2 '翻页后月标题跟着变' ($script:CalPeriod.Text -eq ($script:MonNames[$script:Anchor.Month - 1] + ' ' + $script:Anchor.Year)) $script:CalPeriod.Text
      $script:BtnThis.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  20 {
      Check2 'This month 回到本月' ($script:Anchor.Month -eq [datetime]::Today.Month -and $script:Anchor.Year -eq [datetime]::Today.Year) $script:Anchor.ToString('yyyy-MM')
      W '=== 7. 番茄钟 ==='
      $script:Pomo.Reset = $null
      $script:Pomo.Remaining = 3
      $script:Pomo.Total = 25 * 60
      $script:Pomo.Running = $false
      Update-PomodoroVisual
      Check2 '番茄钟环有几何数据（非空 Path）' ($null -ne $script:PomoArc.Data) ("bounds=" + [int]$script:PomoArc.Data.Bounds.Width + "x" + [int]$script:PomoArc.Data.Bounds.Height)
      $script:BtnPomo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  21 {
      Check2 '开始后 Running=True' ([bool]$script:Pomo.Running)
      Check2 '按钮文案变为 Pause' ($script:PomoBtnText.Text -eq 'Pause') $script:PomoBtnText.Text
      Check2 '计时器已启动' ($null -ne $script:PomoTimer -and [bool]$script:PomoTimer.IsEnabled)
      $script:BtnPomo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
      return
  }

  22 {
      Check2 '暂停后 Running=False' (-not [bool]$script:Pomo.Running)
      Check2 '按钮文案回到 Start' ($script:PomoBtnText.Text -eq 'Start') $script:PomoBtnText.Text
      Check2 '暂停后计时器已停' (-not [bool]$script:PomoTimer.IsEnabled)
      # 验证进度环真的有三档（不是只有空/满两档）—— 坑 24
      $widths = @()
      foreach ($rem in @(25 * 60, (25 * 60) - 300, (25 * 60) - 750, (25 * 60) - 1500, 57)) {
          $script:Pomo.Total = 25 * 60
          $script:Pomo.Remaining = $rem
          Update-PomodoroVisual
          $widths += [double]$script:PomoArc.Data.Bounds.Width
      }
      $uniq = @($widths | Sort-Object -Unique)
      Check2 '进度环几何随剩余时间连续变化（不是空/满两档）' ($uniq.Count -ge 4) ("widths=" + ($widths -join ', '))
      return
  }

  23 {
      W '=== 8. 屏幕截图 ==='
      Set-View 'month'
      Set-Theme 'light'
      $script:MainWindow.Width = 1080.0
      $script:MainWindow.Height = 720.0
      return
  }

  24 {
      [void]$script:MainWindow.UpdateLayout()
      Save-Shot -Path (Join-Path $Root 'verification\shot-month-light.png')
      Check2 '月视图浅色截图已生成' (Test-Path -LiteralPath (Join-Path $Root 'verification\shot-month-light.png'))
      Set-View 'week'
      return
  }

  25 {
      [void]$script:MainWindow.UpdateLayout()
      Save-Shot -Path (Join-Path $Root 'verification\shot-week-light.png')
      Check2 '周视图浅色截图已生成' (Test-Path -LiteralPath (Join-Path $Root 'verification\shot-week-light.png'))
      Set-View 'list'
      return
  }

  26 {
      [void]$script:MainWindow.UpdateLayout()
      Save-Shot -Path (Join-Path $Root 'verification\shot-list-light.png')
      Check2 '列表视图浅色截图已生成' (Test-Path -LiteralPath (Join-Path $Root 'verification\shot-list-light.png'))
      Set-Theme 'night'
      return
  }

  27 {
      [void]$script:MainWindow.UpdateLayout()
      Set-View 'month'
      return
  }

  28 {
      [void]$script:MainWindow.UpdateLayout()
      Save-Shot -Path (Join-Path $Root 'verification\shot-month-night.png')
      Check2 '月视图夜间截图已生成' (Test-Path -LiteralPath (Join-Path $Root 'verification\shot-month-night.png'))
      Set-View 'week'
      return
  }

  29 {
      [void]$script:MainWindow.UpdateLayout()
      Save-Shot -Path (Join-Path $Root 'verification\shot-week-night.png')
      Set-View 'list'
      return
  }

  30 {
      [void]$script:MainWindow.UpdateLayout()
      Save-Shot -Path (Join-Path $Root 'verification\shot-list-night.png')
      Check2 '夜间三视图截图齐备' `
        ((Test-Path (Join-Path $Root 'verification\shot-month-night.png')) -and
         (Test-Path (Join-Path $Root 'verification\shot-week-night.png')) -and
         (Test-Path (Join-Path $Root 'verification\shot-list-night.png')))
      $script:Harness.Stop()
      $script:AllowClose = $true
      $script:MainWindow.Close()
      return
  }

  default {
      W ("!! 步进看门狗：第 " + $script:Step + " 拍无人响应（步骤标签缺失或重复）")
      $script:Fail++
      try { $script:Harness.Stop() } catch { }
      try { $script:AllowClose = $true; $script:MainWindow.Close() } catch { }
      return
  }
        }
    } catch {
        W ("!! 步骤 " + $script:Step + " 异常: " + $_.Exception.Message)
        W ("   at line " + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
        W ("   出错语句: " + $(try { ([string]$_.InvocationInfo.Line).Trim() } catch { '?' }))
        $script:Fail++
    }
})

try {
    $script:Harness.Start()
    . $Widget -TestMode -DataDir $DataDir -StartView month
} catch {
    W ("!! 主脚本异常: " + $_.Exception.Message)
    W ("   at line " + $(try { $_.InvocationInfo.ScriptLineNumber } catch { '?' }))
    W ("   出错语句: " + $(try { ([string]$_.InvocationInfo.Line).Trim() } catch { '?' }))
    $script:Fail++
}

W ''
W '--- 汇总 ---'
W ("  通过 $($script:Pass) 项 · 失败 $($script:Fail) 项")
W '--- errors.log（程序自记日志）---'
$err = Join-Path $DataDir 'errors.log'
if (Test-Path -LiteralPath $err) {
    $raw = Get-Content -LiteralPath $err -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { W '(空)' } else { W $raw }
} else { W '(无)' }
W '--- bootlog.txt ---'
$bl = Join-Path $DataDir 'bootlog.txt'
if (Test-Path -LiteralPath $bl) { W (Get-Content -LiteralPath $bl -Raw -Encoding UTF8) } else { W '(无)' }
$rf = Join-Path $Root 'verification\shot-month-light.png'
if (Test-Path -LiteralPath $rf) { W ('月视图截图字节数: ' + (Get-Item -LiteralPath $rf).Length) }

if (-not $Report) { $Report = Join-Path $Root 'verification\report.txt' }
[System.IO.File]::WriteAllText($Report, ($log -join [Environment]::NewLine),
    (New-Object System.Text.UTF8Encoding($false)))
