// Tiny local server, needed for Google sign-in (Google does not allow file:// pages).
// Usage: node serve.js   then open http://localhost:5173
// Only the site files are served, so photos or other files in this folder are never exposed.
const http = require("http"), fs = require("fs"), path = require("path");
const PORT = 5173;
const files = {"/": ["index.html", "text/html; charset=utf-8"], "/index.html": ["index.html", "text/html; charset=utf-8"], "/config.js": ["config.js", "text/javascript; charset=utf-8"]};
http.createServer((req, res) => {
  const hit = files[req.url.split("?")[0]];
  if (!hit) { res.writeHead(404, {"content-type": "text/plain"}); return res.end("Not found"); }
  fs.readFile(path.join(__dirname, hit[0]), (err, data) => {
    if (err) { res.writeHead(500, {"content-type": "text/plain"}); return res.end(hit[0] + " not found"); }
    res.writeHead(200, {"content-type": hit[1], "cache-control": "no-store"});
    res.end(data);
  });
}).listen(PORT, "127.0.0.1", () => console.log("PSL Rater: http://localhost:" + PORT));
