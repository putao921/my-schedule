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
          <!-- 撤销反馈条（第六轮）：Ctrl+Z 撤销后在这里报"还能撤几次"，
               栈空时提示"没有可撤销的操作了"。默认空字符串 -> 不占视觉重量；
               有内容时不换行、淡色，不抢导航的注意力。 -->
          <TextBlock x:Name="UndoHint" Text="" FontSize="10" Foreground="__InkFaint__"
                     HorizontalAlignment="Center" TextWrapping="Wrap" TextAlignment="Center"
                     Margin="0,0,0,6"/>
          <Border Height="2" Background="__BorderSoft__" Margin="0,0,0,8" Opacity="0.6"/>
          <!-- 第十二轮（item 3）：原"每日一句 + 两条横线"改为工具作者 + 最新更新时间。
               文字在 Apply-Lang 里按语言表刷（about.author / about.updated）。 -->
          <TextBlock x:Name="AuthorLabel" Text="" FontSize="10" Foreground="__InkSoft__"
                     HorizontalAlignment="Center" FontWeight="SemiBold"/>
          <TextBlock x:Name="UpdateLabel" Text="" FontSize="9" Foreground="__InkFaint__"
                     HorizontalAlignment="Center" Margin="0,3,0,0"/>
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

       <!-- 信息头（第十四轮重构：三个像素风"胶囊"替代原来的两行灰字）
            左：日期 + 时钟（时钟用等宽字体、强调色，一眼看到"现在"）
            中：已完成 n/m + 迷你进度条（条色由代码按色板刷，跟随主题）
            右：今日专注时长
            HeroStats 名字给中间+右侧这组：窄窗口 (<820px) 整组收起，日期胶囊保留 -->
       <DockPanel Grid.Row="0" Margin="14,8,14,4" VerticalAlignment="Top" LastChildFill="False">
         <Border DockPanel.Dock="Left" Background="__CardAlt__" BorderBrush="__Border__"
                 BorderThickness="2" CornerRadius="8" Padding="12,4,12,4" VerticalAlignment="Center">
           <StackPanel Orientation="Horizontal">
             <TextBlock x:Name="HeroDate" Text="" FontSize="13" FontWeight="SemiBold"
                        Foreground="__Ink__" VerticalAlignment="Center"/>
             <TextBlock x:Name="HeroClock" Text="" FontSize="13" FontFamily="Consolas" FontWeight="Bold"
                        Foreground="__AccentEvent__" VerticalAlignment="Center" Margin="10,0,0,0"/>
           </StackPanel>
         </Border>
         <StackPanel x:Name="HeroStats" DockPanel.Dock="Left" Orientation="Horizontal"
                     Margin="8,0,0,0" VerticalAlignment="Center">
           <Border Background="__CardAlt__" BorderBrush="__Border__" BorderThickness="2"
                   CornerRadius="8" Padding="12,4,12,4">
             <StackPanel Orientation="Horizontal">
               <TextBlock x:Name="HeroDone" Text="" FontSize="12"
                          Foreground="__InkSoft__" VerticalAlignment="Center"/>
               <Border x:Name="HeroBarTrack" Width="72" Height="9" Background="__Card__"
                       BorderBrush="__Border__" BorderThickness="1" CornerRadius="4"
                       VerticalAlignment="Center" Margin="10,0,0,0">
                 <Border x:Name="HeroBarFill" HorizontalAlignment="Left" CornerRadius="3"/>
               </Border>
             </StackPanel>
           </Border>
           <Border Background="__CardAlt__" BorderBrush="__Border__" BorderThickness="2"
                   CornerRadius="8" Padding="12,4,12,4" Margin="8,0,0,0">
             <TextBlock x:Name="HeroFocus" Text="" FontSize="12"
                        Foreground="__InkSoft__" VerticalAlignment="Center"/>
           </Border>
         </StackPanel>
       </DockPanel>

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
        # 第十四轮（item 4）：主题跟随 —— 换肤后悬浮窗整窗按新色板重建。
        # 放在 finally 之前：重建主窗无论成败，悬浮窗都要跟上（它自己有兜底）。
        try { Refresh-PomoMiniTheme } catch { }
    } catch { Write-ErrLog ('Rebuild-Window: ' + $_.Exception.Message) }
    finally { $script:Rebuilding = $false }
}

# ---------------------------------------------------------------------------
#  D. 像素头像（Canvas 绘制，避免外部图片依赖）
# ---------------------------------------------------------------------------
# ===========================================================================
#  内嵌默认头像（第十四轮）：打招呼的小女孩（128x128 PNG，base64）。
#  替代原 Draw-Avatar 像素小人成为出厂默认头像；托盘图标复用同一份资源。
#  为什么内嵌而不带文件：保持绿色包 = 5 个 ps1、零外部资源的现状，
#  换电脑 / 打 exe 都不会出现「图标找不到」。
# ===========================================================================
$script:DefaultAvatarB64 = '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'

function New-DefaultAvatarBitmap {
    # 从内嵌 base64 解码出默认头像的 BitmapImage。
    try {
        $bytes = [System.Convert]::FromBase64String($script:DefaultAvatarB64)
        $ms = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.StreamSource = $ms
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        $ms.Dispose()
        return $bmp
    } catch {
        Write-ErrLog ('New-DefaultAvatarBitmap: ' + $_.Exception.Message)
        return $null
    }
}

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
    # 优先用户头像；为空或加载失败时回退到内嵌默认头像（小女孩，第十四轮）。
    # 返回值只表达「是否成功加载了用户提供的图片」：默认头像不算用户图片，
    # 这样 Apply-AvatarImage 在用户图加载失败时能正确清空 AvatarPath（回默认）。
    $userBmp = New-AvatarBitmap $Path
    $bmp = $userBmp
    if ($null -eq $bmp) { $bmp = New-DefaultAvatarBitmap }
    if ($null -ne $bmp) {
        $Image.Source = $bmp
        $Image.Visibility = 'Visible'
        $Canvas.Visibility = 'Collapsed'
        if ($null -ne $HintBox) { $HintBox.Visibility = 'Collapsed' }
        if ($null -ne $Hint) { $Hint.Text = '' }
        return ($null -ne $userBmp)
    }
    $Image.Source = $null
    $Image.Visibility = 'Collapsed'
    $Canvas.Visibility = 'Visible'
    if ($null -ne $HintBox) { $HintBox.Visibility = 'Visible' }
    if ($null -ne $Hint) { $Hint.Text = (Get-LangText 'av.change') }
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

