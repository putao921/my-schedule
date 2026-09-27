# -*- coding: utf-8 -*-
"""
Generate platform-neutral front-end assets from the single source of truth.

  design/tokens.json  ->  web/css/tokens.css   (CSS custom properties)
  design/lang.json    ->  web/js/i18n.js       (UI string bundle)

Both outputs are DERIVED. Never hand-edit them; edit the JSON and re-run.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESIGN = os.path.join(ROOT, "design")
WEB = os.path.join(ROOT, "web")


def load(name):
    with open(os.path.join(DESIGN, name), encoding="utf-8") as f:
        return json.load(f)


# Strings that exist only in the web client (cloud sync / install). They are
# kept here rather than in lang.json so that file stays a faithful export of
# the desktop app; regeneration cannot lose them because they are merged in.
WEB_EXTRA = {
    "en": {
        "sync.title": "Sync",
        "sync.signin": "Sign in",
        "sync.signup": "Sign up",
        "sync.upload": "Upload",
        "sync.download": "Download",
        "sync.signout": "Sign out",
        "sync.export": "Export",
        "sync.import": "Import",
        "sync.toggle": "Switch",
        "sync.notSignedIn": "not signed in",
        "sync.localOnly": "this device only",
        "sync.cloudOn": "cloud sync on",
        "sync.tabPassword": "Password",
        "sync.tabOtp": "Email code",
        "sync.tabSignup": "Sign up",
        "sync.tabReset": "Forgot",
        "sync.email": "Email",
        "sync.password": "Password",
        "sync.newPassword": "New password",
        "sync.code": "Code from email",
        "sync.getCode": "Get code",
        "sync.sendReset": "Send reset code",
        "sync.cancel": "Cancel",
        "sync.go": "OK",
        "sync.close": "Close",
        "sync.firstHint": "No account yet? Open the Sign up tab.",
        "sync.warnLocal": "Sign-in only works on the published HTTPS domain. "
                          "This is a local preview, so data stays on this device.",
        "sync.enterEmail": "enter your email first",
        "sync.codeSent": "code sent - check your inbox",
        "sync.resetSent": "reset code sent",
        "sync.wrong": "wrong email or password",
        "sync.needCode": "tap Get code for this email first",
        "sync.needResetCode": "send a reset code to this email first",
        "sync.pwdUpdated": "password updated",
        "sync.signedIn": "signed in",
        "sync.signedOut": "signed out",
        "sync.uploaded": "uploaded",
        "sync.downloaded": "downloaded from cloud",
        "sync.noCloud": "no cloud copy yet",
        "sync.badCloud": "cloud copy looks invalid",
        "sync.sdkMissing": "cloud component did not load",
        "sync.couldNotSend": "could not send",
        "sync.uploadFailed": "upload failed",
        "sync.downloadFailed": "download failed",
        "sync.nothingWritten": "nothing written - check sign-in",
        "sync.keptLocal": "This device has data. Use Upload to send it to the "
                          "cloud, or Download to overwrite it with the cloud copy.",
        "sync.tookCloud": "loaded your cloud data",
        "sync.offline": "offline",

        # Timer (rest of the pomo.* set already comes from the desktop app).
        "pomo.start": "Start",
        "pomo.ready": "Ready",
        "pomo.logged": "minutes logged",
        "pomo.hint": "The timer keeps running while you use other tabs.",
        "nav.focus": "Focus",

        # Search.
        "search.toggle": "Search",
        "search.none": "Nothing matches that search",

        # Settings.
        "set.appearance": "Appearance",
        "set.pomoMin": "Focus minutes",
        "set.breakMin": "Break minutes",
        "set.tags": "Tags",
        "set.tagsHint": "rename / recolour / add",
        "set.tagAdd": "Add tag",
        "set.saved": "saved",
        "av.choose": "Choose image",
        "av.reset": "Reset",

        # Navigation for the two web-only views.
        "nav.today": "Today",
        "nav.stats": "Stats",

        # Today view.
        "today.evDone": "events done",
        "today.focus": "focus today",
        "today.due": "due today",
        "today.overdue": "Overdue",
        "today.events": "Today's schedule",
        "today.dueToday": "Tasks due today",
        "today.evEmpty": "Nothing scheduled today",
        "today.dueEmpty": "Nothing due today",
        "today.stats": "Open stats",
        "today.lateDays": "{0}d late",

        # Stats view.
        "st.focusWeek": "focus this week",
        "st.evWeek": "events done / planned",
        "st.streak": "day focus streak",
        "st.taskDone": "tasks done",
        "st.focus7": "Focus, last 7 days",
        "st.ev7": "Events, last 7 days",
        "st.minutes": "minutes",
        "st.byTag": "Events by tag",
        "st.noData": "No data yet",

        # Pomodoro queue.
        "pomo.queue": "Task queue",
        "pomo.queueAdd": "Add",
        "pomo.queueNow": "Now",
        "pomo.queueClear": "Clear queue",
        "pomo.queueEmpty": "no queued tasks - add one to chain them",

        # Custom festivals.
        "set.holidays": "Festivals",
        "set.holidaysHint": "add your own dates",
        "hol.date": "Date",
        "hol.name": "Name",
        "hol.add": "Add festival",
        "hol.none": "none yet",
        "hol.needBoth": "pick a date and a name first",

        # Leftover English strings found during the feature round.
        "fld.ed.note": "Note",
        "task.doneHead": "Done",
        "gen.untitled": "(untitled)",
        "toast.saved": "saved",
        "toast.deleted": "deleted",
        "toast.imported": "imported",
        "toast.importFail": "import failed",
        "toast.avTooLarge": "image too large",
    },
    "zh": {
        "sync.title": "云同步",
        "sync.signin": "登录",
        "sync.signup": "注册",
        "sync.upload": "上传到云端",
        "sync.download": "从云端下载",
        "sync.signout": "退出登录",
        "sync.export": "导出文件",
        "sync.import": "导入文件",
        "sync.toggle": "切换",
        "sync.notSignedIn": "未登录",
        "sync.localOnly": "仅保存在本机",
        "sync.cloudOn": "云同步已开启",
        "sync.tabPassword": "密码登录",
        "sync.tabOtp": "验证码登录",
        "sync.tabSignup": "注册账号",
        "sync.tabReset": "忘记密码",
        "sync.email": "邮箱",
        "sync.password": "密码",
        "sync.newPassword": "设置新密码",
        "sync.code": "邮箱验证码",
        "sync.getCode": "获取验证码",
        "sync.sendReset": "发送重置码",
        "sync.cancel": "取消",
        "sync.go": "确定",
        "sync.close": "关闭",
        "sync.firstHint": "还没有账号？请切到「注册账号」标签。",
        "sync.warnLocal": "登录仅在正式发布的 HTTPS 域名上可用。当前是本地预览，数据仍会保存在本机。",
        "sync.enterEmail": "请先填写邮箱",
        "sync.codeSent": "验证码已发送，请到邮箱查收",
        "sync.resetSent": "重置码已发送",
        "sync.wrong": "邮箱或密码不对",
        "sync.needCode": "请先点「获取验证码」",
        "sync.needResetCode": "请先发送重置码到该邮箱",
        "sync.pwdUpdated": "密码已更新",
        "sync.signedIn": "登录成功",
        "sync.signedOut": "已退出登录",
        "sync.uploaded": "已上传到云端",
        "sync.downloaded": "已从云端下载",
        "sync.noCloud": "云端还没有数据",
        "sync.badCloud": "云端数据格式不对",
        "sync.sdkMissing": "云端组件未加载",
        "sync.couldNotSend": "验证码发送失败",
        "sync.uploadFailed": "上传失败",
        "sync.downloadFailed": "下载失败",
        "sync.nothingWritten": "没有写入 —— 请检查是否已登录",
        "sync.keptLocal": "本机已有数据：点「上传到云端」用它覆盖云端，或点「从云端下载」用云端覆盖本机。",
        "sync.tookCloud": "已载入云端数据",
        "sync.offline": "离线",

        # Timer.
        "pomo.start": "开始",
        "pomo.ready": "就绪",
        "pomo.logged": "已计入专注时长",
        "pomo.hint": "切到其他页面计时也不会停",
        "nav.focus": "专注",

        # Search.
        "search.toggle": "搜索",
        "search.none": "没有匹配的内容",

        # Settings.
        "set.appearance": "外观",
        "set.pomoMin": "专注时长（分钟）",
        "set.breakMin": "休息时长（分钟）",
        "set.tags": "标签",
        "set.tagsHint": "改名 / 换色 / 新增",
        "set.tagAdd": "新增标签",
        "set.saved": "已保存",
        "av.choose": "选择图片",
        "av.reset": "恢复默认",

        # 仅网页端有的两个视图
        "nav.today": "今日",
        "nav.stats": "统计",

        # 今日计划
        "today.evDone": "日程已完成",
        "today.focus": "今日专注",
        "today.due": "今日到期",
        "today.overdue": "已逾期",
        "today.events": "今日日程",
        "today.dueToday": "今日到期任务",
        "today.evEmpty": "今天没有安排",
        "today.dueEmpty": "今天没有到期任务",
        "today.stats": "查看统计",
        "today.lateDays": "逾期 {0} 天",

        # 统计页
        "st.focusWeek": "本周专注",
        "st.evWeek": "日程完成 / 计划",
        "st.streak": "连续专注天数",
        "st.taskDone": "任务完成",
        "st.focus7": "近 7 天专注",
        "st.ev7": "近 7 天日程",
        "st.minutes": "分钟",
        "st.byTag": "日程标签分布",
        "st.noData": "还没有数据",

        # 番茄钟任务队列
        "pomo.queue": "任务队列",
        "pomo.queueAdd": "加入队列",
        "pomo.queueNow": "就这个",
        "pomo.queueClear": "清空队列",
        "pomo.queueEmpty": "队列是空的 —— 加几个任务就能连着做",

        # 自定义节假日
        "set.holidays": "节假日",
        "set.holidaysHint": "添加自己的日期",
        "hol.date": "日期",
        "hol.name": "名称",
        "hol.add": "添加节假日",
        "hol.none": "还没有自定义的",
        "hol.needBoth": "先填日期和名称",

        # 清理编辑弹层等处遗留的英文
        "fld.ed.note": "备注",
        "task.doneHead": "已完成",
        "gen.untitled": "（未命名）",
        "toast.saved": "已保存",
        "toast.deleted": "已删除",
        "toast.imported": "已导入",
        "toast.importFail": "导入失败",
        "toast.avTooLarge": "图片过大，请换一张",
    },
}


def kebab(key):
    """PaletteKey -> --palette-key (CSS custom property naming)."""
    out = []
    for i, ch in enumerate(key):
        if ch.isupper() and i > 0:
            out.append("-")
        out.append(ch.lower())
    return "--" + "".join(out)


def build_css(tokens):
    lines = [
        "/* GENERATED from design/tokens.json -- do not hand-edit. */",
        "/* Source of truth is the WPF palette; keep the two in sync.  */",
        "",
        ":root {",
        "  --font-ui: '%s', system-ui, -apple-system, 'Segoe UI', sans-serif;" % tokens["fontFamily"],
        "  --font-mono: '%s', ui-monospace, monospace;" % tokens["fontFamilyMono"],
        "",
        "  --radius-card: %dpx;" % tokens["radii"]["card"],
        "  --radius-pill: %dpx;" % tokens["radii"]["pill"],
        "  --radius-btn: %dpx;" % tokens["radii"]["btn"],
        "  --radius-widget: %dpx;" % tokens["radii"]["widget"],
        "",
        "  /* Light theme is the default surface set. */",
    ]
    for k, v in tokens["color"]["light"].items():
        lines.append("  %s: %s;" % (kebab(k), v))

    lines.append("}")
    lines.append("")
    lines.append("[data-theme='night'] {")
    for k, v in tokens["color"]["night"].items():
        lines.append("  %s: %s;" % (kebab(k), v))
    lines.append("}")
    lines.append("")

    # Semantic aliases: components bind to intent, never to a raw palette key.
    lines += [
        "/* Semantic aliases -- components use these, so a palette swap",
        "   never forces a component rewrite. */",
        ":root {",
        "  --bg-app: var(--backdrop);",
        "  --bg-chrome: var(--chrome);",
        "  --bg-card: var(--card);",
        "  --bg-card-alt: var(--card-alt);",
        "  --fg: var(--ink);",
        "  --fg-soft: var(--ink-soft);",
        "  --fg-faint: var(--ink-faint);",
        "  --line: var(--border);",
        "  --line-soft: var(--border-soft);",
        "  --accent: var(--accent-event);",
        "  --accent-warm: var(--accent-focus);",
        "  --accent-cool: var(--accent-task);",
        "  --on-accent: var(--on-accent);",
        "}",
        "",
    ]
    return "\n".join(lines)


def build_i18n(lang):
    strings = lang["strings"]
    body = json.dumps(strings, ensure_ascii=False, indent=2)
    return "\n".join([
        "/* GENERATED from design/lang.json -- do not hand-edit. */",
        "/* {0}-style placeholders are filled by fmt() in app.js.        */",
        "window.I18N = %s;" % body,
        "window.I18N_DEFAULT = '%s';" % lang.get("default", "zh"),
        "",
    ])


def main():
    os.makedirs(os.path.join(WEB, "css"), exist_ok=True)
    os.makedirs(os.path.join(WEB, "js"), exist_ok=True)

    tokens = load("tokens.json")
    with open(os.path.join(WEB, "css", "tokens.css"), "w", encoding="utf-8") as f:
        f.write(build_css(tokens))
    print("tokens.css: %d palette keys x2 themes"
          % len(tokens["color"]["light"]))

    lang = load("lang.json")
    for lg, extra in WEB_EXTRA.items():
        lang["strings"].setdefault(lg, {}).update(extra)
    with open(os.path.join(WEB, "js", "i18n.js"), "w", encoding="utf-8") as f:
        f.write(build_i18n(lang))
    n = len(lang["strings"]["en"])
    print("i18n.js: %d keys x %d languages" % (n, len(lang["strings"])))


if __name__ == "__main__":
    main()
