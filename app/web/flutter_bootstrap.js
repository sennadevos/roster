{{flutter_js}}
{{flutter_build_config}}

// Everything from this origin: CanvasKit comes from ./canvaskit/ (built with
// --no-web-resources-cdn), and the fonts the engine falls back to for glyphs
// that Roboto lacks (symbols, emoji, CJK) from ./fonts/, which
// tool/build_web.sh fills, instead of fonts.gstatic.com. No service worker:
// Flutter's is deprecated, and a browser only allows one in a secure context.
const config = { fontFallbackBaseUrl: "fonts/" };
_flutter.loader.load({
  config,
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine(config);
    await appRunner.runApp();
    // The splash in index.html fades once the app has drawn.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const splash = document.getElementById("splash");
      if (!splash) return;
      splash.classList.add("gone");
      setTimeout(() => splash.remove(), 300);
    }));
  },
});
