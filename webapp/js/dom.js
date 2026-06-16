//
//  dom.js
//  NotionScan Web
//
//  Tiny DOM helpers so the rest of the app can build UI without a framework.
//  `el` creates elements with attributes/children; `clear` empties a node.
//

/**
 * Create an element.
 * @param {string} tag - tag name, optionally with `.class` and `#id` shorthands, e.g. "button.shutter".
 * @param {object} [attrs] - attributes/properties. `class`, `text`, `html`, `on*` handlers, `dataset`, `style` are special-cased.
 * @param {(Node|string|null|undefined|Array)} [children]
 */
export function el(tag, attrs = {}, children = []) {
  let tagName = tag;
  const classes = [];
  let id;

  // Support "div.foo.bar#id" shorthand.
  tagName = tag.replace(/[.#][^.#]+/g, (token) => {
    if (token[0] === ".") classes.push(token.slice(1));
    else id = token.slice(1);
    return "";
  }) || "div";

  const node = document.createElement(tagName);
  if (classes.length) node.classList.add(...classes);
  if (id) node.id = id;

  for (const [key, value] of Object.entries(attrs)) {
    if (value == null || value === false) continue;
    if (key === "class") {
      node.className = [node.className, value].filter(Boolean).join(" ");
    } else if (key === "text") {
      node.textContent = value;
    } else if (key === "html") {
      node.innerHTML = value;
    } else if (key === "dataset") {
      Object.assign(node.dataset, value);
    } else if (key === "style" && typeof value === "object") {
      Object.assign(node.style, value);
    } else if (key.startsWith("on") && typeof value === "function") {
      node.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (key in node && key !== "list") {
      try {
        node[key] = value;
      } catch {
        node.setAttribute(key, value);
      }
    } else {
      node.setAttribute(key, value);
    }
  }

  appendChildren(node, children);
  return node;
}

function appendChildren(node, children) {
  const list = Array.isArray(children) ? children : [children];
  for (const child of list) {
    if (child == null || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

/** Remove all children from a node. */
export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
  return node;
}

/** Shorthand for document.querySelector. */
export function qs(selector, root = document) {
  return root.querySelector(selector);
}

/** Read a File/Blob as a data URL. */
export function blobToDataURL(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** Trigger a browser download of a blob with the given filename. */
export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = el("a", { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Give the download a tick to start before revoking.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
