// POST /api/liqpay-callback : LiqPay tells us the payment status (form fields data and signature). Credits are given only after the signature is verified.
const {env, rpc, readBody, send, safeEq, sha1b64} = require("./_lib");
module.exports = async (req, res) => {
  if (req.method !== "POST") return send(res, 405, {error: "method"});
  const f = new URLSearchParams((await readBody(req)).toString("utf8")), data = f.get("data") ?? "", signature = f.get("signature") ?? "";
  const key = env("LIQPAY_PRIVATE_KEY");
  if (!key || !data || !safeEq(signature, sha1b64(key + data + key))) return send(res, 400, {error: "bad_signature"});
  let d; try { d = JSON.parse(Buffer.from(data, "base64").toString("utf8")); } catch { return send(res, 400, {error: "bad_json"}); }
  const paid = d.status === "success" || (d.status === "sandbox" && env("LIQPAY_ALLOW_SANDBOX") === "1");
  if (paid) {
    try { await rpc("credit_order", {p_order: d.order_id, p_provider: "liqpay", p_ref: String(d.payment_id ?? d.liqpay_order_id ?? d.order_id), p_amount_minor: Math.round(Number(d.amount) * 100), p_currency: String(d.currency ?? "").toUpperCase()}); }
    catch (e) { return send(res, 500, {error: "credit_failed"}); }
  }
  return send(res, 200, {received: true});
};
module.exports.config = {api: {bodyParser: false}};
