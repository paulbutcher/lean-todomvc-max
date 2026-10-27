/*
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
*/

// `navigator.credentials` cannot be reached from markup, which is the whole reason this file
// exists. Loaded from <head> with no `defer`, as connect.js is, so nothing is looked up at parse
// time: the listener is on `document` and finds its button when the click arrives.
//
// Every binary value crosses the wire as base64url, in both directions, because that is what the
// library's routes speak.
(function () {
  "use strict";

  // The controls are rendered `hidden` and revealed here, so a browser that cannot do this is
  // offered nothing rather than a button that fails.
  if (!window.PublicKeyCredential || !navigator.credentials) return;

  document.addEventListener("DOMContentLoaded", function () {
    var blocks = document.querySelectorAll("[data-passkey]");
    for (var i = 0; i < blocks.length; i++) blocks[i].hidden = false;
  });

  function decode(text) {
    var base64 = text.replace(/-/g, "+").replace(/_/g, "/");
    return Uint8Array.from(atob(base64), function (c) {
      return c.charCodeAt(0);
    });
  }

  function encode(buffer) {
    var bytes = new Uint8Array(buffer);
    var binary = "";
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  // Every refusal answers `400` with one body that says nothing, so a refusal is simply not `ok`.
  function post(url, body) {
    var init = { method: "POST", credentials: "same-origin" };
    if (body !== undefined) {
      init.headers = { "content-type": "application/json" };
      init.body = JSON.stringify(body);
    }
    return fetch(url, init).then(function (response) {
      if (!response.ok) throw new Error("refused");
      return response.json();
    });
  }

  function signIn(button) {
    return post(button.getAttribute("data-begin"))
      .then(function (options) {
        return navigator.credentials.get({
          publicKey: {
            challenge: decode(options.challenge),
            rpId: options.rpId,
            userVerification: options.userVerification,
          },
        });
      })
      .then(function (asserted) {
        var response = asserted.response;
        return post(button.getAttribute("data-complete"), {
          id: asserted.id,
          authenticatorData: encode(response.authenticatorData),
          clientDataJSON: encode(response.clientDataJSON),
          signature: encode(response.signature),
          userHandle: response.userHandle ? encode(response.userHandle) : null,
        });
      })
      .then(function (answer) {
        if (!answer.signedIn) throw new Error("refused");
        // Already checked against the allowlist by the route, which is the only place that can.
        window.location.assign(answer.returnTo);
      });
  }

  function register(button) {
    var field = document.getElementById(button.getAttribute("data-label"));
    var label = field ? field.value.trim() : "";
    return post(button.getAttribute("data-begin"))
      .then(function (options) {
        return navigator.credentials.create({
          publicKey: {
            challenge: decode(options.challenge),
            rp: options.rp,
            user: {
              id: decode(options.user.id),
              name: options.user.name,
              displayName: options.user.displayName,
            },
            pubKeyCredParams: options.pubKeyCredParams,
            authenticatorSelection: options.authenticatorSelection,
            excludeCredentials: options.excludeCredentials.map(function (c) {
              return { type: c.type, id: decode(c.id), transports: c.transports };
            }),
          },
        });
      })
      .then(function (created) {
        var response = created.response;
        return post(button.getAttribute("data-complete"), {
          label: label,
          attestationObject: encode(response.attestationObject),
          clientDataJSON: encode(response.clientDataJSON),
          transports: response.getTransports ? response.getTransports() : [],
        });
      })
      .then(function () {
        // The page lists what the account holds, so showing the new passkey is a matter of
        // asking for the page again.
        window.location.reload();
      });
  }

  // `NotAllowedError` is what a browser reports both for a dismissed prompt and for one that
  // timed out, deliberately indistinguishable, so it is answered as the person having stopped.
  // `InvalidStateError` from `create` is the authenticator already holding a passkey for this
  // account, which `excludeCredentials` exists to catch.
  function failure(kind, error) {
    if (error && error.name === "NotAllowedError") {
      return kind === "register" ? "No passkey was added." : "Nothing was signed in.";
    }
    if (kind === "register" && error && error.name === "InvalidStateError") {
      return "This device already has a passkey for your account.";
    }
    return kind === "register"
      ? "That passkey could not be added. Try again."
      : "That passkey did not sign you in. Try again, or use your email address.";
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("[data-passkey-action]");
    if (!button || button.disabled) return;
    var kind = button.getAttribute("data-passkey-action");
    var status = document.getElementById(button.getAttribute("data-status"));
    button.disabled = true;
    if (status) status.textContent = "";
    (kind === "register" ? register(button) : signIn(button)).catch(function (error) {
      button.disabled = false;
      if (status) status.textContent = failure(kind, error);
    });
  });
})();
