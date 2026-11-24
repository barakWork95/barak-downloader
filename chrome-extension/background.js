// שולח קישור לאפליקציה דרך barak://add?url=...
// כרום מעביר קישורים כאלה למק (בפעם הראשונה הוא שואל אם לפתוח את Barak Downloader), והדף עצמו נשאר פתוח.

const SCHEME = "barak://add?url=";

function send(url, tabId) {
  if (!url || !/^https?:\/\//.test(url)) return;
  chrome.tabs.update(tabId, { url: SCHEME + encodeURIComponent(url) });
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "link", title: "הורד עם Barak ⚡", contexts: ["link"] });
  chrome.contextMenus.create({ id: "page", title: "הורד את הסרטון שבעמוד הזה", contexts: ["page", "video"] });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const url = info.menuItemId === "link" ? info.linkUrl : info.pageUrl || (tab && tab.url);
  send(url, tab.id);
});

// לחיצה על כפתור התוסף: הדף הנוכחי
chrome.action.onClicked.addListener((tab) => send(tab.url, tab.id));
