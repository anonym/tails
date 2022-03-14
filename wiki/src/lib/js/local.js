document.addEventListener("DOMContentLoaded", function() {
  /* Translate the placeholder of the search box
   *
   * Using the usual CSS translation hack doesn't work here because it sends
   * multiple #searchbox fields in the form and DuckDuckGo only takes the
   * first one (English) into account.
   */
  var lang;
  var languages = ['en', 'de', 'es', 'fr', 'it', 'pt', 'ru'];
  languages.forEach(function(l) {
    if (document.body.classList.contains(l)) {
      lang = l;
    }
  });
  var placeholder = document.getElementById("searchbox").placeholder;
  switch (lang) {
    case 'es':
      placeholder = "Con DuckDuckGo…";
      break;
    case 'fr':
      placeholder = "Avec DuckDuckGo…";
      break;
    case 'it':
      placeholder = "Usando DuckDuckGo…";
      break;
    case 'pt':
      placeholder = "Usando DuckDuckGo…";
      break;
    case 'ru':
      placeholder = "Поиск DuckDuckGo…";
      break;
    case 'de':
      placeholder = "Verwende DuckDuckGo…";
      break;
  }
  document.getElementById("searchbox").placeholder = placeholder;

  /* Toggle warnings
   */
  let warnings = ["identity", "tor", "computer"];

  function hideAllWarnings(evt) {
    warnings.forEach(function(element) {
      document.getElementById("detailed-" + element).style.display = "none";
    });

  }

  function toggleWarnings(warning, evt) {
    hideAllWarnings(evt);
    let elem = document.getElementById("detailed-" + warning);
    let style = elem.style;
    if (style.display == "block") {
      style.display = "none";
    } else {
      style.display = "block";
    }
  }

  warnings.forEach(warning => document.getElementById("toggle-" + warning).onclick = function(e) { toggleWarnings(warning, e); });
  warnings.forEach(warning => document.getElementById("hide-" + warning).onclick = function(e) { hideAllWarnings(e); });
});
