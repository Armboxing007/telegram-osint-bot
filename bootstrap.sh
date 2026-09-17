
#!/bin/bash
set -e
npm init -y
npm install telegraf better-sqlite3 dotenv node-fetch
npm install -D typescript ts-node @types/node
mkdir -p src

cat > src/index.ts << 'EOF'
import { Telegraf } from 'telegraf';
import 'dotenv/config';
import Database from 'better-sqlite3';
import { detectInputType } from './detector';
import { searchWeb } from './search';

const bot = new Telegraf(process.env.TELEGRAM_BOT_TOKEN!);
const db = new Database('osint.db');

db.exec(`CREATE TABLE IF NOT EXISTS investigations (id TEXT PRIMARY KEY, user_id TEXT, type TEXT, input TEXT, status TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP); CREATE TABLE IF NOT EXISTS findings (id INTEGER PRIMARY KEY AUTOINCREMENT, investigation_id TEXT, title TEXT, url TEXT, snippet TEXT);`);

bot.start((ctx) => ctx.reply('👋 OSINT Bot\n\nОтправь: phone, email, username, domain.\n/help'));
bot.help((ctx) => ctx.reply('Отправь данные — тип определится автоматически.'));

bot.on('text', async (ctx) => {
  const text = ctx.message.text;
  if (text.startsWith('/')) return;
  const d = detectInputType(text);
  if (d.type === 'UNKNOWN') return ctx.reply('🤔 Не понял тип.');
  const id = Math.random().toString(36).slice(2, 10);
  db.prepare('INSERT INTO investigations (id, user_id, type, input, status) VALUES (?, ?, ?, ?, ?)')
    .run(id, String(ctx.from.id), d.type, d.value, 'RUNNING');
  const msg = await ctx.reply(`🔎 Started\nType: ${d.type}\nInput: ${d.value}\nID: ${id}\n⏳...`);
  try {
    const results = await searchWeb(d.value);
    const ins = db.prepare('INSERT INTO findings (investigation_id, title, url, snippet) VALUES (?, ?, ?, ?)');
    for (const r of results) ins.run(id, r.title, r.url, r.snippet);
    db.prepare('UPDATE investigations SET status = ? WHERE id = ?').run('COMPLETED', id);
    await ctx.telegram.editMessageText(ctx.chat.id, msg.message_id, undefined,
      `✅ Complete\nType: ${d.type}\nID: ${id}\nFindings: ${results.length}`);
  } catch (e: any) {
    db.prepare('UPDATE investigations SET status = ? WHERE id = ?').run('FAILED', id);
    await ctx.telegram.editMessageText(ctx.chat.id, msg.message_id, undefined, `❌ ${e.message}`);
  }
});

bot.launch();
console.log('Bot started');
EOF

cat > src/detector.ts << 'EOF'
export function detectInputType(input: string): { type: string; value: string } {
  const s = input.trim();
  if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s)) return { type: 'EMAIL', value: s };
  if (/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$/i.test(s)) return { type: 'DOMAIN', value: s };
  const digits = s.replace(/\D/g, '');
  if (digits.length >= 7 && digits.length <= 15 && /^[+\d\s\-\(\)]+$/.test(s)) return { type: 'PHONE', value: s };
  if (/^[a-zA-Z0-9_\.]{3,32}$/.test(s)) return { type: 'USERNAME', value: s };
  return { type: 'UNKNOWN', value: s };
}
EOF

cat > src/search.ts << 'EOF'
export async function searchWeb(query: string) {
  const key = process.env.SEARCH_API_KEY;
  const cx = process.env.SEARCH_ENGINE_ID;
  if (!key || !cx) return [];
  const url = new URL('https://www.googleapis.com/customsearch/v1');
  url.searchParams.set('key', key);
  url.searchParams.set('cx', cx);
  url.searchParams.set('q', `"${query}"`);
  url.searchParams.set('num', '10');
  const res = await fetch(url.toString());
  if (!res.ok) return [];
  const data: any = await res.json();
  return (data.items || []).map((i: any) => ({ title: i.title, url: i.link, snippet: i.snippet }));
}
EOF

cat > .env.example << 'EOF'
TELEGRAM_BOT_TOKEN=
SEARCH_API_KEY=
SEARCH_ENGINE_ID=
EOF

cat > README.md << 'EOF'
# Telegram OSINT Bot
Run: npx ts-node src/index.ts
EOF
