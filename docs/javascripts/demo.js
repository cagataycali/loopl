/* loopl.dev landing demo — replays the agent run captured on an iPhone 16 Pro
   (core2/device-proof/selftest-qwen3-1.7b-4bit.log, 2026-10-05 10:50:53–59Z) at ~2× speed.
   Progressive: without JS every row is simply visible. Reduced motion → final state, no replay. */
(function () {
  var demo = document.querySelector('.loopl-demo');
  if (!demo || !('IntersectionObserver' in window)) return;
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var steps = Array.prototype.slice.call(demo.querySelectorAll('[data-step]'));
  var status = demo.querySelector('.loopl-demo__status');
  var answer = demo.querySelector('.loopl-demo__a p');
  var replay = demo.querySelector('.loopl-demo__replay');
  var answerText = answer ? answer.getAttribute('data-text') : '';
  var timers = [], playing = false;

  // real timeline (device): cycle 1 3.0 s → 4 tools at once (<1 ms each) → cycle 2 3.0 s → "1081" → end_turn
  var script = [
    [0,    function () { say('cycle 1 · streaming… (3.0 s on device)'); }],
    [900,  function () { show('tool', 90); }],
    [1500, function () { say('cycle 2 · streaming… (3.0 s on device)'); }],
    [2300, function () { show('answer'); type(answerText, 90); }],
    [2800, function () { show('foot'); say('end_turn · 2 cycles · 5.8 s on device · replayed at ~2×'); demo.removeAttribute('data-playing'); playing = false; }]
  ];

  function say(t) { if (status) status.textContent = t; }
  function show(kind, stagger) {
    steps.filter(function (s) { return s.getAttribute('data-step') === kind; })
      .forEach(function (s, i) { timers.push(setTimeout(function () { s.classList.add('is-on'); }, (stagger || 0) * i)); });
  }
  function type(text, ms) {
    if (!answer) return; answer.textContent = '';
    for (var i = 1; i <= text.length; i++) (function (n) { timers.push(setTimeout(function () { answer.textContent = text.slice(0, n); }, ms * n)); })(i);
  }
  function reset() {
    timers.forEach(clearTimeout); timers = [];
    steps.forEach(function (s) { s.classList.remove('is-on'); });
    if (answer) answer.textContent = '';
  }
  function finalState() {
    reset(); steps.forEach(function (s) { s.classList.add('is-on'); });
    if (answer) answer.textContent = answerText; say('end_turn · 2 cycles · 5.8 s on device');
  }
  function play() {
    if (reduce) return finalState();
    reset(); playing = true; demo.setAttribute('data-playing', '');
    script.forEach(function (st) { timers.push(setTimeout(st[1], st[0])); });
  }

  demo.setAttribute('data-js', '');
  if (reduce) { finalState(); if (replay) replay.hidden = true; return; }
  var seen = false;
  new IntersectionObserver(function (entries, io) {
    if (entries.some(function (e) { return e.isIntersecting; }) && !seen) { seen = true; play(); io.disconnect(); }
  }, { threshold: 0.25 }).observe(demo);
  if (replay) replay.addEventListener('click', function () { if (!playing) play(); });
  setTimeout(function () { if (!seen) finalState(); }, 12000);   // never leave the card blank (print, odd viewports)
})();
