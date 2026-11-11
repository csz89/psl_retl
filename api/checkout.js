// POST /api/checkout  {pack, currency, provider}  with  Authorization: Bearer <the player's Supabase token>
// Creates an order at the price from the database (the browser cannot choose the price) and returns where to pay.
const {env, rpc, userFromToken, readBody, send, siteUrl, sha1b64} = require("./_lib");
const LIQPAY_CURRENCIES = ["UAH", "USD", "EUR"];
module.exports = async (req, res) => {
  if (req.method !== "POST") return send(res, 405, {error: "method"});
  try {
    const token = String(req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
    if (!token) return send(res, 401, {error: "no_token"});
    let b; try { b = JSON.parse((await readBody(req)).toString("utf8") || "{}"); } catch { return send(res, 400, {error: "bad_json"}); }
    const pack = String(b.pack ?? ""), currency = String(b.currency ?? "").toUpperCase(), provider = String(b.provider ?? "");
    if (!["stripe", "liqpay"].includes(provider) || !/^[a-z0-9_]{1,40}$/.test(pack) || !/^[A-Z]{3}$/.test(currency)) return send(res, 400, {error: "bad_request"});
    if (!env("SUPABASE_URL") || !env("SUPABASE_SERVICE_ROLE_KEY")) return send(res, 503, {error: "not_configured"});
    if (provider === "stripe" && !env("STRIPE_SECRET_KEY")) return send(res, 503, {error: "not_configured"});
    if (provider === "liqpay" && !(env("LIQPAY_PUBLIC_KEY") && env("LIQPAY_PRIVATE_KEY"))) return send(res, 503, {error: "not_configured"});
    if (provider === "liqpay" && !LIQPAY_CURRENCIES.includes(currency)) return send(res, 400, {error: "currency_not_supported"});
    const user = await userFromToken(token);
    if (!user?.id) return send(res, 401, {error: "bad_token"});
    let order;
    try { order = await rpc("create_order", {p_player: user.id, p_pack: pack, p_currency: currency, p_provider: provider}); }
    catch (e) { const code = /no_price|no_pack|not_joined/.exec(e.message)?.[0]; return send(res, code ? 400 : 502, {error: code ?? "order_failed"}); }
    const site = siteUrl(req), name = `${order.amount} ${order.kind === "rates" ? "рейтов" : "игр"} (PSL Rater)`;
    if (provider === "stripe") {
      const f = new URLSearchParams({
        mode: "payment", success_url: `${site}/#/donate?paid=1`, cancel_url: `${site}/#/donate`, client_reference_id: order.id,
        "metadata[order_id]": order.id, "line_items[0][quantity]": "1", "line_items[0][price_data][currency]": currency.toLowerCase(),
        "line_items[0][price_data][unit_amount]": String(order.amount_minor), "line_items[0][price_data][product_data][name]": name,
      });
      const r = await fetch("https://api.stripe.com/v1/checkout/sessions", {method: "POST", headers: {authorization: "Bearer " + env("STRIPE_SECRET_KEY"), "content-type": "application/x-www-form-urlencoded"}, body: f});
      const s = await r.json();
      if (!r.ok || !s.url) return send(res, 502, {error: "provider_failed"});
      return send(res, 200, {provider, url: s.url});
    }
    const data = Buffer.from(JSON.stringify({version: 3, public_key: env("LIQPAY_PUBLIC_KEY"), action: "pay", amount: Number((order.amount_minor / 100).toFixed(2)), currency, description: name,
      order_id: order.id, result_url: `${site}/#/donate?paid=1`, server_url: `${site}/api/liqpay-callback`, language: "ru", ...(env("LIQPAY_ALLOW_SANDBOX") === "1" ? {sandbox: 1} : {})})).toString("base64");   // sandbox: LiqPay test mode, nothing is charged
    return send(res, 200, {provider, action: "https://www.liqpay.ua/api/3/checkout", data, signature: sha1b64(env("LIQPAY_PRIVATE_KEY") + data + env("LIQPAY_PRIVATE_KEY"))});
  } catch (e) { return send(res, 500, {error: "server_error"}); }
};
module.exports.config = {api: {bodyParser: false}};
