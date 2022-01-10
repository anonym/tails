document.addEventListener("DOMContentLoaded", function() {
  /* Translate the placeholder of the search box
   *
   * Using the usual CSS translation hack doesn't work here because it sends
   * multiple #searchbox fields in the form and DuckDuckGo only takes the
   * first one (English) into account.
   */
  var lang;
  var languages = ['en', 'de', 'es', 'fr', 'it', 'pt', 'ru'];
  console.log(document.body.classList);
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
    case 'ru':
      placeholder = "Поиск DuckDuckGo…";
      break;
    case 'de':
      placeholder = "Verwende DuckDuckGo…";
      break;
  }
  document.getElementById("searchbox").placeholder = placeholder;
});
