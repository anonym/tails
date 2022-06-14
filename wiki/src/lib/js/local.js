document.addEventListener("DOMContentLoaded", function() {
  /* Toggle warnings
   */
  let warnings = ["identity", "tor", "computer"];

  function hideAllWarnings(evt) {
    warnings.forEach(function(element) {
      document.getElementById("detailed-" + element).style.display = "none";
      document.getElementById("toggle-" + element).classList.remove("button-revealed");
    });

  }

  function toggleWarnings(warning, evt) {
    let elem = document.getElementById("detailed-" + warning);
    let style = elem.style;
    if (style.display == "block") {
      hideAllWarnings(evt);
      return
    } else {
      hideAllWarnings(evt);
      style.display = "block";
      let btn = document.getElementById("toggle-" + warning);
      btn.classList.add("button-revealed")
    }
  }

  warnings.forEach(warning => document.getElementById("toggle-" + warning).onclick = function(e) { toggleWarnings(warning, e); });
  warnings.forEach(warning => document.getElementById("hide-" + warning).onclick = function(e) { hideAllWarnings(e); });
});
