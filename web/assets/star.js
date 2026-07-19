/* SimpleSpectr landing — "star on GitHub" nudge.
 *
 * When a visitor clicks a download button, the download opens in a new tab
 * (the link keeps target="_blank"), and a small modal appears on the current
 * page asking them to give the project a star on GitHub as a thank-you to the
 * author. Purely additive: if the modal markup is missing, this does nothing.
 */
(function () {
  "use strict";

  var modal = document.getElementById("star-modal");
  if (!modal) return;

  var lastFocus = null;

  function open() {
    lastFocus = document.activeElement;
    modal.hidden = false;
    document.body.classList.add("star-modal-open");
    var focusTarget = modal.querySelector(".btn-primary");
    if (focusTarget && focusTarget.focus) focusTarget.focus();
  }

  function close() {
    if (modal.hidden) return;
    modal.hidden = true;
    document.body.classList.remove("star-modal-open");
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  var buttons = document.querySelectorAll(".js-download");
  for (var i = 0; i < buttons.length; i++) {
    buttons[i].addEventListener("click", function () {
      // The link itself opens the download in a new tab; nudge shortly after.
      setTimeout(open, 350);
    });
  }

  modal.addEventListener("click", function (e) {
    if (e.target.closest("[data-star-close]")) close();
  });

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") close();
  });
})();
