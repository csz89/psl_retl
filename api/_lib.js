// Shared helpers of the payment functions. The name starts with "_", so Vercel does not publish this file as a URL.
// Secrets come from the environment variables of the Vercel project (Settings -> Environment Variables), never from the site files:
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY            (all payments)
//   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET                              (cards through Stripe)
//   LIQPAY_PUBLIC_KEY, LIQPAY_PRIVATE_KEY                                 (LiqPay, hryvnia), LIQPAY_ALLOW_SANDBOX=1 only for tests
//   SITE_URL                                                              (optional: https://your-site.vercel.app)
const crypto = require("crypto");
const env = k => String(process.env[k] ?? "").trim();
const supabaseUrl = () => env("SUPABASE_URL").replace(/\/+$/, "");

async function rpc(fn, args) {   // calls a database function with the service key (the browser never has it)
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const r = await fetch(`${supabaseUrl()}/rest/v1/rpc/${fn}`, {method: "POST", headers: {apikey: key, authorization: "Bearer " + key, "content-type": "application/json"}, body: JSON.stringify(args)});
  const text = await r.text();
  let data = null; try { data = text ? JSON.parse(text) : null; } catch {}
  if (!r.ok) { const e = new Error(data?.message ?? `database error ${r.status}`); e.status = r.status; throw e; }
  return data;
}
async function userFromToken(token) {   // the signed-in player the browser claims to be: asked from Supabase, never trusted from the request
  const r = await fetch(`${supabaseUrl()}/auth/v1/user`, {headers: {apikey: env("SUPABASE_ANON_KEY") || env("SUPABASE_SERVICE_ROLE_KEY"), authorization: "Bearer " + token}});
  return r.ok ? r.json() : null;
}
async function readBody(req) {   // the raw bytes: the signatures are computed over them
  if (Buffer.isBuffer(req.body)) return req.body;
  if (typeof req.body === "string") return Buffer.from(req.body);
  const chunks = []; for await (const c of req) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
  return Buffer.concat(chunks);
}
const send = (res, code, obj) => { res.statusCode = code; res.setHeader("content-type", "application/json; charset=utf-8"); res.end(JSON.stringify(obj)); };
const siteUrl = req => env("SITE_URL").replace(/\/+$/, "") || `https://${req.headers["x-forwarded-host"] ?? req.headers.host}`;
const safeEq = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
const sha1b64 = s => crypto.createHash("sha1").update(s).digest("base64");   // LiqPay signs with base64(sha1(private + data + private))
module.exports = {crypto, env, rpc, userFromToken, readBody, send, siteUrl, safeEq, sha1b64};
