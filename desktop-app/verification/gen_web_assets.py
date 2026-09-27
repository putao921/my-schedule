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
    with open(os.path.join(WEB, "js", "i18n.js"), "w", encoding="utf-8") as f:
        f.write(build_i18n(lang))
    n = len(lang["strings"]["en"])
    print("i18n.js: %d keys x %d languages" % (n, len(lang["strings"])))


if __name__ == "__main__":
    main()
