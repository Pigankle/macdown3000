/**
 * "Reveal in Editor" support for the editor preview.
 *
 * Records the point under a right-click or option-click, and collects the
 * preview's text so MPDocument can map that point back to the Markdown
 * source (see MPPreviewSourceLocator). Option-click asks MPDocument to reveal
 * the point through the x-macdown-reveal URL scheme, authenticated with the
 * same per-renderer token as the checkbox bridge, and does not also follow a
 * link or toggle a checkbox. Listeners are on the document, so they survive
 * the body.innerHTML DOM-replacement path. This script only runs in the
 * editor preview; exports do not include it.
 *
 * Related to GitHub issue #627.
 */
(function () {
  if (window.macdownRevealInstalled) {
    return;
  }
  window.macdownRevealInstalled = true;

  // Elements whose text the renderer generates rather than copies from the
  // Markdown source. Text inside them is not collected.
  var EXCLUDED_SELECTOR = [
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    '.macdown-toc',
    'sup[id^="fnref"]',
    'a[rev="footnote"]',
    '.MathJax',
    '.MathJax_Display',
    '.MathJax_Preview',
    '.macdown-table-resize-handle',
    '.prism-show-language'
  ].join(', ');
  var FOOTNOTE_ITEM_SELECTOR = 'div.footnotes > ol > li';
  // Collection stops this many nodes after the clicked one; the source
  // locator never looks further ahead than that.
  var NODES_AFTER_POINT = 40;

  window.macdownRevealPoint = null;

  function closest(element, selector) {
    if (element && element.closest) {
      return element.closest(selector);
    }
    for (; element && element.nodeType === 1; element = element.parentNode) {
      var matches = element.matches || element.webkitMatchesSelector;
      if (matches.call(element, selector)) {
        return element;
      }
    }
    return null;
  }

  function capturePoint(event) {
    var range = document.caretRangeFromPoint(event.clientX, event.clientY);
    window.macdownRevealPoint = range
      ? {node: range.startContainer, offset: range.startOffset}
      : null;
  }

  document.addEventListener('contextmenu', capturePoint, true);

  document.addEventListener('click', function (event) {
    if (!event.altKey || event.button !== 0) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    capturePoint(event);
    var tokenMeta =
      document.querySelector('meta[name="macdown-checkbox-token"]');
    var token = tokenMeta ? tokenMeta.getAttribute('content') : '';
    window.location =
      'x-macdown-reveal://reveal?token=' + encodeURIComponent(token);
  }, true);

  function isCollected(node) {
    return node.nodeValue.trim().length > 0
      && !closest(node.parentNode, EXCLUDED_SELECTOR);
  }

  // Whether node is at or after ref in document order. With afterSubtree,
  // whether node is after everything inside ref instead.
  function isAtOrAfter(node, ref, afterSubtree) {
    if (node === ref) {
      return !afterSubtree;
    }
    var position = ref.compareDocumentPosition(node);
    if (!(position & Node.DOCUMENT_POSITION_FOLLOWING)) {
      return false;
    }
    return !afterSubtree || !(position & Node.DOCUMENT_POSITION_CONTAINED_BY);
  }

  function footnoteIndex(node, items) {
    if (!items.length) {
      return -1;
    }
    var item = closest(node.parentNode, FOOTNOTE_ITEM_SELECTOR);
    return item ? Array.prototype.indexOf.call(items, item) : -1;
  }

  /**
   * Returns {texts, footnotes, index, offset}: the collected text nodes'
   * values in document order, the footnote each is inside (or -1), and the
   * entry and offset the recorded point resolves to. index is -1 if there is
   * no recorded point or its node is no longer in the document.
   */
  window.macdownRevealCollect = function () {
    var result = {texts: [], footnotes: [], index: -1, offset: 0};
    var point = window.macdownRevealPoint;
    if (!point || !point.node || !document.body.contains(point.node)) {
      return result;
    }

    // The point resolves to the first collected node at or after ref (or
    // after ref's subtree), else to the end of the last collected node.
    var ref = point.node;
    var afterSubtree = false;
    if (ref.nodeType === 1) {
      if (point.offset < ref.childNodes.length) {
        ref = ref.childNodes[point.offset];
      } else {
        afterSubtree = true;
      }
    }

    var items = document.querySelectorAll(FOOTNOTE_ITEM_SELECTOR);
    var walker = document.createTreeWalker(
      document.body, NodeFilter.SHOW_TEXT, null, false);
    var stop = -1;
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!isCollected(node)) {
        continue;
      }
      var i = result.texts.length;
      if (result.index < 0 && isAtOrAfter(node, ref, afterSubtree)) {
        result.index = i;
        result.offset = node === point.node ? point.offset : 0;
        stop = i + NODES_AFTER_POINT;
      }
      result.texts.push(node.nodeValue);
      result.footnotes.push(footnoteIndex(node, items));
      if (i === stop) {
        break;
      }
    }
    if (result.index < 0 && result.texts.length) {
      result.index = result.texts.length - 1;
      result.offset = result.texts[result.index].length;
    }
    return result;
  };
})();
