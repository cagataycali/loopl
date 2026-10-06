/* loopl.dev — reveal on scroll, copy button, and the landing's live turn.
   Progressive: without JS everything is visible in its final state. Reduced motion → final state, no animation.
   Re-runs on Material's instant navigation (document$). */
(function () {
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var root = document.documentElement;

  function reveal() {
    var els = document.querySelectorAll('.l-reveal');
    if (!els.length || reduce || !('IntersectionObserver' in window)) return;
    root.classList.add('l-js');
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('is-on'); io.unobserve(e.target); } });
    }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });
    els.forEach(function (el) { io.observe(el); });
    setTimeout(function () { els.forEach(function (el) { el.classList.add('is-on'); }); }, 4000); // never leave content hidden
  }

  function copy() {
    document.querySelectorAll('[data-copy]').forEach(function (b) {
      b.addEventListener('click', function () {
        (navigator.clipboard ? navigator.clipboard.writeText(b.getAttribute('data-copy')) : Promise.reject())
          .then(function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1400); })
          .catch(function () {});
      });
    });
  }

  function stage() {
    var s = document.querySelector('.l-stage');
    if (!s || reduce) { var r = document.querySelector('.l-ring'); if (r && r.pauseAnimations) r.pauseAnimations(); return; }
    var steps = [].slice.call(s.querySelectorAll('[data-step]'));
    var calls = [].slice.call(s.querySelectorAll('.l-call'));
    var out = s.querySelector('[data-stream]');
    var text = out ? out.getAttribute('data-stream') : '';
    var timers = [], playing = false;
    function at(ms, fn) { timers.push(setTimeout(fn, ms)); }
    function reset() {
      timers.forEach(clearTimeout); timers = [];
      steps.forEach(function (x) { x.classList.remove('is-on'); });
      calls.forEach(function (c) { c.classList.remove('is-done'); });
      if (out) out.textContent = '';
      s.removeAttribute('data-typing');
    }
    function play() {
      if (playing) return; playing = true; reset();
      at(200, function () { steps[0].classList.add('is-on'); });
      calls.forEach(function (c, i) {                 // both calls start together — they run concurrently
        at(1100 + i * 120, function () { c.classList.add('is-on'); });
        at(1900 + i * 380, function () { c.classList.add('is-done'); });
      });
      at(2900, function () {
        var a = s.querySelector('[data-step="answer"]'); a.classList.add('is-on'); s.setAttribute('data-typing', '');
        var words = text.split(/(\s+)/), n = 0;
        (function tick() {                             // stream in 1–3 word chunks, like a real model
          if (n >= words.length) { at(600, function () { s.removeAttribute('data-typing'); playing = false; }); return; }
          var k = 1 + Math.floor(Math.random() * 3); out.textContent += words.slice(n, n + k).join(''); n += k;
          at(55 + Math.random() * 70, tick);
        })();
      });
    }
    root.classList.add('l-js');
    var rb = s.querySelector('.l-replay'); if (rb) rb.addEventListener('click', function () { playing = false; play(); });
    var seen = false;
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (es, io) {
        if (!seen && es.some(function (e) { return e.isIntersecting; })) { seen = true; io.disconnect(); play(); }
      }, { threshold: 0.35 }).observe(s);
    } else { play(); }
  }

  function init() { reveal(); copy(); stage(); }
  if (window.document$ && window.document$.subscribe) window.document$.subscribe(init);
  else if (document.readyState !== 'loading') init(); else document.addEventListener('DOMContentLoaded', init);
})();
