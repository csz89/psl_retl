// Tiny local server, needed for Google sign-in (Google does not allow file:// pages).
// Usage: node serve.js   then open http://localhost:5173
// Only index.html is served, so photos or other files in this folder are never exposed.
const http = require("http"), fs = require("fs"), path = require("path");
const PORT = 5173, page = path.join(__dirname, "index.html");
http.createServer((req, res) => {
  const url = req.url.split("?")[0];
  if (url !== "/" && url !== "/index.html") { res.writeHead(404, {"content-type": "text/plain"}); return res.end("Not found"); }
  fs.readFile(page, (err, data) => {
    if (err) { res.writeHead(500, {"content-type": "text/plain"}); return res.end("index.html not found"); }
    res.writeHead(200, {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"});
    res.end(data);
  });
}).listen(PORT, "127.0.0.1", () => console.log("PSL Rater: http://localhost:" + PORT));
