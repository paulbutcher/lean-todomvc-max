/*
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/

// Loaded from <head> with no `defer`, so nothing here may look for an element at parse time:
// the listener is on `document`, which exists by then, and finds its element when the click
// arrives.
(function () {
  "use strict";

  function write(source) {
    if (navigator.clipboard) return navigator.clipboard.writeText(source.value);
    return Promise.reject();
  }

  function say(button, text) {
    var was = button.textContent;
    button.textContent = text;
    setTimeout(function () {
      button.textContent = was;
    }, 2000);
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("[data-copy]");
    if (!button) return;
    var source = document.getElementById(button.getAttribute("data-copy"));
    if (!source) return;
    // Selected either way, so that what was copied is visible, and so that a refused clipboard
    // leaves the keyboard one keystroke from doing the same job.
    source.select();
    write(source).then(
      function () {
        // The only confirmation there is: nothing else about the page changes, and a button that
        // looks the same after being pressed reads as one that did nothing.
        say(button, "Copied");
      },
      function () {
        say(button, "Press ⌘C or Ctrl-C");
      }
    );
  });
})();
