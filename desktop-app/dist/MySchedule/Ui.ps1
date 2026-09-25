# =============================================================================
#  My Schedule - 界面层（XAML 窗口 + 三视图渲染）
#  本文件由 ScheduleWidget.ps1 dot-source，不要单独运行
# =============================================================================

# ---------------------------------------------------------------------------
#  A. 窗口 XAML
#     说明：颜色以占位符 __KEY__ 形式写，启动时按主题替换
#           —— 这样"启动即夜间模式"与"运行中切换主题"走同一条路
# ---------------------------------------------------------------------------
$windowXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Schedule"
        WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="CanResize"
        WindowStartupLocation="Manual"
        MinWidth="760" MinHeight="560"
        Width="1080" Height="760" FontFamily="Microsoft YaHei">

  <!-- 无边框窗口也要参与系统缩放：保留 10px 的可命中缩放边。 -->
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="0" ResizeBorderThickness="10"
                        GlassFrameThickness="0" CornerRadius="14"
                        UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>

  <!-- 资源必须写在内容之前：WPF 解析 XAML 是单趟顺序的，内容用到 StaticResource 时资源索引里必须已经有它 -->
  <Window.Resources>
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="BorderBrush" Value="__Border__"/>
      <Setter Property="BorderThickness" Value="2"/>
      <Setter Property="Foreground" Value="__Border__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WinBtnClose" TargetType="Button" BasedOn="{StaticResource WinBtn}"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="13,0"/>
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="Foreground" Value="__Border__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="sh" Background="__Shadow__" CornerRadius="7"
                      Margin="2,2,0,0"/>
              <Border x:Name="bd" Background="{TemplateBinding Background}"
                      BorderBrush="__Border__" BorderThickness="2" CornerRadius="7">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Margin" Value="2,2,0,0"/>
                <Setter TargetName="sh" Property="Opacity" Value="0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Background" Value="__AccentEvent__"/>
      <Setter Property="Foreground" Value="__OnAccent__"/>
    </Style>

    <Style x:Key="SegBtn" TargetType="Button">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="13,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="__InkSoft__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="0,0,0,2"
                    CornerRadius="0" Padding="2,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CalBtn" TargetType="Button">
      <Setter Property="Height" Value="34"/>
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="Foreground" Value="__Border__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="sh" Background="__Shadow__" CornerRadius="6" Margin="2,2,0,0"/>
              <Border x:Name="bd" Background="{TemplateBinding Background}"
                      BorderBrush="__Border__" BorderThickness="2" CornerRadius="6">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Margin" Value="2,2,0,0"/>
                <Setter TargetName="sh" Property="Opacity" Value="0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="__InkSoft__"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}"
                    CornerRadius="8" Padding="6,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ComboBox 必须自带模板。
         系统默认模板（Aero2）里那块底色是 StaticResource，不是 TemplateBinding，
         所以给 ComboBox.Background 赋值完全无效：夜间模式下就是"白底 + 白字"，
         整块下拉框在界面上等于消失。这里自带一套模板，颜色全部走主题占位符。
         用隐式样式（不写 x:Key）：主窗口里所有代码创建的 ComboBox 都会自动套上，
         不用逐个改造；对话框是独立的 Window，不会继承这里的资源。 -->
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="__Card__"/>
      <Setter Property="Foreground" Value="__Ink__"/>
      <Setter Property="BorderBrush" Value="__Border__"/>
      <Setter Property="BorderThickness" Value="2"/>
      <Setter Property="Padding" Value="7,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Name="PART_Toggle" Focusable="False" ClickMode="Press"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay,
                                        RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="bd" CornerRadius="4"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center"
                            Margin="0,0,7,0" Data="M0,0 L8,0 L4,5 Z"
                            Fill="__InkSoft__"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="bd" Property="Background" Value="__CardAlt__"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Name="PART_Content" IsHitTestVisible="False"
                                Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Left" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"/>
              <!-- PART_EditableTextBox：模板里没有这块的话，IsEditable=True 的下拉框
                   （对话框里那几个既可选又可手输的字段）压根显示不出输入内容。 -->
              <TextBox Name="PART_EditableTextBox" Visibility="Collapsed"
                       IsReadOnly="{TemplateBinding IsReadOnly}"
                       Margin="{TemplateBinding Padding}"
                       HorizontalAlignment="Stretch" VerticalAlignment="Center"
                       Background="Transparent" BorderThickness="0"
                       Foreground="{TemplateBinding Foreground}"
                       CaretBrush="{TemplateBinding Foreground}"/>
              <Popup Name="PART_Popup" Placement="Bottom" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="280"
                        Background="__Card__" BorderBrush="__Border__"
                        BorderThickness="2" CornerRadius="5" Margin="0,2,0,0">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel IsItemsHost="True"
                                KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_Content" Property="Visibility" Value="Collapsed"/>
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- 下拉项：默认模板同样是写死的白底，夜里会出现"白条 + 白字" -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="__Ink__"/>
      <Setter Property="Padding" Value="7,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="bd" CornerRadius="3"
                    Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__AccentFocus__"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="__AccentFocus__"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="OuterRing" Background="__Backdrop__" CornerRadius="14" Padding="0">
   <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="42"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- 标题栏（可拖动） -->
    <Border x:Name="TitleBar" Grid.Row="0" Background="__Chrome__"
            CornerRadius="14,14,0,0" BorderThickness="2,2,2,0" BorderBrush="__Border__">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="10,0,0,0"
                    VerticalAlignment="Center">
          <Border Width="12" Height="12" CornerRadius="3" Background="__AccentEvent__"
                  BorderThickness="2" BorderBrush="__Border__"/>
          <TextBlock x:Name="WinTitle" Text="Main window - Month view"
                     Margin="10,0,0,0" VerticalAlignment="Center"
                     Foreground="__Ink__" FontSize="13" FontWeight="SemiBold"/>
        </StackPanel>
        <TextBlock Grid.Column="1" Text="" />

        <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,8,0"
                    VerticalAlignment="Center">
          <Button x:Name="BtnMore" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtn}" ToolTip="More options">
            <Border x:Name="IcMore" Width="14" Height="14" VerticalAlignment="Center"/></Button>
          <Button x:Name="BtnMin" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtn}">
            <Border x:Name="IcMin" Width="10" Height="10" VerticalAlignment="Center"/></Button>
          <Button x:Name="BtnMax" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtn}">
            <Border x:Name="IcMax" Width="10" Height="10" VerticalAlignment="Center"/></Button>
          <Button x:Name="BtnClose" Width="28" Height="24" Margin="4,0,0,0"
                  Style="{StaticResource WinBtnClose}">
            <Border x:Name="IcClose" Width="10" Height="10" VerticalAlignment="Center"/></Button>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 主体 -->
    <Border x:Name="MainPanel" Grid.Row="1" Background="__Panel__"
            CornerRadius="0,0,14,14" BorderThickness="2,0,2,2" BorderBrush="__Border__">
     <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="NavCol" Width="142"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- 左侧导航 -->
      <Border x:Name="NavPanel" Grid.Column="0" Background="__Card__"
              BorderThickness="0,0,2,0" BorderBrush="__BorderSoft__">
       <!-- 两行：导航（可滚动）/ DAILY NOTE（固定）。
            历史：曾把 7 个入口拆成"主导航 + 次导航"两块固定高度区，想让多余高度落在
              两块之间显得像刻意排布。实际效果相反 —— 窗口一拉高，两块之间那条空隙
              看起来就是"上下脱节"，用户第一眼就报了这个。
            现在：Month/Week/List/Tasks/Focus/Settings/Profile 全部回到同一个
              StackPanel（唯一滚动容器），多余高度统一落在整个导航组的下方，
              导航自身始终是连续的一整列；窗口很矮时滚动依然是唯一出路，
              且底部 DAILY NOTE 固定不动。
            用 Grid 而不是 DockPanel：DockPanel 只有"最后一个子项"能填充剩余空间，
              而需要填充的是排在最前面的导航区，Dock 顺序会把它错挤到左边。 -->
       <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <!-- 导航放进 ScrollViewer：窗口变矮时它可滚动，而 DAILY NOTE 固定块始终完整可见
             （挤不下就裁掉是不可接受的）。 -->
        <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="10,14,10,0">
          <Border x:Name="AvatarBox" Width="82" Height="82" HorizontalAlignment="Center"
                  CornerRadius="8" BorderThickness="2" BorderBrush="__Border__"
                  Background="__CardAlt__" Cursor="Hand"
                  ToolTip="Click to choose your own avatar image">
            <Grid>
              <Canvas x:Name="AvatarCanvas" Width="82" Height="82" ClipToBounds="True"/>
              <Image x:Name="AvatarImage" Stretch="UniformToFill" ClipToBounds="True"/>
              <Border x:Name="AvatarHintBox" VerticalAlignment="Bottom" Background="__Card__"
                      Opacity="0.88" Padding="3,1">
                <TextBlock x:Name="AvatarHint" Text="Change" FontSize="9"
                           HorizontalAlignment="Center" Foreground="__InkSoft__"/>
              </Border>
            </Grid>
          </Border>

          <Button x:Name="BtnAdd" Style="{StaticResource PrimaryBtn}" Height="36" Margin="0,12,0,4">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="IcAdd" Width="14" Height="14" VerticalAlignment="Center"/>
              <TextBlock Text="New event" Margin="6,0,0,0"/></StackPanel></Button>

          <Button x:Name="NavMonth" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="month">
            <StackPanel><Border x:Name="IcNavMonth" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Month" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavWeek" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="week">
            <StackPanel><Border x:Name="IcNavWeek" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Week" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavList" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="list">
            <StackPanel><Border x:Name="IcNavList" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="List" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Border Height="2" Background="__BorderSoft__" Margin="6,10,6,0" Opacity="0.6"/>

          <Button x:Name="NavTask" Style="{StaticResource NavBtn}" Margin="0,10,0,0" Tag="tasks">
            <StackPanel><Border x:Name="IcNavTask" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Tasks" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavFocus" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="focus">
            <StackPanel><Border x:Name="IcNavFocus" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Focus" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavSettings" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="settings">
            <StackPanel><Border x:Name="IcNavSettings" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Settings" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>
          <Button x:Name="NavProfile" Style="{StaticResource NavBtn}" Margin="0,4,0,0" Tag="profile">
            <StackPanel><Border x:Name="IcNavProfile" Width="19" Height="19"
                        HorizontalAlignment="Center" Margin="0,0,0,3"/>
              <TextBlock Text="Profile" FontSize="10" HorizontalAlignment="Center"/></StackPanel>
          </Button>

          <!-- 导航到此结束。多出来的高度落在这行空白上 —— 空白处在整列导航的
               "下方"，而不是插在两组按钮中间，所以视觉上永远是一整列。 -->
          <Border Height="0" Background="Transparent" Margin="0,10,0,6"/>
        </StackPanel>
        </ScrollViewer>

        <StackPanel Grid.Row="1" VerticalAlignment="Bottom" Margin="10,0,10,12">
          <Border Height="2" Background="__BorderSoft__" Margin="0,0,0,8" Opacity="0.6"/>
          <TextBlock Text="DAILY NOTE" FontSize="9" Foreground="__InkFaint__"
                     HorizontalAlignment="Center" FontFamily="Consolas"/>
          <Border Height="4" Background="__Border__" CornerRadius="2" Margin="0,5,0,0"/>
          <Border Height="4" Background="__Shadow__" CornerRadius="2"
                  Margin="0,3,14,0" HorizontalAlignment="Left" Width="70"/>
        </StackPanel>
       </Grid>
      </Border>

      <!-- 右侧主区 -->
      <Grid Grid.Column="1">
       <Grid.RowDefinitions>
         <RowDefinition Height="Auto"/>
         <RowDefinition Height="Auto"/>
         <RowDefinition Height="*"/>
       </Grid.RowDefinitions>

       <!-- 信息头（番茄钟已整体挪到左侧栏，这里只留日期与统计） -->
       <StackPanel Grid.Row="0" Margin="14,6,14,8" VerticalAlignment="Top">
         <TextBlock x:Name="HeroDate" Text="" FontSize="15"
                    Foreground="__InkFaint__"/>
         <TextBlock x:Name="HeroStats" Text="" FontSize="14" Margin="0,2,0,0"
                    Foreground="__InkSoft__"/>
       </StackPanel>

       <!-- 日历导航条 -->
       <DockPanel Grid.Row="1" Margin="14,0,14,0" VerticalAlignment="Top"
                  x:Name="CalBar" Height="34">
         <!-- 顺序：上一页 / This week（本期按钮）/ 下一页 —— 本期按钮夹在左右翻页键中间 -->
         <Button x:Name="BtnPrev" DockPanel.Dock="Left" Style="{StaticResource CalBtn}" Width="34"
                 ToolTip="Previous">
           <Border x:Name="IcPrev" Width="12" Height="12" VerticalAlignment="Center"/></Button>
         <Button x:Name="BtnThis" DockPanel.Dock="Left" Style="{StaticResource CalBtn}"
                 Width="118" Margin="7,0,0,0" ToolTip="Jump back to the current period">
           <TextBlock x:Name="CalLabel" Text="This month" FontSize="11"/></Button>
         <Button x:Name="BtnNext" DockPanel.Dock="Left" Style="{StaticResource CalBtn}"
                 Width="34" Margin="7,0,0,0" ToolTip="Next">
           <Border x:Name="IcNext" Width="12" Height="12" VerticalAlignment="Center"/></Button>
         <TextBlock x:Name="CalNote" DockPanel.Dock="Right" VerticalAlignment="Center"
                    FontSize="12" Foreground="__Holiday__" Margin="8,0,0,0"/>
         <TextBlock x:Name="CalPeriod" Text="" FontSize="20" FontWeight="Bold"
                    VerticalAlignment="Center" Margin="12,0,0,0" Foreground="__Ink__"/>
         <TextBlock Text=""/>
       </DockPanel>

       <!-- 视图容器 + 覆盖层（同格叠放，后加的即覆盖层，永远在最上面） -->
       <Grid Grid.Row="2" Margin="14,10,14,3" ClipToBounds="False">
         <Grid x:Name="ViewHost" Margin="0"/>
         <Canvas x:Name="UiOverlay" Background="{x:Null}"/>
       </Grid>
      </Grid>
     </Grid>
    </Border>
   </Grid>
  </Border>

</Window>
"@

# ---------------------------------------------------------------------------
#  B. 主题 XAML 替换
# ---------------------------------------------------------------------------
function ConvertTo-ThemeXaml {
    param([string]$Xaml, [string]$Theme)
    $map = $script:PaletteLight
    if ($Theme -eq 'night') { $map = $script:PaletteNight }
    $out = $Xaml
    foreach ($k in $map.Keys) {
        $out = $out.Replace("__$k" + "__", [string]$map[$k])
    }
    return $out
}

# ---------------------------------------------------------------------------
#  C. 运行时主题回放（切换主题时重建界面）
#     像素 WPF 的可靠做法：整窗重建，避免逐元素回放的遗漏
# ---------------------------------------------------------------------------
function Set-Theme {
    param([string]$Theme, [switch]$Sync)
    $script:Theme = $Theme
    $script:Settings['Theme'] = $Theme
    $script:NightMode = ($Theme -eq 'night')

    if ($Sync) {
        # 测试/回归用：同步重建。BeginInvoke(Background) 排队的话，测试脚本
        # 在同一次回调里就截图了，拍到的是旧皮肤。
        Rebuild-Window
        return
    }
    # 让 Dispatcher 处理完当前消息后重建窗口
    $script:MainWindow.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [action]{ Rebuild-Window }) | Out-Null
}

function Rebuild-Window {
    # 主题切换 = 重建内容树，但【不重建 Window 对象】。
    #
    # 为什么不重建 Window：实测（见 verification/_trc7/_trc8 的 trace），
    # 只要 Application.Windows 里已经有过窗口，新 Build 出来的 Window 再 Show()
    # 就会静默失败 —— 无异常、IsLoaded 恒为 false、ActualWidth 恒 0，窗口永远
    # 出不来；把旧窗口先 Close 再 Show 也一样，甚至第一次重建都会失败。
    # 这条路走不通，而且逐元素回放颜色又容易漏。
    #
    # 所以：Build-Window 照常把整棵新树建好（颜色/处理器都是新的），
    # 然后把它的 Content 搬进【现有的窗口对象】。窗口位置/尺寸/置顶全部自然保留，
    # 也不会闪屏。Window 级的生命周期钩子（Closing/Closed）挂在旧窗口上，继续有效。
    try {
        $script:Rebuilding = $true
        Build-Window
        Refresh-All
    } catch { Write-ErrLog ('Rebuild-Window: ' + $_.Exception.Message) }
    finally { $script:Rebuilding = $false }
}

# ---------------------------------------------------------------------------
#  D. 像素头像（Canvas 绘制，避免外部图片依赖）
# ---------------------------------------------------------------------------
function Draw-Avatar {
    param($Canvas)
    $Canvas.Children.Clear()
    $art = @(
        '...hhhhhh....', '..hHHHHHHh...', '.hHHkkkHHHh..', '.hHkkkkkHHh..',
        '.hHssssssHh..', '.hHseeseeSh..', '.hHsbbssbSh..', '..hSssssSs...',
        '...rrrrrr....', '..cccccccc...', '.cccccccccc..', '.ccCccccCcc..',
        '..cc....cc...', '..ss....ss...'
    )
    # 取色：字符表里的大写字母统一映射到小写键（PS 哈希键大小写不敏感，
    # 写 h 和 H 会直接判成重复键，整个脚本解析失败）
    $map = @{ 'h' = 'h'; 'x' = 'x'; 'k' = 'k'; 's' = 's'; 'e' = 'e'; 'b' = 'b'; 'c' = 'c'; 'r' = 'r' }
    foreach ($big in @('H', 'S', 'C')) { $map[$big] = $map[$big.ToLower()] }
    if ($script:Theme -eq 'night') {
        $P = @{
            h = '#4A2E36'; x = '#65404A'; k = '#8A5C66'
            s = '#C9A292'; e = '#1A1116'; b = '#B4707E'
            c = '#3A2A32'; r = '#A85A6C'
        }
    } else {
        $P = @{
            h = '#7A4A52'; x = '#9C6068'; k = '#C98A90'
            s = '#E8BDA9'; e = '#3A2A30'; b = '#E08A9A'
            c = '#FDF4F2'; r = '#C05A6C'
        }
    }
    $cell = [double]$Canvas.Width / 14.0
    for ($y = 0; $y -lt 14; $y++) {
        $row = $art[$y]
        for ($x = 0; $x -lt 14; $x++) {
            $chRaw = [string]$row[$x]
            if (-not $map.ContainsKey($chRaw)) { continue }
            $ch = [string]$map[$chRaw]
            if (-not $P.ContainsKey($ch)) { continue }
            $r = New-Object System.Windows.Shapes.Rectangle
            $r.Width = [math]::Ceiling($cell)
            $r.Height = [math]::Ceiling($cell)
            $r.Fill = (Brush $P[$ch])
            [System.Windows.Controls.Canvas]::SetLeft($r, [double]($x * $cell))
            [System.Windows.Controls.Canvas]::SetTop($r, [double]($y * $cell))
            [void]$Canvas.Children.Add($r)
        }
    }
}

function New-AvatarBitmap {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $uri = [System.Uri]::new([System.IO.Path]::GetFullPath($Path))
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = $uri
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.DecodePixelWidth = 512
        $bmp.EndInit()
        $bmp.Freeze()
        return $bmp
    } catch {
        Write-ErrLog ('New-AvatarBitmap: ' + $_.Exception.Message)
        return $null
    }
}

function Set-AvatarElement {
    param($Image, $Canvas, $Hint, $HintBox, [string]$Path)
    if ($null -eq $Image -or $null -eq $Canvas) { return $false }
    $bmp = New-AvatarBitmap $Path
    if ($null -ne $bmp) {
        $Image.Source = $bmp
        $Image.Visibility = 'Visible'
        $Canvas.Visibility = 'Collapsed'
        if ($null -ne $HintBox) { $HintBox.Visibility = 'Collapsed' }
        if ($null -ne $Hint) { $Hint.Text = '' }
        return $true
    }
    $Image.Source = $null
    $Image.Visibility = 'Collapsed'
    $Canvas.Visibility = 'Visible'
    if ($null -ne $HintBox) { $HintBox.Visibility = 'Visible' }
    if ($null -ne $Hint) { $Hint.Text = 'Change' }
    return $false
}

function Apply-AvatarImage {
    param([string]$Path = '', [switch]$Store)
    $ok = Set-AvatarElement -Image $script:AvatarImage -Canvas $script:AvatarCanvas `
        -Hint $script:AvatarHint -HintBox $script:AvatarHintBox -Path $Path
    if (-not $ok -and $Store) {
        $script:Settings['AvatarPath'] = ''
        Save-Settings
    } elseif ($ok -and $Store) {
        $script:Settings['AvatarPath'] = $Path
        Save-Settings
    }
    return $ok
}

# ---------------------------------------------------------------------------
#  E. 描边图标（24x24 网格）
#
#  网页版原型的图标是一组 24x24 viewBox 的 SVG 描边路径。这里把同样的路径
#  数据搬到 WPF：外层 Viewbox 负责缩放到目标尺寸，内层 Canvas 用 24x24 坐标。
#  这样图标是矢量重绘的、零图片依赖，换主题时只要重画一次即可。
# ---------------------------------------------------------------------------
$script:IconDefs = @{
    month = @(
        @{ k = 'rect'; x = 3; y = 5; w = 18; h = 16; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M3 10h18M8 3v4M16 3v4'; sw = 2 },
        @{ k = 'path'; d = 'M7 14h.01M12 14h.01M17 14h.01M7 18h.01M12 18h.01M17 18h.01'; sw = 2 }
    )
    week = @(
        @{ k = 'rect'; x = 3; y = 5; w = 18; h = 16; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M3 10h18M8 3v4M16 3v4'; sw = 2 },
        @{ k = 'rect'; x = 6; y = 13; w = 3; h = 5; r = 1; fill = $true },
        @{ k = 'rect'; x = 10.5; y = 13; w = 3; h = 5; r = 1; fill = $true },
        @{ k = 'rect'; x = 15; y = 13; w = 3; h = 5; r = 1; fill = $true }
    )
    list = @(
        @{ k = 'path'; d = 'M8 6h13M8 12h13M8 18h13'; sw = 2 },
        @{ k = 'path'; d = 'M3.5 6h.01M3.5 12h.01M3.5 18h.01'; sw = 2 }
    )
    tasks = @(
        @{ k = 'rect'; x = 4; y = 3; w = 16; h = 18; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M8 9l2 2 4-4M8 16h6'; sw = 2 }
    )
    timer = @(
        @{ k = 'circle'; cx = 12; cy = 13; r = 8; sw = 2 },
        @{ k = 'path'; d = 'M12 9v4l3 2M9 2h6M12 2v3'; sw = 2 }
    )
    image = @(
        @{ k = 'rect'; x = 3; y = 4; w = 18; h = 16; r = 2; sw = 2 },
        @{ k = 'circle'; cx = 9; cy = 9; r = 2; sw = 2 },
        @{ k = 'path'; d = 'M4 18l5-5 4 4 3-3 4 4'; sw = 2 }
    )
    settings = @(
        @{ k = 'circle'; cx = 12; cy = 12; r = 3; sw = 2 },
        @{ k = 'path'; d = 'M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M19 5l-2 2M7 17l-2 2'; sw = 2 }
    )
    profile = @(
        @{ k = 'circle'; cx = 12; cy = 8; r = 4; sw = 2 },
        @{ k = 'path'; d = 'M4 21c0-4 3.6-6 8-6s8 2 8 6'; sw = 2 }
    )
    plus = @(
        @{ k = 'path'; d = 'M12 5v14M5 12h14'; sw = 2.8 }
    )
    pin = @(
        @{ k = 'path'; d = 'M15 3l6 6-3 1-4 4 1 5-3-3-6 6'; sw = 2 },
        @{ k = 'path'; d = 'M9 9l-5 5 6 1'; sw = 2 }
    )
    moon = @(
        # SVG 原文 "A8.5 8.5 0 019.5 4" 省略了分隔符，WPF 解析器不容忍，这里补全
        @{ k = 'path'; d = 'M20,14.5 A8.5,8.5 0 0 1 9.5,4 A8.5,8.5 0 1 0 20,14.5 z'; sw = 2 },
        @{ k = 'path'; d = 'M4 4l1.5 1.5M17 2v2M21 19h2'; sw = 2; dim = $true }
    )
    sun = @(
        @{ k = 'circle'; cx = 12; cy = 12; r = 4; sw = 2 },
        @{ k = 'path'; d = 'M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19'; sw = 2 }
    )
    more = @(
        @{ k = 'circle'; cx = 5; cy = 12; r = 2; fill = $true },
        @{ k = 'circle'; cx = 12; cy = 12; r = 2; fill = $true },
        @{ k = 'circle'; cx = 19; cy = 12; r = 2; fill = $true }
    )
    collapse = @(
        @{ k = 'path'; d = 'M6 15l6-6 6 6'; sw = 2.5 }
    )
    chevL = @(
        @{ k = 'path'; d = 'M15 6l-6 6 6 6'; sw = 3 }
    )
    chevR = @(
        @{ k = 'path'; d = 'M9 6l6 6-6 6'; sw = 3 }
    )
    search = @(
        @{ k = 'circle'; cx = 11; cy = 11; r = 7; sw = 2.2 },
        @{ k = 'path'; d = 'M20 20l-4-4'; sw = 2.2 }
    )
    check = @(
        @{ k = 'path'; d = 'M4 12.5l5 5L20 7'; sw = 3.5 }
    )
    min = @(
        @{ k = 'path'; d = 'M5 12h14'; sw = 3 }
    )
    max = @(
        @{ k = 'rect'; x = 4; y = 4; w = 16; h = 16; r = 1.5; sw = 2.5 }
    )
    close = @(
        @{ k = 'path'; d = 'M6 6l12 12M18 6L6 18'; sw = 3 }
    )
    doc = @(
        @{ k = 'path'; d = 'M6 3h8l5 5v13H6z'; sw = 2 },
        @{ k = 'path'; d = 'M14 3v5h5'; sw = 2 }
    )
    trash = @(
        @{ k = 'path'; d = 'M4 7h16M9 7V5h6v2M6 7l1 14h10l1-14'; sw = 2 }
    )
}

function New-Icon {
    param([string]$Name, [int]$Size = 18, [string]$Color = '')
    if (-not $script:IconDefs.ContainsKey($Name)) { return $null }
    $col = $Color
    if ([string]::IsNullOrWhiteSpace($col)) { $col = Get-Pal 'Ink' }
    $brush = Brush $col

    $cv = New-Object System.Windows.Controls.Canvas
    $cv.Width = 24; $cv.Height = 24

    foreach ($spec in $script:IconDefs[$Name]) {
        # 合并默认值：StrictMode 下直接读缺失的哈希键容易出岔子，先补齐
        $s = @{ sw = 2.0; fill = $false; dim = $false }
        foreach ($k in $spec.Keys) { $s[$k] = $spec[$k] }

        $sh = New-Object System.Windows.Shapes.Path
        switch ([string]$s['k']) {
            'path' { $sh.Data = [System.Windows.Media.Geometry]::Parse([string]$s['d']) }
            'rect' {
                $g = New-Object System.Windows.Media.RectangleGeometry
                $g.Rect = New-Object System.Windows.Rect(
                    [double]$s['x'], [double]$s['y'], [double]$s['w'], [double]$s['h'])
                $g.RadiusX = [double]$s['r']; $g.RadiusY = [double]$s['r']
                $sh.Data = $g
            }
            'circle' {
                $g = New-Object System.Windows.Media.EllipseGeometry
                $g.Center = New-Object System.Windows.Point([double]$s['cx'], [double]$s['cy'])
                $g.RadiusX = [double]$s['r']; $g.RadiusY = [double]$s['r']
                $sh.Data = $g
            }
            default { continue }
        }

        if ([bool]$s['fill']) {
            $sh.Fill = $brush
        } else {
            $sh.Stroke = $brush
            $sh.StrokeThickness = [double]$s['sw']
        }
        $sh.StrokeStartLineCap = 'Round'
        $sh.StrokeEndLineCap = 'Round'
        $sh.StrokeLineJoin = 'Round'
        if ([bool]$s['dim']) { $sh.Opacity = 0.6 }
        [void]$cv.Children.Add($sh)
    }

    $vb = New-Object System.Windows.Controls.Viewbox
    $vb.Width = $Size; $vb.Height = $Size
    $vb.Stretch = 'Uniform'
    $vb.Child = $cv
    return $vb
}

# 把图标画进一个占位 Border（XAML 里只放空 Border，尺寸由 XAML 决定）
# 参数名不能叫 $Host：那是只读自动变量，绑定参数时会抛异常。
function Draw-Icon {
    param($Target, [string]$Name, [int]$Size = 18, [string]$Color = '')
    if ($null -eq $Target) { return }
    $ic = New-Icon -Name $Name -Size $Size -Color $Color
    if ($null -eq $ic) { return }
    $Target.Child = $ic
}

# 一次性把窗口里所有图标占位符画满。主题重建时会再调一次。
function Draw-AllIcons {
    param($N)
    $defs = @(
        @{ host = 'IcNavMonth';    icon = 'month' },
        @{ host = 'IcNavWeek';     icon = 'week' },
        @{ host = 'IcNavList';     icon = 'list' },
        @{ host = 'IcNavTask';     icon = 'tasks' },
        @{ host = 'IcNavFocus';    icon = 'timer' },
        @{ host = 'IcNavSettings'; icon = 'settings' },
        @{ host = 'IcNavProfile';  icon = 'profile' },
        @{ host = 'IcViewMonth';   icon = 'month' },
        @{ host = 'IcViewWeek';    icon = 'week' },
        @{ host = 'IcViewList';    icon = 'list' },
        @{ host = 'IcAdd';         icon = 'plus' },
        @{ host = 'IcFocusMenu';   icon = 'timer' },
        @{ host = 'IcPin';         icon = 'pin' },
        @{ host = 'IcTheme';       icon = $(if ($script:NightMode) { 'sun' } else { 'moon' }) },
        @{ host = 'IcMore';        icon = 'more' },
        @{ host = 'IcCollapse';    icon = 'collapse' },
        @{ host = 'IcPrev';        icon = 'chevL' },
        @{ host = 'IcNext';        icon = 'chevR' },
        @{ host = 'IcMin';         icon = 'min' },
        @{ host = 'IcMax';         icon = 'max' },
        @{ host = 'IcClose';       icon = 'close' }
    )
    foreach ($d in $defs) {
        # 注意：变量不能叫 $host —— 那是 PowerShell 的只读自动变量（宿主对象），
        # 赋值会直接抛 "无法覆盖变量 Host，因为该变量为只读变量或常量"。
        $slot = $N[$d['host']]
        if ($null -eq $slot) { continue }
        Draw-Icon -Target $slot -Name $d['icon'] -Size ([int]$slot.Width)
    }
}

