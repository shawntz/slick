// Slick website. The page is complete without this file. With it, the page:
// - adds the download button and the version line when data/release.json turns the download on,
// - redraws the feature list from data/features.json,
// - takes alt text from media/manifest.json and plays the recording behind each clip slot,
// - switches the hero clip between dark and light, and copies the install command.
// This file only requests local assets. The HTML loads Seline analytics separately.
(() => {
  'use strict';

  const doc = document;
  const SVG = 'http://www.w3.org/2000/svg';
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const lightScheme = matchMedia('(prefers-color-scheme: light)');

  const getJSON = (url) =>
    fetch(url, { cache: 'no-cache', credentials: 'same-origin' }).then((response) => {
      if (!response.ok) throw new Error(`${url}: ${response.status}`);
      return response.json();
    });

  function h(tag, attrs, ...children) {
    const node = doc.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value === null || value === undefined) continue;
      if (key === 'class') node.className = value;
      else node.setAttribute(key, value);
    }
    node.append(...children.filter((child) => child !== null && child !== undefined));
    return node;
  }

  function svgIcon(path) {
    const svg = doc.createElementNS(SVG, 'svg');
    const attrs = {
      class: 'icon', 'aria-hidden': 'true', focusable: 'false', width: '18', height: '18', viewBox: '0 0 16 16',
      fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6', 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
    };
    for (const [key, value] of Object.entries(attrs)) svg.setAttribute(key, value);
    const shape = doc.createElementNS(SVG, 'path');
    shape.setAttribute('d', path);
    svg.append(shape);
    return svg;
  }

  // Download switch. Only when data/release.json has enabled: true and a URL does this add the
  // download button and set the version line. The Install section
  // is plain HTML, edited by hand for each release.

  function applyRelease(release) {
    const download = release && release.download;
    if (!download || download.enabled !== true || typeof download.url !== 'string' || !download.url) return;
    let url;
    try {
      url = new URL(download.url, location.href);
    } catch {
      return;
    }
    if (url.protocol !== 'https:' && url.origin !== location.origin) return;
    const source = doc.getElementById('cta-source');
    if (!source || doc.getElementById('cta-download')) return;

    const button = h('a', { class: 'button button--primary', id: 'cta-download', href: url.href },
      svgIcon('M8 2v8.5M4.5 7 8 10.5 11.5 7M2.5 13.5h11'),
      h('span', null, download.label || 'Download for Mac'));
    source.classList.replace('button--primary', 'button--quiet');
    source.before(button);

    const pill = doc.querySelector('.status-pill');
    if (pill) {
      pill.querySelector('.status-dot')?.classList.add('status-dot--on');
      const text = pill.querySelector('.status-pill-text');
      if (text) text.textContent = download.version ? `Version ${download.version} for macOS` : 'Available for macOS';
    }
  }

  // Feature list. It draws the markup that scripts/sync-features.py writes into index.html, so a
  // redraw moves nothing. Each group gets a section, and each feature its title and summary, in
  // file order. The script writes every group with a title and features, and every feature with
  // an id, a title and a summary and nothing else. The redraw is all or nothing. If any part of
  // the file has another shape, as an older copy of it does, the static copy stays.

  const FEATURE_KEYS = 'id,summary,title';
  const isText = (value) => typeof value === 'string' && value.trim() !== '';
  const isFeature = (feature) => Boolean(feature) && typeof feature === 'object'
    && Object.keys(feature).sort().join() === FEATURE_KEYS
    && isText(feature.id) && isText(feature.title) && isText(feature.summary);
  const isGroup = (group) => Boolean(group) && isText(group.title)
    && Array.isArray(group.features) && group.features.length > 0 && group.features.every(isFeature);

  function renderFeatures(data) {
    const host = doc.getElementById('features');
    if (!host || !data || !Array.isArray(data.groups) || !data.groups.length) return;
    if (!data.groups.every(isGroup)) return;
    const sections = data.groups.map((group, index) => {
      const id = `feature-group-${index + 1}`;
      const list = h('ul', { class: 'feature-list' });
      for (const feature of group.features) {
        list.append(h('li', { class: 'feature' }, h('h4', null, feature.title), h('p', null, feature.summary)));
      }
      return h('section', { class: 'feature-group', 'aria-labelledby': id },
        h('h3', { class: 'feature-group-title', id }, group.title),
        list);
    });
    host.replaceChildren(...sections);
  }

  // Clip slots. A frame with data-clip, or with data-clip-dark and data-clip-light, stands for a
  // recording in media/. The page holds the recording's poster as a plain picture, which is what
  // readers without JavaScript see. Once the frame is shown and comes near the screen, the poster
  // gives way to a muted, looping, inline video with the same poster and the manifest's alt text.
  // The video plays while a fifth of it is on screen and its frame is shown. For readers who ask
  // for reduced motion it stays on its poster until they press Play.

  const VIDEO = /\.(mp4|m4v|webm|mov)$/i;
  const entries = new Map();
  const shot = doc.getElementById('hero-shot');
  const heroSource = shot && shot.querySelector('picture source[data-media]');
  const autoMedia = heroSource && heroSource.getAttribute('media');
  const clipFrames = [...doc.querySelectorAll('.frame[data-clip], .frame[data-clip-dark]')];

  const heroLook = () => (!shot || shot.dataset.look === 'auto' ? (lightScheme.matches ? 'light' : 'dark') : shot.dataset.look);
  const lookOf = (frame) => (frame === shot ? heroLook() : lightScheme.matches ? 'light' : 'dark');
  const clipOf = (frame) => frame.dataset.clip || (lookOf(frame) === 'light' ? frame.dataset.clipLight : frame.dataset.clipDark);
  const visible = (node) => node.getClientRects().length > 0;
  const near = (node, margin) => {
    const box = node.getBoundingClientRect();
    return box.width > 0 && box.bottom > -margin && box.top < innerHeight + margin;
  };

  const nearObserver = 'IntersectionObserver' in window
    ? new IntersectionObserver((list) => {
      for (const entry of list) {
        if (!entry.isIntersecting || !visible(entry.target)) continue;
        nearObserver.unobserve(entry.target);
        swapInClip(entry.target);
      }
    }, { rootMargin: '600px 0px' })
    : null;

  const playObserver = 'IntersectionObserver' in window
    ? new IntersectionObserver((list) => {
      for (const entry of list) updateVideo(entry.target, entry.isIntersecting);
    }, { threshold: 0.2 })
    : null;

  function applyManifest(manifest) {
    for (const entry of (manifest && manifest.files) || []) {
      if (entry && typeof entry.file === 'string') entries.set(entry.file, entry);
    }
    for (const img of doc.querySelectorAll('img[data-media]')) {
      const entry = entries.get(img.dataset.media);
      if (entry && entry.alt) img.alt = entry.alt;
    }
    syncHeroAlt();
    for (const frame of clipFrames) {
      if (nearObserver) nearObserver.observe(frame);
      else swapInClip(frame);
    }
  }

  function setClip(video, file, entry) {
    video.dataset.file = file;
    video.poster = entry.poster ? `media/${entry.poster}` : '';
    video.setAttribute('aria-label', entry.alt || '');
    video.src = `media/${file}`;
  }

  function swapInClip(frame) {
    if (!frame.isConnected || frame.querySelector('video')) return;
    const file = clipOf(frame);
    const entry = file && VIDEO.test(file) ? entries.get(file) : null;
    if (!entry) return;
    const video = h('video', {
      width: entry.width || 1880,
      height: entry.height || 1480,
      preload: 'none',
      muted: '', loop: '', playsinline: '', disablepictureinpicture: '', disableremoteplayback: '',
    });
    video.muted = true;
    video.defaultMuted = true;
    video.loop = true;
    video.playsInline = true;
    setClip(video, file, entry);
    for (const node of [...frame.children]) if (node.matches('img, picture')) node.remove();
    frame.prepend(video);
    addMotionToggle(frame);
    if (playObserver) playObserver.observe(video);
    updateVideo(video, near(video, 0));
  }

  // A frame whose clip follows the appearance changes recording when the appearance changes.
  function syncClips() {
    for (const frame of clipFrames) {
      const video = frame.querySelector('video');
      const file = clipOf(frame);
      const entry = entries.get(file);
      if (!video || !entry || video.dataset.file === file) continue;
      setClip(video, file, entry);
      updateVideo(video);
    }
  }

  // Pause and Play belong to the figure, so one button serves every clip in a picker, and it sits
  // in the caption bar, where it covers nothing in the recording.
  const holder = (node) => node.closest('figure') || node.parentElement;

  function shouldPlay(figure) {
    if (figure.dataset.motion === 'paused') return false;
    if (figure.dataset.motion === 'playing') return true;
    return !reduceMotion.matches;
  }

  function updateVideo(video, onScreen) {
    if (onScreen !== undefined) video.dataset.onScreen = onScreen ? '1' : '';
    if (!video.isConnected) return;
    const figure = holder(video);
    const play = video.dataset.onScreen && visible(video) && shouldPlay(figure);
    if (play) video.play().catch(() => {});
    else if (!video.paused) video.pause();
    const button = figure.querySelector('.media-toggle');
    if (button) {
      const playing = shouldPlay(figure);
      button.textContent = playing ? 'Pause' : 'Play';
      button.setAttribute('aria-label', playing ? 'Pause the recording' : 'Play the recording');
    }
  }

  function addMotionToggle(frame) {
    const figure = holder(frame);
    if (figure.querySelector('.media-toggle')) return;
    const button = h('button', { type: 'button', class: 'media-toggle' }, 'Pause');
    button.addEventListener('click', () => {
      figure.dataset.motion = shouldPlay(figure) ? 'paused' : 'playing';
      for (const video of figure.querySelectorAll('video')) updateVideo(video);
    });
    const bar = figure.querySelector('.figure-bar');
    if (!bar) {
      frame.append(button);
      return;
    }
    let controls = bar.querySelector('.figure-controls');
    if (!controls) {
      controls = h('div', { class: 'figure-controls' });
      bar.append(controls);
    }
    controls.append(button);
  }

  reduceMotion.addEventListener('change', () => {
    for (const video of doc.querySelectorAll('.frame video')) updateVideo(video);
  });
  lightScheme.addEventListener('change', syncClips);

  // A picker of several clips shows one frame at a time. The newly shown frame gets its video,
  // and the hidden ones pause.
  for (const viewer of doc.querySelectorAll('.viewer')) {
    viewer.addEventListener('change', () => {
      for (const frame of viewer.querySelectorAll('.frame')) {
        if (visible(frame) && near(frame, 600)) swapInClip(frame);
        for (const video of frame.querySelectorAll('video')) updateVideo(video, near(video, 0));
      }
    });
  }

  // Hero appearance switch. It starts on the reader's own appearance. Before the video arrives,
  // the hero is a <picture> whose light source follows prefers-color-scheme, so the switch
  // changes that source's media. After, it changes the video's recording.

  function syncHeroAlt() {
    const img = shot && shot.querySelector('picture img');
    const entry = entries.get(`hero-${heroLook()}-poster.png`);
    if (img && entry && entry.alt) img.alt = entry.alt;
  }

  function initLookToggle() {
    const group = doc.querySelector('.look-toggle');
    if (!shot || !group) return;
    const sync = () => {
      for (const button of group.querySelectorAll('button')) {
        button.setAttribute('aria-pressed', String(button.dataset.lookValue === heroLook()));
      }
      syncHeroAlt();
    };
    group.addEventListener('click', async (event) => {
      const button = event.target.closest('button[data-look-value]');
      if (!button || button.dataset.lookValue === heroLook()) return;
      const look = button.dataset.lookValue;
      const entry = entries.get(look === 'light' ? shot.dataset.clipLight : shot.dataset.clipDark);
      const picture = shot.querySelector('picture');
      const next = shot.querySelector('video') ? (entry && entry.poster ? `media/${entry.poster}` : null)
        : picture ? (look === 'light' ? heroSource.srcset : picture.querySelector('img').getAttribute('src')) : null;
      if (next) {
        // Wait briefly for the other picture so the switch does not flash an empty frame.
        const pending = Object.assign(new Image(), { src: next });
        await Promise.race([pending.decode().catch(() => {}), new Promise((done) => setTimeout(done, 500))]);
      }
      shot.dataset.look = look;
      if (heroSource && heroSource.isConnected) heroSource.media = look === 'light' ? 'all' : 'not all';
      sync();
      syncClips();
    });
    lightScheme.addEventListener('change', sync);
    if (heroSource && autoMedia) heroSource.media = autoMedia;
    sync();
    group.hidden = false;
  }

  // Copy the commands of a terminal block, without prompts or comments.

  function initCopy() {
    if (!navigator.clipboard || !window.isSecureContext) return;
    for (const button of doc.querySelectorAll('.copy-button')) {
      const target = doc.getElementById(button.dataset.copyTarget);
      const status = button.closest('.terminal')?.querySelector('.copy-status');
      if (!target) continue;
      button.hidden = false;
      let timer;
      button.addEventListener('click', async () => {
        const text = [...target.querySelectorAll('.cmd')].map((node) => node.textContent).join('\n');
        let message;
        try {
          await navigator.clipboard.writeText(`${text}\n`);
          message = 'Copied';
        } catch {
          message = 'Copy failed';
        }
        button.textContent = message;
        if (status) status.textContent = message === 'Copied' ? 'Commands copied.' : 'Could not copy.';
        clearTimeout(timer);
        timer = setTimeout(() => { button.textContent = 'Copy'; }, 1800);
      });
    }
  }

  initLookToggle();
  initCopy();
  Promise.allSettled([
    getJSON('data/release.json').then(applyRelease),
    getJSON('data/features.json').then(renderFeatures),
    getJSON('media/manifest.json').then(applyManifest),
  ]).then((results) => {
    for (const result of results) if (result.status === 'rejected') console.warn(result.reason);
  });
})();
