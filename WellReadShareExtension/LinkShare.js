//
//  LinkShare.js
//  WellReadShareExtension
//
//  Safari runs this in the shared page before handing the share to SPINE, so
//  the app gets the page's visible text without fetching the URL again. That
//  matters for pages an anonymous fetch can't see (paywalls, logged-in feeds,
//  bot walls). Referenced from Info.plist as NSExtensionJavaScriptPreprocessingFile.
//

var LinkShare = function () {};

LinkShare.prototype = {
    run: function (arguments) {
        var meta = function (name) {
            try {
                var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
                return el ? (el.getAttribute("content") || "") : "";
            } catch (e) {
                return "";
            }
        };
        var text = "";
        try {
            text = (document.body && document.body.innerText) || "";
        } catch (e) {
            text = "";
        }
        // Enough for a long listicle; the app trims further before the model sees it.
        var maxChars = 60000;
        if (text.length > maxChars) {
            text = text.substring(0, maxChars);
        }
        arguments.completionFunction({
            "url": document.URL || "",
            "title": document.title || meta("og:title") || "",
            "description": meta("og:description") || meta("description") || "",
            "text": text
        });
    },

    finalize: function (arguments) {}
};

var ExtensionPreprocessingJS = new LinkShare();
