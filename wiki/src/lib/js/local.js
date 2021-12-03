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
    case 'fr':
      placeholder = "Avec DuckDuckGo…";
      break;
    case 'es':
      placeholder = "Con DuckDuckGo…";
      break;
  }
  document.getElementById("searchbox").placeholder = placeholder;
});
