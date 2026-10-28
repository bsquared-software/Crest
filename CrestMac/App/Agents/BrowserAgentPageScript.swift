import Foundation

/// A script Crest runs for an agent in the agent's own world of a page, the
/// same on both engines: reading the page as an outline, finding the element
/// a uid names, filling a field, or looking for text. Each is the body of an
/// async function; its arguments are written into it as JSON.
struct BrowserAgentPageScript {
    // MARK: - Static Variables

    /// What every script shares: the elements the latest outline named, by
    /// uid, which a new document starts empty.
    private static let state = #"""
        const state = (globalThis.__crestAgent ??= { document: null, uids: new Map(), elements: new WeakMap(), next: 1 });
        if (state.document !== document) {
          state.document = document; state.uids = new Map(); state.elements = new WeakMap(); state.next = 1;
        }
        // A form's named fields shadow its own properties: a field named "title" or "hidden" stands in for
        // the form's. Elements are read through the DOM's own accessors, which a page cannot shadow.
        const isConnectedOf = Object.getOwnPropertyDescriptor(Node.prototype, "isConnected").get;
        const tagName = Object.getOwnPropertyDescriptor(Element.prototype, "tagName").get;
        const tagOf = (node) => tagName.call(node);
        const editableOf = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "isContentEditable").get;
        const editable = (node) => node instanceof HTMLElement && editableOf.call(node);
        const element = (uid) => {
          const found = state.uids.get(uid)?.deref();
          return found && isConnectedOf.call(found) ? found : null;
        };
        """#

    /// The page as an accessibility outline: each meaningful element's role,
    /// name and state with a uid, and the text between them, within a bound.
    /// A password field's value is never part of it.
    private static let outline = Self(
        source: #"""
            const limit = 60000;
            const shadowRootOf = Object.getOwnPropertyDescriptor(Element.prototype, "shadowRoot").get;
            const childNodesOf = Object.getOwnPropertyDescriptor(Node.prototype, "childNodes").get;
            const nodeTypeOf = Object.getOwnPropertyDescriptor(Node.prototype, "nodeType").get;
            const parentOf = Object.getOwnPropertyDescriptor(Node.prototype, "parentElement").get;
            const textOf = Object.getOwnPropertyDescriptor(Node.prototype, "textContent").get;
            const innerTextOf = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "innerText").get;
            // The document's named elements shadow its properties the same way, as an <img name="body"> does.
            const ofDocument = (name) => Object.getOwnPropertyDescriptor(Document.prototype, name).get.call(document);
            const attribute = (node, name) => Element.prototype.getAttribute.call(node, name);
            const has = (node, name) => Element.prototype.hasAttribute.call(node, name);
            const lines = [];
            let size = 0;
            let truncated = false;
            const roles = { A: "link", BUTTON: "button", SELECT: "combobox", TEXTAREA: "textbox", IMG: "img", NAV: "navigation",
              MAIN: "main", HEADER: "banner", FOOTER: "contentinfo", ASIDE: "complementary", FORM: "form", TABLE: "table",
              TR: "row", TD: "cell", TH: "columnheader", UL: "list", OL: "list", LI: "listitem", DIALOG: "dialog",
              SUMMARY: "button", DETAILS: "group", OPTION: "option", IFRAME: "iframe", H1: "heading", H2: "heading",
              H3: "heading", H4: "heading", H5: "heading", H6: "heading", PROGRESS: "progressbar" };
            const inputs = { checkbox: "checkbox", radio: "radio", button: "button", submit: "button", reset: "button",
              image: "button", range: "slider", number: "spinbutton", search: "searchbox", file: "button", color: "button" };
            const interactive = new Set(["link", "button", "combobox", "textbox", "searchbox", "checkbox", "radio", "slider",
              "spinbutton", "option", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "switch", "treeitem"]);
            const landmarks = new Set(["heading", "img", "navigation", "main", "banner", "contentinfo", "complementary",
              "form", "table", "row", "cell", "columnheader", "list", "listitem", "dialog", "group", "iframe", "region",
              "progressbar", "alert", "status", "tablist", "menu", "tree", "grid"]);
            const roleOf = (node) => {
              const explicit = attribute(node, "role")?.split(" ")[0];
              if (explicit) return explicit;
              const tag = tagOf(node);
              if (tag === "INPUT") return inputs[node.type] ?? "textbox";
              if (tag === "A" && !has(node, "href")) return null;
              if (tag === "SECTION" && (has(node, "aria-label") || has(node, "aria-labelledby"))) return "region";
              if (editable(node) && !editable(parentOf.call(node))) return "textbox";
              return roles[tag] ?? null;
            };
            const clean = (text) => String(text ?? "").replace(/\s+/g, " ").trim().slice(0, 200);
            const nameOf = (node, role) => {
              const label = attribute(node, "aria-label");
              if (label) return clean(label);
              const by = attribute(node, "aria-labelledby");
              if (by) return clean(by.split(" ").map((id) => Document.prototype.getElementById.call(document, id))
                .map((found) => found && textOf.call(found)).join(" "));
              // A label's own words, not those of a control inside it, such as a menu's options.
              const own = (label) => [...childNodesOf.call(label)].filter((child) => nodeTypeOf.call(child) === Node.TEXT_NODE ||
                (nodeTypeOf.call(child) === Node.ELEMENT_NODE && !Element.prototype.matches.call(child, "input, select, textarea, button")))
                .map((child) => textOf.call(child)).join(" ");
              // A form has no labels of its own, only, perhaps, a field named "labels".
              if (tagOf(node) !== "FORM" && node.labels?.length) return clean([...node.labels].map(own).join(" "));
              const alt = attribute(node, "alt");
              if (alt) return clean(alt);
              if (["link", "button", "heading", "option", "tab", "menuitem", "cell", "columnheader", "listitem", "treeitem"].includes(role))
                return clean(node instanceof HTMLElement ? innerTextOf.call(node) : textOf.call(node));
              return clean(attribute(node, "title") || attribute(node, "placeholder") || "");
            };
            const hidden = (node) => {
              if (attribute(node, "aria-hidden") === "true" || has(node, "hidden")) return true;
              if (Element.prototype.checkVisibility)
                return !Element.prototype.checkVisibility.call(node, { checkOpacity: false, checkVisibilityCSS: true });
              const style = getComputedStyle(node);
              return style.display === "none" || style.visibility === "hidden";
            };
            const uidOf = (node) => {
              let uid = state.elements.get(node);
              if (!uid) {
                uid = "e" + state.next++;
                state.elements.set(node, uid);
                state.uids.set(uid, new WeakRef(node));
              }
              return uid;
            };
            const emit = (depth, line) => {
              if (truncated) return;
              size += line.length + depth * 2 + 1;
              if (size > limit) { truncated = true; return; }
              lines.push("  ".repeat(depth) + line);
            };
            const describe = (node, role) => {
              const parts = [`- ${role}`];
              const name = nameOf(node, role);
              if (name) parts.push(JSON.stringify(name));
              parts.push(`[uid=${uidOf(node)}]`);
              const tag = tagOf(node);
              if (role === "heading") parts.push(`[level=${tag.slice(1) || attribute(node, "aria-level") || 2}]`);
              if (node.disabled === true || attribute(node, "aria-disabled") === "true") parts.push("[disabled]");
              if (node.checked === true || attribute(node, "aria-checked") === "true") parts.push("[checked]");
              if (attribute(node, "aria-expanded")) parts.push(`[expanded=${attribute(node, "aria-expanded")}]`);
              if (node.selected === true || attribute(node, "aria-selected") === "true") parts.push("[selected]");
              if (node === ofDocument("activeElement")) parts.push("[focused]");
              // A link to the page's own origin is its path, which navigate takes too: the origin
              // repeated on every link is a fifth of a busy page's outline. Anything else, such as a
              // blob: link, a link with credentials or a path that reads as a host (//x), keeps its whole address.
              if (tag === "A" && node.href) {
                const own = location.origin !== "null" && /^https?:$/.test(node.protocol) && node.protocol === location.protocol
                  && node.host === location.host && !node.username && !node.password && !node.pathname.startsWith("//");
                const href = own ? node.pathname + node.search + node.hash : node.href;
                parts.push(`[href=${href.slice(0, 300)}]`);
              }
              if (tag === "INPUT" && node.type === "password") parts.push("[password]");
              else if ("value" in node && ["textbox", "searchbox", "combobox", "spinbutton", "slider"].includes(role) && node.value)
                parts.push(`[value=${JSON.stringify(String(node.value).slice(0, 200))}]`);
              return parts.join(" ");
            };
            const walk = (node, depth) => {
              for (const child of childNodesOf.call(node)) {
                if (truncated) return;
                if (nodeTypeOf.call(child) === Node.TEXT_NODE) {
                  const text = clean(child.textContent);
                  if (text) emit(depth, `- text ${JSON.stringify(text)}`);
                  continue;
                }
                if (nodeTypeOf.call(child) !== Node.ELEMENT_NODE) continue;
                if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "HEAD", "META", "LINK"].includes(tagOf(child).toUpperCase())) continue;
                if (hidden(child)) continue;
                const role = roleOf(child);
                if (role && (interactive.has(role) || landmarks.has(role))) {
                  emit(depth, describe(child, role));
                  // A control's own text is its name; its children add nothing.
                  if (!interactive.has(role) || role === "listitem") walk(child, depth + 1);
                  const shadow = shadowRootOf.call(child);
                  if (shadow) walk(shadow, depth + 1);
                } else {
                  walk(child, depth);
                  const shadow = shadowRootOf.call(child);
                  if (shadow) walk(shadow, depth);
                }
              }
            };
            const root = scope === null ? (ofDocument("body") ?? ofDocument("documentElement")) : element(scope);
            if (!root) return { error: "unknown" };
            if (scope === null) {
              walk(root, 0);
            } else if (!hidden(root)) {
              // One part of the page: the element itself, then what it holds.
              const role = roleOf(root);
              if (role) emit(0, describe(root, role));
              walk(root, role ? 1 : 0);
              const shadow = shadowRootOf.call(root);
              if (shadow) walk(shadow, role ? 1 : 0);
            }
            return { url: location.href, title: ofDocument("title"), outline: lines.join("\n"), truncated,
              hidden: scope !== null && hidden(root) };
            """#)

    // MARK: - Variables

    let source: String

    // MARK: - Actions - Elements

    /// Scrolls the element `uid` names into view and answers where it is in
    /// the viewport, in CSS pixels, with its role and name; or an error.
    static func locate(_ uid: String) -> Self {
        Self(
            source: state + """
                const target = element(\(json(uid)));
                if (!target) return { error: "unknown" };
                target.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
                const box = target.getBoundingClientRect();
                return { x: box.left + box.width / 2, y: box.top + box.height / 2, left: box.left, top: box.top,
                  width: box.width, height: box.height, viewportWidth: innerWidth, viewportHeight: innerHeight,
                  tag: tagOf(target).toLowerCase(), editable: editable(target) || ["INPUT", "TEXTAREA"].includes(tagOf(target)),
                  menu: tagOf(target) === "SELECT" };
                """)
    }

    /// Readies the element `uid` names for new text: focuses it and selects
    /// what it holds, so typing replaces it; or chooses the menu option whose
    /// label or value is `value`.
    static func prepareFill(_ uid: String, value: String) -> Self {
        Self(
            source: state + """
                const target = element(\(json(uid)));
                if (!target) return { error: "unknown" };
                const value = \(json(value));
                if (tagOf(target) === "SELECT") {
                  const option = [...target.options].find((item) => item.label === value || item.value === value || item.text.trim() === value);
                  if (!option) return { error: "option" };
                  target.value = option.value;
                  target.dispatchEvent(new Event("input", { bubbles: true }));
                  target.dispatchEvent(new Event("change", { bubbles: true }));
                  return { chosen: option.label || option.text };
                }
                if (!(editable(target) || ["INPUT", "TEXTAREA"].includes(tagOf(target)))) return { error: "editable" };
                target.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
                target.focus();
                if (editable(target)) {
                  const range = document.createRange();
                  range.selectNodeContents(target);
                  const selection = getSelection();
                  selection.removeAllRanges();
                  selection.addRange(range);
                  if (!value) document.execCommand("delete");
                } else {
                  target.select?.();
                  if (!value) {
                    const prototype = tagOf(target) === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                    Object.getOwnPropertyDescriptor(prototype, "value").set.call(target, "");
                    target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "deleteContentBackward" }));
                  }
                }
                return { ready: true };
                """)
    }

    /// The page as an outline, or only the part of it the element `uid` holds,
    /// the element first; or an error when the page has no such element now.
    static func snapshot(of uid: String?) -> Self {
        Self(source: state + "const scope = \(json(uid));\n" + outline.source)
    }

    /// The page's readable text as Markdown, within `limit` characters:
    /// headings, paragraphs, list items, quotes, code and links, leaving out
    /// what the page hides and every form field's value, a password's above
    /// all.
    static func readText(limit: Int) -> Self {
        Self(
            source: """
                const limit = \(limit);
                const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "INPUT",
                  "TEXTAREA", "SELECT", "OPTION"]);
                const blocks = new Set(["P", "DIV", "SECTION", "ARTICLE", "MAIN", "HEADER", "FOOTER", "ASIDE", "NAV",
                  "FIGURE", "FIGCAPTION", "TABLE", "TR", "UL", "OL", "DL", "DT", "DD", "FORM", "FIELDSET", "DETAILS", "SUMMARY"]);
                // A form's named fields shadow its own properties; read elements through the DOM's accessors.
                const tagName = Object.getOwnPropertyDescriptor(Element.prototype, "tagName").get;
                const childNodesOf = Object.getOwnPropertyDescriptor(Node.prototype, "childNodes").get;
                const childrenOf = Object.getOwnPropertyDescriptor(Element.prototype, "children").get;
                const nodeTypeOf = Object.getOwnPropertyDescriptor(Node.prototype, "nodeType").get;
                const checkVisibility = Element.prototype.checkVisibility;
                const tagOf = (node) => tagName.call(node);
                const ofDocument = (name) => Object.getOwnPropertyDescriptor(Document.prototype, name).get.call(document);
                const out = [];
                let size = 0;
                let truncated = false;
                const push = (text) => {
                  if (truncated) return;
                  if (size + text.length > limit) { out.push(text.slice(0, limit - size)); truncated = true; size = limit; return; }
                  out.push(text); size += text.length;
                };
                const hidden = (node) => {
                  if (Element.prototype.hasAttribute.call(node, "hidden")
                    || Element.prototype.getAttribute.call(node, "aria-hidden") === "true") return true;
                  if (!checkVisibility) return false;
                  // A display: contents wrapper has no box of its own, so only the visibility it
                  // passes down, its own or an ancestor's, hides what it holds.
                  const style = getComputedStyle(node);
                  if (style.display === "contents") return style.visibility !== "visible";
                  return !checkVisibility.call(node, { checkOpacity: true, checkVisibilityCSS: true, opacityProperty: true,
                    visibilityProperty: true });
                };
                const inline = (node) => {
                  if (nodeTypeOf.call(node) === Node.TEXT_NODE) return node.textContent.replace(/\\s+/g, " ");
                  if (nodeTypeOf.call(node) !== Node.ELEMENT_NODE || skipped.has(tagOf(node)) || hidden(node)) return "";
                  const text = [...childNodesOf.call(node)].map(inline).join("");
                  if (tagOf(node) === "A" && node.href && text.trim()) return `[${text.trim()}](${node.href})`;
                  if (tagOf(node) === "IMG") return node.alt ? `![${node.alt}]` : "";
                  if (tagOf(node) === "CODE") return text ? "`" + text + "`" : "";
                  if (tagOf(node) === "BR") return "\\n";
                  if (tagOf(node) === "STRONG" || tagOf(node) === "B") return text.trim() ? `**${text.trim()}**` : text;
                  return text;
                };
                const walk = (node, depth) => {
                  if (truncated || nodeTypeOf.call(node) !== Node.ELEMENT_NODE || skipped.has(tagOf(node)) || hidden(node)) return;
                  const tag = tagOf(node);
                  const heading = /^H([1-6])$/.exec(tag);
                  if (heading) { const text = inline(node).trim(); if (text) push("#".repeat(+heading[1]) + " " + text + "\\n\\n"); return; }
                  if (tag === "LI") {
                    // A nested list follows its item, indented, rather than running into its text.
                    const own = [...childNodesOf.call(node)]
                      .filter((child) => nodeTypeOf.call(child) !== Node.ELEMENT_NODE || !["UL", "OL"].includes(tagOf(child)))
                      .map(inline).join("").trim();
                    if (own) push("  ".repeat(Math.max(depth, 0)) + "- " + own + "\\n");
                    for (const child of childrenOf.call(node)) if (["UL", "OL"].includes(tagOf(child))) walk(child, depth);
                    return;
                  }
                  if (tag === "PRE") { push("```\\n" + node.innerText + "\\n```\\n\\n"); return; }
                  if (tag === "BLOCKQUOTE") { const text = inline(node).trim(); if (text) push("> " + text + "\\n\\n"); return; }
                  if (tag === "UL" || tag === "OL") { for (const child of childrenOf.call(node)) walk(child, depth + 1); push("\\n"); return; }
                  const hasBlocks = [...childrenOf.call(node)].some((child) => blocks.has(tagOf(child)) || /^H[1-6]$/.test(tagOf(child))
                    || ["LI", "PRE", "BLOCKQUOTE", "UL", "OL"].includes(tagOf(child)));
                  if (!hasBlocks) { const text = inline(node).trim(); if (text) push(text + "\\n\\n"); return; }
                  for (const child of childNodesOf.call(node)) {
                    if (nodeTypeOf.call(child) === Node.TEXT_NODE) { const text = child.textContent.trim(); if (text) push(text + "\\n\\n"); }
                    else walk(child, depth);
                  }
                };
                const body = ofDocument("body");
                if (body) walk(body, -1);
                return { url: location.href, title: ofDocument("title"), text: out.join("").replace(/\\n{3,}/g, "\\n\\n").trim(), truncated };
                """)
    }

    /// Whether the page shows `text` now, or, without text, whether it has
    /// finished loading.
    static func shows(_ text: String?) -> Self {
        Self(
            source: """
                const text = \(json(text));
                // A page's named elements shadow the document's properties, so read them through its accessors.
                const ofDocument = (name) => Object.getOwnPropertyDescriptor(Document.prototype, name).get.call(document);
                if (text === null) return ofDocument("readyState") === "complete";
                const body = ofDocument("body");
                return (body?.innerText ?? "").includes(text);
                """)
    }

    private static func json(_ value: String?) -> String {
        guard let value else { return "null" }
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
