import WebKit

/// Avoid the system-ui CJK missing-glyph fallback seen in iOS 26.3 WebKit.
/// Local faces are restricted to CJK, leaving Latin text and icon fonts alone.
enum CjkFontFallback {
  static var userScript: WKUserScript {
    WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
  }

  private static let source = #"""
  (() => {
    const id = 'ssg-cjk-font-fallback';
    const range = 'U+2E80-2FFF,U+3000-303F,U+3100-312F,U+31A0-31EF,U+3400-9FFF,U+F900-FAFF,U+FE30-FE4F,U+FF00-FFEF,U+20000-3FFFF';
    const faces = [[400, 'Regular'], [500, 'Medium'], [600, 'Semibold']]
      .map(([weight, name]) => `@font-face {
        font-family: "SSG Shell CJK";
        src: local("PingFangSC-${name}");
        font-style: normal;
        font-weight: ${weight};
        font-display: swap;
        unicode-range: ${range};
      }`).join('\n');
    const css = faces + `
      html, body {
        --font-family: "SSG Shell CJK", system-ui, -apple-system, BlinkMacSystemFont,
          "Roboto", "Apple Color Emoji", "Helvetica Neue", sans-serif !important;
      }
    `;
    function install() {
      if (!document.documentElement) return false;
      if (!document.getElementById(id)) {
        const style = document.createElement('style');
        style.id = id;
        style.textContent = css;
        document.documentElement.appendChild(style);
      }
      return true;
    }
    // At document start even <html> may not exist yet. Observe only until it does.
    if (!install()) {
      const observer = new MutationObserver(() => {
        if (install()) observer.disconnect();
      });
      observer.observe(document, { childList: true });
    }
  })();
  """#
}
