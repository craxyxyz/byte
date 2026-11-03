// Byte 2.0 © 2026 Apurba Laskar.
// Web playback through the official embedded player (visible, small, docked
// above the mini player). Byte drives it: load / play / pause / seek and
// reads its time; when a song can't play here it says so at once.
(function () {
  var box = null, player = null, ready = false, pending = null, apiAsked = false;
  var st = { t: 0, d: 0, s: -1, e: 0, n: 0, ready: false, id: '' };
  function el() {
    if (box) return box;
    box = document.createElement('div');
    box.id = 'byte-embed';
    box.setAttribute('aria-label', 'Now playing video');
    box.style.cssText = 'position:fixed;right:12px;bottom:150px;width:200px;height:113px;border-radius:12px;overflow:hidden;' +
      'z-index:20;box-shadow:0 6px 24px rgba(0,0,0,.28);background:#000;display:none;transition:opacity .2s';
    var inner = document.createElement('div');
    inner.id = 'byte-embed-player';
    box.appendChild(inner);
    document.body.appendChild(box);
    return box;
  }
  function make(id, start) {
    el().style.display = 'block';
    player = new YT.Player('byte-embed-player', {
      width: '200', height: '113', videoId: id,
      playerVars: { autoplay: 1, playsinline: 1, controls: 1, rel: 0, start: Math.floor(start || 0), origin: location.origin },
      events: {
        onReady: function () { ready = true; st.ready = true; try { player.playVideo(); } catch (e) {} },
        onStateChange: function (ev) { st.s = ev.data; if (ev.data === 0) st.n++; },
        onError: function (ev) { st.e = ev.data || 1; }
      }
    });
  }
  window.onYouTubeIframeAPIReady = function () {
    if (pending) { var p = pending; pending = null; make(p[0], p[1]); }
  };
  function askApi() {
    if (apiAsked) return;
    apiAsked = true;
    var s = document.createElement('script');
    s.src = 'https://www.youtube.com/iframe_api';
    s.onerror = function () { st.e = 'api'; };
    document.head.appendChild(s);
  }
  window.byteEmbed = {
    load: function (id, start) {
      st.e = 0; st.s = -1; st.t = start || 0; st.d = 0; st.id = id;
      if (player && ready) {
        el().style.display = 'block';
        player.loadVideoById({ videoId: id, startSeconds: start || 0 });
        return;
      }
      if (window.YT && window.YT.Player) { if (!player) make(id, start); else pending = [id, start]; return; }
      pending = [id, start];
      askApi();
    },
    play: function () { try { player && player.playVideo(); } catch (e) {} },
    pause: function () { try { player && player.pauseVideo(); } catch (e) {} },
    seek: function (s) { try { player && player.seekTo(s, true); } catch (e) {} },
    volume: function (v) { try { player && player.setVolume(Math.round(v * 100)); } catch (e) {} },
    hide: function () { try { player && player.stopVideo(); } catch (e) {} if (box) box.style.display = 'none'; },
    snap: function () {
      if (player && ready) {
        try { st.t = player.getCurrentTime() || 0; st.d = player.getDuration() || 0; } catch (e) {}
      }
      return JSON.stringify(st);
    }
  };
})();
