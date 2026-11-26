// A chat picture's commands live in the app's right-click menu, not in buttons
// over the picture. WebKit's own menu already copies the image; the app adds
// Open Beside, which acts on the picture remembered here when the menu was
// raised.

export function installPictureMenu({ openBeside }) {
  let figure = null;
  document.addEventListener(
    "contextmenu",
    (event) => {
      const target = event.target;
      figure = target?.closest?.("figure.source-image-figure") ?? null;
    },
    true,
  );
  window.openContextPictureBeside = () => {
    const img = figure?.querySelector("img");
    const token = figure?.dataset.sourceImage;
    if (!token || !img || img.hidden) return;
    openBeside(token, img);
  };
}
