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


  function story() {
    var st = document.querySelector('.l-story');
    if (!st) return;
    var steps = [].slice.call(st.querySelectorAll('.l-step'));
    var screens = [].slice.call(st.querySelectorAll('.l-story__screen'));
    if (reduce || !('IntersectionObserver' in window)) {
      // no pinned phone: each step carries its own screen
      steps.forEach(function (s) {
        var src = screens.filter(function (f) { return f.getAttribute('data-screen') === s.getAttribute('data-screen'); })[0];
        if (src) { var c = src.cloneNode(true); c.className = 'l-story__step-shot'; c.removeAttribute('data-screen'); s.appendChild(c); }
      });
      return;
    }
    root.classList.add('l-js');
    function show(id) {
      screens.forEach(function (f) { f.classList.toggle('is-on', f.getAttribute('data-screen') === id); });
      steps.forEach(function (s) { s.classList.toggle('is-on', s.getAttribute('data-screen') === id); });
    }
    show(steps[0].getAttribute('data-screen'));
    // the step whose centre is nearest the viewport's middle wins
    var io = new IntersectionObserver(function () {
      var pin = st.querySelector('.l-story__pin'), pr = pin ? pin.getBoundingClientRect() : null;
      var top = (pr && pr.width > 0 && pr.width >= window.innerWidth * 0.8) ? Math.max(0, pr.bottom) : 0; // mobile: the phone sits above the steps
      var mid = top + (window.innerHeight - top) * 0.5, best = null, d = Infinity;
      steps.forEach(function (s) { var r = s.getBoundingClientRect(); var c = Math.abs((r.top + r.bottom) / 2 - mid); if (r.bottom > 0 && r.top < window.innerHeight && c < d) { d = c; best = s; } });
      if (best) show(best.getAttribute('data-screen'));
    }, { threshold: [0, .25, .5, .75, 1] });
    steps.forEach(function (s) { io.observe(s); });
  }

  function heroVideo() {
    var v = document.querySelector('.l-phone__video');
    if (!v) return;
    var dark = document.body.getAttribute('data-md-color-scheme') === 'slate' || (!document.body.getAttribute('data-md-color-scheme') && window.matchMedia('(prefers-color-scheme: dark)').matches);
    var base = v.getAttribute(dark ? 'data-dark' : 'data-light');
    if (!base || v.getAttribute('data-base') === base) return;
    v.setAttribute('data-base', base);
    var ss = v.querySelectorAll('source'); if (ss[0]) ss[0].src = base + '.webm'; if (ss[1]) ss[1].src = base + '.mp4';
    v.classList.remove('is-playing');
    v.addEventListener('playing', function () { v.classList.add('is-playing'); });
    v.load(); if (!reduce) v.play().catch(function () {});
    if (reduce) { v.removeAttribute('autoplay'); v.pause(); }   // the poster stays
  }

  if ('MutationObserver' in window) new MutationObserver(heroVideo).observe(document.body, { attributes: true, attributeFilter: ['data-md-color-scheme'] });
  function init() { reveal(); copy(); stage(); story(); heroVideo(); }
  if (window.document$ && window.document$.subscribe) window.document$.subscribe(init);
  else if (document.readyState !== 'loading') init(); else document.addEventListener('DOMContentLoaded', init);
})();
