(() => {
  const API_URL = '/api/chat';
  const MAX_TURNS = 10; // history sent to the server

  const fab = document.getElementById('chatFab');
  const panel = document.getElementById('chatPanel');
  const closeBtn = document.getElementById('chatClose');
  const log = document.getElementById('chatLog');
  const form = document.getElementById('chatForm');
  const input = document.getElementById('chatInput');
  const sendBtn = form.querySelector('.chat__send');
  const suggest = document.getElementById('chatSuggest');

  const history = [];
  let busy = false;
  let lastOpener = fab;

  const open = (opener) => {
    lastOpener = opener || fab;
    panel.hidden = false;
    fab.setAttribute('aria-expanded', 'true');
    setTimeout(() => input.focus(), 50);
  };
  const close = () => {
    panel.hidden = true;
    fab.setAttribute('aria-expanded', 'false');
    (lastOpener || fab).focus();
  };

  fab.addEventListener('click', () => open(fab));
  document.querySelectorAll('[data-open-chat]').forEach((b) => b.addEventListener('click', () => open(b)));
  closeBtn.addEventListener('click', close);
  panel.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });

  const addMsg = (text, who, extra) => {
    const div = document.createElement('div');
    div.className = `msg msg--${who}` + (extra ? ` ${extra}` : '');
    div.textContent = text;
    log.appendChild(div);
    log.scrollTop = log.scrollHeight;
    return div;
  };

  const addTyping = () => {
    const div = document.createElement('div');
    div.className = 'msg msg--bot typing';
    div.setAttribute('aria-label', 'Assistant is typing');
    div.innerHTML = '<span></span><span></span><span></span>';
    log.appendChild(div);
    log.scrollTop = log.scrollHeight;
    return div;
  };

  const ask = async (question) => {
    question = question.trim();
    if (!question || busy) return;
    busy = true;
    sendBtn.disabled = true;
    suggest.hidden = true;
    addMsg(question, 'user');
    input.value = '';
    const typing = addTyping();

    try {
      const res = await fetch(API_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: question, history: history.slice(-MAX_TURNS * 2) }),
      });
      const data = await res.json().catch(() => ({}));
      typing.remove();
      if (!res.ok) throw Object.assign(new Error(data.error || ''), { fromServer: Boolean(data.error) });
      addMsg(data.reply, 'bot');
      if (!data.unavailable) history.push({ role: 'user', content: question }, { role: 'assistant', content: data.reply });
    } catch (err) {
      typing.remove();
      const comingSoon = 'The AI assistant is coming soon! In the meantime, email sdfridaysd@gmail.com with any questions.';
      addMsg(err.fromServer ? err.message : comingSoon, 'bot', err.fromServer ? 'msg--err' : '');
    } finally {
      busy = false;
      sendBtn.disabled = false;
      input.focus();
    }
  };

  form.addEventListener('submit', (e) => { e.preventDefault(); ask(input.value); });
  suggest.addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) ask(b.textContent); });
})();
