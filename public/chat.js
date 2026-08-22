/*
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/

// Loaded from <head> with no `defer`, so nothing here may look for an element at parse time:
// everything is a listener on `document`, which exists by then, and finds its element when the
// event arrives.
(function () {
  "use strict";

  var WIDTH_KEY = "todomvc-chat-width";
  var MIN_PANEL = 288; // Matches `.chat-panel { min-width }`.
  var MIN_PANE = 320; // Matches `.app-pane { min-width }`.

  function setWidth(px) {
    var limit = window.innerWidth - MIN_PANE;
    var width = Math.max(MIN_PANEL, Math.min(px, limit));
    document.documentElement.style.setProperty("--chat-width", width + "px");
    return width;
  }

  // The width belongs to the window being read in rather than to the account, so it is kept here
  // rather than sent to the server, and a browser that refuses storage simply starts from the
  // stylesheet's default every time.
  function restoreWidth() {
    try {
      var saved = window.localStorage.getItem(WIDTH_KEY);
      if (saved) setWidth(parseInt(saved, 10));
    } catch (e) {
      /* Private mode, or storage turned off. The default width is a fine answer. */
    }
  }

  function rememberWidth(width) {
    try {
      window.localStorage.setItem(WIDTH_KEY, String(width));
    } catch (e) {
      /* As above: not being able to remember it is not a reason to stop resizing. */
    }
  }

  var dragging = false;

  document.addEventListener("pointerdown", function (event) {
    if (!event.target.closest || !event.target.closest("#app-divider")) return;
    dragging = true;
    event.target.setPointerCapture(event.pointerId);
    event.target.classList.add("dragging");
    document.body.classList.add("resizing");
    event.preventDefault();
  });

  document.addEventListener("pointermove", function (event) {
    if (!dragging) return;
    setWidth(window.innerWidth - event.clientX);
  });

  document.addEventListener("pointerup", function (event) {
    if (!dragging) return;
    dragging = false;
    var divider = document.getElementById("app-divider");
    if (divider) divider.classList.remove("dragging");
    document.body.classList.remove("resizing");
    rememberWidth(setWidth(window.innerWidth - event.clientX));
  });

  // A narrowed window can leave the panel wider than the limit that was in force when it was set.
  window.addEventListener("resize", function () {
    var current = getComputedStyle(document.documentElement).getPropertyValue("--chat-width");
    setWidth(parseInt(current, 10));
  });

  // Enter sends, Shift+Enter starts a line: the textarea is two rows because a prompt is
  // sometimes more than one, and a chat window that needs the mouse to send is a slow one.
  document.addEventListener("keydown", function (event) {
    if (event.key !== "Enter" || event.shiftKey) return;
    var prompt = event.target.closest && event.target.closest(".chat-prompt");
    if (!prompt) return;
    event.preventDefault();
    if (window.htmx) window.htmx.trigger(prompt.form, "submit");
  });

  // Reading a transcript is reading the end of it, and every swap either adds a message or
  // reports a step of the turn that will. `htmx:afterSwap` covers the poll and the send alike.
  document.addEventListener("htmx:afterSwap", function (event) {
    var conversation =
      event.target.id === "chat-conversation"
        ? event.target
        : document.getElementById("chat-conversation");
    if (conversation) conversation.scrollTop = conversation.scrollHeight;
  });

  document.addEventListener("DOMContentLoaded", function () {
    restoreWidth();
    var conversation = document.getElementById("chat-conversation");
    if (conversation) conversation.scrollTop = conversation.scrollHeight;
  });
})();
