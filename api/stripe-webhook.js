// POST /api/stripe-webhook : Stripe tells us a payment went through. Credits are given only after the signature is verified.
// In Stripe: Developers -> Webhooks -> Add endpoint https://YOUR-SITE/api/stripe-webhook, events checkout.session.completed and checkout.session.async_payment_succeeded.
const {crypto, env, rpc, readBody, send, safeEq} = require("./_lib");
function verify(raw, header, secret, now = Date.now()) {   // Stripe-Signature: t=timestamp,v1=hmac_sha256(secret, t + "." + body)
  if (!secret || !header) return false;
  const items = String(header).split(",").map(p => p.trim());
  const t = Number(items.find(p => p.startsWith("t="))?.slice(2)), sigs = items.filter(p => p.startsWith("v1=")).map(p => p.slice(3));
  if (!t || Math.abs(now / 1000 - t) > 300 || !sigs.length) return false;
  const expect = crypto.createHmac("sha256", secret).update(`${t}.`).update(raw).digest("hex");
  return sigs.some(s => safeEq(s, expect));
}
module.exports = async (req, res) => {
  if (req.method !== "POST") return send(res, 405, {error: "method"});
  const raw = await readBody(req);
  if (!verify(raw, req.headers["stripe-signature"], env("STRIPE_WEBHOOK_SECRET"))) return send(res, 400, {error: "bad_signature"});
  let ev; try { ev = JSON.parse(raw.toString("utf8")); } catch { return send(res, 400, {error: "bad_json"}); }
  if (ev.type === "checkout.session.completed" || ev.type === "checkout.session.async_payment_succeeded") {
    const s = ev.data?.object ?? {};
    if (s.payment_status === "paid") {
      try { await rpc("credit_order", {p_order: s.client_reference_id || s.metadata?.order_id, p_provider: "stripe", p_ref: s.id, p_amount_minor: s.amount_total, p_currency: String(s.currency ?? "").toUpperCase()}); }
      catch (e) { return send(res, 500, {error: "credit_failed"}); }   // Stripe will send it again
    }
  }
  return send(res, 200, {received: true});
};
module.exports.verify = verify;
module.exports.config = {api: {bodyParser: false}};
