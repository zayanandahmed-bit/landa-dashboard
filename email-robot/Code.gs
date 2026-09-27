/**
 * Landa Dashboard — Email robot (Google Apps Script)
 *
 * Sends alert emails FROM the Google account that owns this script
 * (zayantechtricks@gmail.com) to the addresses set in the dashboard's
 * Settings → Email alerts.
 *
 *  - "Send test email" / "Send digest now" buttons in the dashboard
 *  - Daily digest at 9 AM Pakistan time
 *  - Hourly check: emails straight away when a NEW urgent (red) alert appears
 *  - "Ask AI" page: relays questions to the Claude API. The API key is stored in this
 *    script's Script Properties, never in the browser or on GitHub.
 *
 * Setup: see README.md → "Email alerts".
 */

const SUPA_URL = 'https://ajevxwdgmpaakjkffvmf.supabase.co';
const SUPA_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFqZXZ4d2RnbXBhYWtqa2Zmdm1mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODUwNjE5NzIsImV4cCI6MjEwMDYzNzk3Mn0.bB97bHOFgCeMUTYUraOArzvXAkFRHxiajrCg3gwCGrc';
const P = 'landa_clothing_wholesale_business_';
const TZ = 'Asia/Karachi';
const DASHBOARD_URL = 'https://zayanandahmed-bit.github.io/landa-dashboard/';

/* ---------- run this once from the editor to authorise + install timers ---------- */
function setup() {
  installTriggers_();
  Logger.log('Timers installed. Emails left today: ' + MailApp.getRemainingDailyQuota());
  Logger.log('Now: Deploy → New deployment → Web app → Execute as: Me, Who has access: Anyone.');
}

function installTriggers_() {
  ScriptApp.getProjectTriggers()
    .filter(t => ['dailyDigest', 'checkUrgent'].includes(t.getHandlerFunction()))
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('dailyDigest').timeBased().everyDays(1).atHour(9).inTimezone(TZ).create();
  ScriptApp.newTrigger('checkUrgent').timeBased().everyHours(1).create();
}

/* ---------- web app: called by the dashboard ---------- */
function doGet() {
  return ContentService.createTextOutput('Landa email robot is running ✓');
}

function doPost(e) {
  try {
    const req = JSON.parse(e.postData.contents || '{}');
    const settings = getSettings_(req.token); // throws unless the caller is logged in to the dashboard
    if (req.action === 'connect') {
      if (!req.robotToken) throw new Error('Missing robot token');
      getSettings_(req.robotToken);
      PropertiesService.getScriptProperties().setProperty('ROBOT_TOKEN', req.robotToken);
      installTriggers_();
      return json_({ok: true, message: 'Email robot connected — daily digest at 9 AM, urgent alerts hourly'});
    }
    if (req.action === 'ai_status') return json_(aiStatus_());
    if (req.action === 'ai_set_key') return json_(aiSetKey_(req));
    if (req.action === 'ask') return json_({ok: true, answer: ask_(req)});
    const to = recipients_(settings);
    if (!to.length) throw new Error('No recipient emails set in Settings → Email alerts');
    if (req.action === 'test') {
      send_(settings, to, `✅ Test email — ${settings.biz_name}`, page_(settings, 'Test email',
        `<p style="font-size:15px">If you can read this, alert emails from <b>${esc_(settings.biz_name)}</b> are working. 🎉</p>
         <p>Sent from <b>${esc_(Session.getEffectiveUser().getEmail())}</b> to ${to.map(esc_).join(', ')}.</p>
         <p style="color:#6b7280">Daily digest: ${settings.email_daily_digest ? 'ON (9 AM)' : 'OFF'} · Instant urgent alerts: ${settings.email_instant_alerts ? 'ON' : 'OFF'}</p>`));
      return json_({ok: true, sentTo: to, from: Session.getEffectiveUser().getEmail()});
    }
    if (req.action === 'digest') {
      const D = loadData_(req.token);
      sendDigest_(D, to);
      return json_({ok: true, sentTo: to});
    }
    throw new Error('Unknown action');
  } catch (err) {
    return json_({ok: false, error: String(err && err.message || err)});
  }
}

/* ---------- timers ---------- */
function dailyDigest() {
  const token = robotToken_();
  if (!token) return;
  const D = loadData_(token);
  if (!D.settings.email_daily_digest) return;
  const to = recipients_(D.settings);
  if (to.length) sendDigest_(D, to);
}

function checkUrgent() {
  const token = robotToken_();
  if (!token) return;
  const D = loadData_(token);
  const props = PropertiesService.getScriptProperties();
  const urgent = computeAlerts_(D).filter(a => a.lvl === 'danger');
  const sent = JSON.parse(props.getProperty('SENT_URGENT') || '{}');
  const fresh = urgent.filter(a => !sent[a.key]);
  // remember only alerts that are still active, so one that comes back later is emailed again
  const keep = {};
  urgent.forEach(a => keep[a.key] = sent[a.key] || today_());
  props.setProperty('SENT_URGENT', JSON.stringify(keep));
  if (!fresh.length || !D.settings.email_instant_alerts) return;
  const to = recipients_(D.settings);
  if (!to.length) return;
  send_(D.settings, to, `🚨 ${fresh.length} urgent alert${fresh.length > 1 ? 's' : ''} — ${D.settings.biz_name}`,
    page_(D.settings, 'Urgent — needs action today', alertList_(fresh)));
}

/* ---------- database ---------- */
function robotToken_() {
  const t = PropertiesService.getScriptProperties().getProperty('ROBOT_TOKEN');
  if (!t) Logger.log('Not connected yet — press "Connect email robot" in the dashboard Settings.');
  return t;
}

function sb_(path, token) {
  const res = UrlFetchApp.fetch(SUPA_URL + '/rest/v1/' + path, {
    muteHttpExceptions: true,
    headers: {apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY, 'x-landa-session': token || ''},
  });
  if (res.getResponseCode() >= 300) throw new Error('Database error ' + res.getResponseCode() + ': ' + res.getContentText());
  return JSON.parse(res.getContentText() || '[]');
}

function all_(path, token) {
  let out = [];
  for (let off = 0; ; off += 1000) {
    const d = sb_(path + '&limit=1000&offset=' + off, token);
    out = out.concat(d);
    if (d.length < 1000) return out;
  }
}

function getSettings_(token) {
  if (!token) throw new Error('Not logged in');
  const r = sb_(P + 'settings?select=*&id=eq.1', token);
  if (!r.length) throw new Error('Not logged in (session expired) — log in to the dashboard again');
  return r[0];
}

function loadData_(token) {
  const settings = getSettings_(token);
  const stock = all_(P + 'stock_items?select=category,grade,qty,price,min_qty&order=category,grade', token);
  const bales = all_(P + 'bales_received?select=id,received_date,supplier,bale_type,weight_kg,cost,status&order=id', token);
  const customers = all_(P + 'wholesale_customers?select=id,name,credit_limit&order=id', token);
  const orders = all_(P + 'customer_orders?select=id,order_date,customer_id,status,paid&order=id', token);
  const lines = all_(P + 'customer_order_lines?select=order_id,category,grade,qty,price&order=id', token);
  const byId = {};
  orders.forEach(o => { o.lines = []; byId[o.id] = o; });
  lines.forEach(l => { if (byId[l.order_id]) byId[l.order_id].lines.push(l); });
  return {settings, stock, bales, customers, orders};
}

/* ---------- alerts (same rules as the dashboard) ---------- */
const today_ = () => Utilities.formatDate(new Date(), TZ, 'yyyy-MM-dd');
const age_ = d => Math.round((new Date(today_()) - new Date(d)) / 864e5);
const total_ = o => o.lines.reduce((s, l) => s + l.qty * Number(l.price), 0);
const due_ = o => o.status === 'cancelled' ? 0 : total_(o) - Number(o.paid);
const rs_ = n => 'Rs ' + Math.round(Number(n) || 0).toLocaleString('en-US');
const esc_ = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));

function velocity_(D, days) {
  const v = {};
  D.orders.filter(o => o.status !== 'cancelled' && age_(o.order_date) < days)
    .forEach(o => o.lines.forEach(l => { const k = l.category + ' · ' + l.grade; v[k] = (v[k] || 0) + l.qty; }));
  return v;
}

function computeAlerts_(D) {
  const st = D.settings, A = [], v = velocity_(D, 14);
  const name = id => (D.customers.find(c => c.id === id) || {name: id}).name;
  D.stock.forEach(s => {
    const k = s.category + ' · ' + s.grade;
    if (s.min_qty > 0 && s.qty <= s.min_qty)
      A.push({lvl: s.qty <= 0 ? 'danger' : 'warn', type: s.qty <= 0 ? 'Out of stock' : 'Low stock', key: 'low:' + k + (s.qty <= 0 ? ':out' : ''), text: `${k} is down to ${s.qty} pcs (minimum ${s.min_qty})`});
    else if (v[k] && s.qty > 0) {
      const cover = s.qty / (v[k] / 14);
      if (cover <= st.runout_days) A.push({lvl: 'info', type: 'Selling fast', key: 'fast:' + k, text: `${k} will run out in ~${Math.max(1, Math.round(cover))} days at current pace (${v[k]} sold in 14 days)`});
    }
  });
  D.bales.filter(b => b.status !== 'sorted' && age_(b.received_date) >= st.sort_days)
    .forEach(b => A.push({lvl: 'warn', type: 'Sorting delay', key: 'sort:' + b.id, text: `Bale ${b.id} (${b.bale_type}) arrived ${age_(b.received_date)} days ago and isn't finished — ${rs_(b.cost)} of cash sitting idle`}));
  D.orders.filter(o => (o.status === 'new' || o.status === 'packed') && age_(o.order_date) >= st.dispatch_days)
    .forEach(o => A.push({lvl: 'warn', type: 'Dispatch late', key: 'disp:' + o.id, text: `${o.id} for ${name(o.customer_id)} is ${o.status} but not sent — ${age_(o.order_date)} days old`}));
  D.orders.filter(o => due_(o) > 0 && age_(o.order_date) >= st.due_days)
    .forEach(o => A.push({lvl: 'danger', type: 'Payment overdue', key: 'due:' + o.id, text: `${name(o.customer_id)} owes ${rs_(due_(o))} on ${o.id} (${age_(o.order_date)} days)`}));
  D.customers.forEach(c => {
    const d = D.orders.filter(o => o.customer_id === c.id).reduce((s, o) => s + due_(o), 0);
    if (Number(c.credit_limit) && d > Number(c.credit_limit))
      A.push({lvl: 'danger', type: 'Credit limit', key: 'credit:' + c.id, text: `${c.name} owes ${rs_(d)} — over their ${rs_(c.credit_limit)} limit. Hold new orders until paid.`});
  });
  const rank = {danger: 0, warn: 1, info: 2};
  return A.sort((a, b) => rank[a.lvl] - rank[b.lvl]);
}

/* ---------- emails ---------- */
function recipients_(settings) {
  return String(settings.alert_email || '').split(/[\s,;]+/).map(s => s.trim()).filter(s => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s));
}

function send_(settings, to, subject, html) {
  MailApp.sendEmail({to: to.join(','), subject: subject, htmlBody: html, name: settings.biz_name});
}

function alertList_(A) {
  const col = {danger: ['#fee2e2', '#b91c1c'], warn: ['#fef3c7', '#b45309'], info: ['#dbeafe', '#1d4ed8']};
  return A.map(a => `<div style="background:${col[a.lvl][0]};border-radius:10px;padding:10px 12px;margin:0 0 8px">
    <div style="font-size:11px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;color:${col[a.lvl][1]}">${esc_(a.type)}</div>
    <div style="font-size:14px;color:#1c2230">${esc_(a.text)}</div></div>`).join('');
}

function page_(settings, title, inner) {
  return `<div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:620px;margin:0 auto;color:#1c2230">
    <div style="background:#111827;color:#fff;padding:16px 20px;border-radius:12px 12px 0 0">
      <div style="font-size:18px;font-weight:700">${esc_(settings.biz_name)}</div>
      <div style="color:#94a3b8;font-size:13px">${esc_(title)} · ${today_()}</div></div>
    <div style="border:1px solid #e5e7eb;border-top:0;border-radius:0 0 12px 12px;padding:18px 20px">${inner}
      <p style="margin-top:18px"><a href="${DASHBOARD_URL}" style="background:#0f766e;color:#fff;padding:9px 16px;border-radius:8px;text-decoration:none;font-weight:600">Open dashboard</a></p></div></div>`;
}

function sendDigest_(D, to) {
  const A = computeAlerts_(D);
  const month = today_().slice(0, 7);
  const live = D.orders.filter(o => o.status !== 'cancelled');
  const sales = live.filter(o => o.order_date.slice(0, 7) === month).reduce((s, o) => s + total_(o), 0);
  const collect = D.orders.reduce((s, o) => s + due_(o), 0);
  const pcs = D.stock.reduce((s, x) => s + x.qty, 0);
  const value = D.stock.reduce((s, x) => s + x.qty * Number(x.price), 0);
  const v30 = velocity_(D, 30);
  const best = Object.keys(v30).sort((a, b) => v30[b] - v30[a])[0];
  const kpi = (l, v) => `<td style="padding:10px;background:#f8fafc;border-radius:8px"><div style="font-size:11px;color:#6b7280;text-transform:uppercase">${l}</div><div style="font-size:17px;font-weight:700">${v}</div></td>`;
  const reds = A.filter(a => a.lvl === 'danger').length, ambers = A.filter(a => a.lvl === 'warn').length;
  const html = page_(D.settings, 'Daily digest', `
    <table style="width:100%;border-spacing:6px;margin:0 -6px 12px"><tr>
      ${kpi('🏆 Best seller · 30d', best ? esc_(best) + ` <span style="font-weight:400;color:#6b7280">(${v30[best]} pcs)</span>` : '—')}
      ${kpi('Sales this month', rs_(sales))}</tr><tr>
      ${kpi('Money to collect', rs_(collect))}
      ${kpi('Stock on hand', pcs.toLocaleString('en-US') + ' pcs · ' + rs_(value))}</tr></table>
    <h3 style="margin:14px 0 8px">${A.length ? `${reds} urgent · ${ambers} falling behind · ${A.length - reds - ambers} signals` : 'All clear 👌'}</h3>
    ${alertList_(A)}`);
  send_(D.settings, to, `${reds ? '🔴' : ambers ? '🟠' : '🟢'} ${D.settings.biz_name} — daily digest (${A.length} alerts)`, html);
}

/* ---------- AI assistant ---------- */
const AI_DEFAULT_MODEL = 'claude-opus-5';
const AI_SYSTEM = `You are the business analyst inside the dashboard of a landa (bulk used-clothing bale) wholesale business in Pakistan. The owner buys bales from suppliers, sorts the pieces by category and grade (A, B, C, Reject), and sells to wholesalers, who often pay on credit. All money is in Pakistani rupees (Rs).

Answer only from the BUSINESS DATA below. Never invent numbers; if the data cannot answer the question, say what is missing. Be concise and practical: lead with the answer, then the key numbers, then one or two clear actions. Use short bullet points or a small markdown table when it helps. The owner writes casual English, so keep the tone plain and friendly. Show Rs amounts with thousands separators.`;

function aiStatus_() {
  const p = PropertiesService.getScriptProperties(), key = p.getProperty('AI_KEY');
  return {ok: true, configured: !!key, model: p.getProperty('AI_MODEL') || AI_DEFAULT_MODEL, keyHint: key ? '…' + key.slice(-4) : ''};
}

function aiSetKey_(req) {
  const p = PropertiesService.getScriptProperties();
  if (req.key) {
    const k = String(req.key).trim();
    if (!/^sk-ant-[A-Za-z0-9_-]{20,}$/.test(k)) throw new Error('That does not look like an Anthropic API key (it should start with sk-ant-)');
    p.setProperty('AI_KEY', k);
  }
  if (req.model) {
    const m = String(req.model).trim();
    if (!/^claude-[a-z0-9.-]+$/.test(m)) throw new Error('Model names look like claude-opus-5');
    p.setProperty('AI_MODEL', m);
  }
  return aiStatus_();
}

function ask_(req) {
  const p = PropertiesService.getScriptProperties();
  const key = p.getProperty('AI_KEY');
  if (!key) throw new Error('The AI key is not set yet — add it in Settings → AI assistant');
  const model = p.getProperty('AI_MODEL') || AI_DEFAULT_MODEL;
  const question = String(req.question || '').trim().slice(0, 2000);
  if (!question) throw new Error('Type a question first');
  const context = String(req.context || '').slice(0, 200000);
  const history = (Array.isArray(req.history) ? req.history : []).slice(-8)
    .filter(m => (m.role === 'user' || m.role === 'assistant') && typeof m.text === 'string')
    .map(m => ({role: m.role, content: m.text.slice(0, 6000)}));
  while (history.length && history[0].role !== 'user') history.shift();
  const messages = history.concat([{role: 'user', content: question}]);

  const body = {
    model: model,
    max_tokens: 4096,
    output_config: {effort: 'medium'},
    system: [
      {type: 'text', text: AI_SYSTEM},
      // same data on every question in a chat, so cache it — follow-up questions cost a fraction
      {type: 'text', text: 'BUSINESS DATA (JSON):\n' + context, cache_control: {type: 'ephemeral'}},
    ],
    messages: messages,
  };
  const headers = {'x-api-key': key, 'anthropic-version': '2023-06-01'};
  if (/^claude-(opus-5|fable-5-1)$/.test(model)) {   // route refusals to a fallback model automatically
    body.fallbacks = 'default';
    headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
  }
  const res = UrlFetchApp.fetch('https://api.anthropic.com/v1/messages', {
    method: 'post', contentType: 'application/json', headers: headers, payload: JSON.stringify(body), muteHttpExceptions: true,
  });
  const code = res.getResponseCode(), text = res.getContentText();
  let data; try { data = JSON.parse(text); } catch (e) { data = {}; }
  if (code >= 300) {
    if (code === 401) throw new Error('Anthropic rejected the API key — check it in Settings → AI assistant');
    throw new Error('Claude error ' + code + ': ' + ((data.error && data.error.message) || text.slice(0, 300)));
  }
  if (data.stop_reason === 'refusal') throw new Error('Claude declined to answer that one — try rephrasing it');
  const answer = (data.content || []).filter(b => b.type === 'text').map(b => b.text).join('\n').trim();
  if (!answer) throw new Error('Claude sent back an empty answer — try again');
  return data.stop_reason === 'max_tokens' ? answer + '\n\n_(answer was cut short — ask me to continue)_' : answer;
}

function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
