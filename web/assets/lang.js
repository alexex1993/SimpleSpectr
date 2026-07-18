/* SimpleSpectr landing — browser-language hint.
 *
 * Behaviour: when a visitor lands on the EN root (/), and their browser language
 * matches one of the available translations they haven't explicitly dismissed,
 * show a small, dismissible banner offering to switch. No forced redirect —
 * forced redirects hurt SEO and annoy users. The choice is remembered for 30 days.
 *
 * This file is intentionally tiny and defensive; it does nothing if any element
 * is missing or if the page is already a localized one.
 */
(function () {
  "use strict";

  // Map browser language prefixes to the sub-paths we publish.
  // Keys are the lang attr we use in <html>; values are path segments.
  var AVAILABLE = {
    ru: "ru", de: "de", es: "es", fr: "fr", it: "it", ja: "ja",
    ko: "ko", "zh-hans": "zh-Hans", "pt-br": "pt-BR", hi: "hi",
    ar: "ar", bn: "bn", tr: "tr"
  };

  // Friendly endonym for each locale (shown in the banner link).
  var NATIVE = {
    ru: "На русском", de: "Auf Deutsch", es: "En español", fr: "En français",
    it: "In italiano", ja: "日本語で", ko: "한국어로", "zh-hans": "简体中文",
    "pt-br": "Em português", hi: "हिन्दी में", ar: "بالعربية", bn: "বাংলায়",
    tr: "Türkçe olarak"
  };

  // Only run on the EN root. Localized pages live in sub-paths and never redirect.
  var path = window.location.pathname.replace(/\/+$/, "");
  if (path !== "" && path !== "/index.html") return;

  try {
    if (localStorage.getItem("ss_lang_choice") === "en") return;
  } catch (e) { /* localStorage may be unavailable */ }

  // navigator.languages is the robust source of preference order.
  var langs = (navigator.languages && navigator.languages.length)
    ? navigator.languages
    : [navigator.language || ""];

  var match = null;
  for (var i = 0; i < langs.length; i++) {
    var l = String(langs[i] || "").toLowerCase();
    if (!l || l.indexOf("en") === 0) break; // English (or below it) — stop.

    // exact like "pt-br" or "zh-hans"
    if (AVAILABLE[l]) { match = AVAILABLE[l]; break; }
    // prefix like "ru", "de", "ja" ...
    var prefix = l.split("-")[0];
    if (AVAILABLE[prefix]) {
      // special-case zh / pt to the variants we publish
      if (prefix === "zh") match = AVAILABLE["zh-hans"];
      else if (prefix === "pt") match = AVAILABLE["pt-br"];
      else match = AVAILABLE[prefix];
      break;
    }
  }

  if (!match) return;

  var banner = document.getElementById("lang-banner");
  var link = document.getElementById("lang-banner-link");
  var dismiss = document.getElementById("lang-banner-dismiss");
  if (!banner || !link || !dismiss) return;

  link.textContent = NATIVE[match] || ("↗");
  link.href = window.location.origin + "/" + match + "/";
  banner.classList.add("visible");

  dismiss.addEventListener("click", function () {
    try { localStorage.setItem("ss_lang_choice", "en"); } catch (e) {}
    banner.classList.remove("visible");
  });
})();
