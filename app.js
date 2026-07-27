import createTransition from "gl-transition";
import glTransitions from "gl-transitions";

(() => {
  "use strict";

  const images = Array.isArray(window.WALLPAPER_IMAGES) ? window.WALLPAPER_IMAGES : [];
  const gridElement = document.querySelector("#grid");
  const transitionByName = new Map(glTransitions.map((transition) => [transition.name, transition]));
  const transitionNames = [...transitionByName.keys()].sort((left, right) => left.localeCompare(right));
  const defaults = {
    rows: 4,
    columns: 8,
    persistenceSeconds: 30,
    fadeDurationSeconds: 0.42,
    topInsetPixels: 28,
    transitionStyle: "fade",
    randomTransitionNames: transitionNames,
  };

  let settings = { ...defaults };
  let settingsSignature = "";
  let tiles = [];
  let updateOrder = [];
  let updateCursor = 0;
  let randomDeck = [];
  let schedulerTimer = null;
  let schedulerGeneration = 0;
  let currentRun = null;
  let glRuntime = null;
  let transitionInProgress = false;
  let completedTransitions = 0;
  let activeTransitions = 0;
  let maximumConcurrentTransitions = 0;

  function clamp(value, minimum, maximum) {
    return Math.min(Math.max(Number(value) || minimum, minimum), maximum);
  }

  function clampMinimum(value, minimum) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? Math.max(numeric, minimum) : minimum;
  }

  function normalizeSettings(candidate = {}) {
    const transitionStyle = candidate.transitionStyle === "random"
      ? "random"
      : transitionByName.has(candidate.transitionStyle)
      ? candidate.transitionStyle
      : defaults.transitionStyle;
    const requestedRandomTransitions = Array.isArray(candidate.randomTransitionNames)
      ? new Set(candidate.randomTransitionNames)
      : new Set(transitionNames);
    const requestedPool = transitionNames.filter((name) => requestedRandomTransitions.has(name));
    const randomTransitionNames = requestedPool.length > 0 ? requestedPool : [defaults.transitionStyle];
    return {
      rows: Math.round(clamp(candidate.rows, 1, 20)),
      columns: Math.round(clamp(candidate.columns, 1, 32)),
      persistenceSeconds: clamp(candidate.persistenceSeconds, 1, 86400),
      fadeDurationSeconds: clampMinimum(candidate.fadeDurationSeconds, 0),
      topInsetPixels: clamp(candidate.topInsetPixels, 0, 200),
      transitionStyle,
      randomTransitionNames,
    };
  }

  function shuffle(values) {
    for (let index = values.length - 1; index > 0; index -= 1) {
      const swapIndex = Math.floor(Math.random() * (index + 1));
      [values[index], values[swapIndex]] = [values[swapIndex], values[index]];
    }
    return values;
  }

  function refillDeck() {
    randomDeck = shuffle(images.map((_, index) => index));
  }

  function nextImageIndex(excluded = new Set()) {
    if (images.length === 0) return -1;

    for (let attempt = 0; attempt < images.length * 2; attempt += 1) {
      if (randomDeck.length === 0) refillDeck();
      const candidate = randomDeck.pop();
      if (!excluded.has(candidate)) return candidate;
    }

    return Math.floor(Math.random() * images.length);
  }

  function tileCount() {
    return settings.rows * settings.columns;
  }

  function slotDurationMs() {
    return (settings.persistenceSeconds * 1000) / Math.max(tileCount(), 1);
  }

  function transitionDurationMs() {
    return settings.fadeDurationSeconds * 1000;
  }

  function createTile(imageIndex) {
    const tile = document.createElement("div");
    const firstImage = document.createElement("img");
    const secondImage = document.createElement("img");

    tile.className = "tile";
    tile.dataset.active = "0";
    tile.imageIndex = imageIndex;
    firstImage.alt = "";
    secondImage.alt = "";
    firstImage.decoding = "async";
    secondImage.decoding = "async";
    firstImage.src = images[imageIndex];
    tile.append(firstImage, secondImage);
    return tile;
  }

  function renderGrid() {
    const selected = new Set();
    const fragment = document.createDocumentFragment();

    document.documentElement.style.setProperty("--columns", settings.columns);
    document.documentElement.style.setProperty("--rows", settings.rows);
    document.documentElement.style.setProperty("--top-inset", `${settings.topInsetPixels}px`);

    tiles = [];
    for (let index = 0; index < tileCount(); index += 1) {
      const imageIndex = nextImageIndex(selected);
      selected.add(imageIndex);
      const tile = createTile(imageIndex);
      tiles.push(tile);
      fragment.append(tile);
    }

    updateOrder = shuffle(tiles.map((_, index) => index));
    updateCursor = 0;
    gridElement.replaceChildren(fragment);
  }

  function createTexture(gl, image) {
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);

    return {
      shape: [image.naturalWidth, image.naturalHeight],
      bind(unit) {
        gl.activeTexture(gl.TEXTURE0 + unit);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        return unit;
      },
      dispose() {
        gl.deleteTexture(texture);
      },
    };
  }

  function getGlRuntime() {
    if (glRuntime && !glRuntime.gl.isContextLost()) return glRuntime;

    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl", {
      alpha: false,
      antialias: false,
      depth: false,
      preserveDrawingBuffer: false,
    });
    if (!gl) throw new Error("WebGL is unavailable");

    const buffer = gl.createBuffer();
    glRuntime = { canvas, gl, buffer };
    return glRuntime;
  }

  function startCssFallback(tile, previousImage, nextImage, duration) {
    nextImage.style.zIndex = "2";
    previousImage.style.zIndex = "1";
    const options = { duration, easing: "ease-in-out", fill: "both" };
    const animations = [
      nextImage.animate([{ opacity: 0 }, { opacity: 1 }], options),
      previousImage.animate([{ opacity: 1 }, { opacity: 0 }], options),
    ];
    let settled = false;
    let resolvePromise;
    const promise = new Promise((resolve) => { resolvePromise = resolve; });

    function finish() {
      if (settled) return;
      settled = true;
      animations.forEach((animation) => animation.cancel());
      nextImage.style.removeProperty("z-index");
      previousImage.style.removeProperty("z-index");
      resolvePromise();
    }

    Promise.all(animations.map((animation) => animation.finished)).then(finish, finish);
    return { promise, cancel: finish, renderer: "css-fallback" };
  }

  function startGlTransition(tile, previousImage, nextImage, transition, duration) {
    const { canvas, gl, buffer } = getGlRuntime();
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    canvas.className = "gl-transition-canvas";
    canvas.width = Math.max(1, Math.round(tile.clientWidth * scale));
    canvas.height = Math.max(1, Math.round(tile.clientHeight * scale));
    canvas.setAttribute("aria-hidden", "true");
    tile.append(canvas);

    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, -1, 4, 4, -1]), gl.STATIC_DRAW);
    gl.viewport(0, 0, canvas.width, canvas.height);

    let renderer;
    let fromTexture;
    let toTexture;
    try {
      fromTexture = createTexture(gl, previousImage);
      toTexture = createTexture(gl, nextImage);
      renderer = createTransition(gl, transition, { resizeMode: "contain" });
      renderer.draw(0, fromTexture, toTexture, canvas.width, canvas.height);
    } catch (error) {
      renderer?.dispose();
      fromTexture?.dispose();
      toTexture?.dispose();
      canvas.remove();
      throw error;
    }

    let animationFrame = null;
    let startedAt = null;
    let settled = false;
    let resolvePromise;
    const promise = new Promise((resolve) => { resolvePromise = resolve; });

    function cleanup() {
      if (settled) return;
      settled = true;
      if (animationFrame !== null) cancelAnimationFrame(animationFrame);
      renderer.dispose();
      fromTexture.dispose();
      toTexture.dispose();
      canvas.remove();
      resolvePromise();
    }

    function drawFrame(timestamp) {
      if (startedAt === null) startedAt = timestamp;
      const linearProgress = duration === 0 ? 1 : Math.min((timestamp - startedAt) / duration, 1);
      const easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress);
      renderer.draw(easedProgress, fromTexture, toTexture, canvas.width, canvas.height);
      if (linearProgress < 1) {
        animationFrame = requestAnimationFrame(drawFrame);
      } else {
        cleanup();
      }
    }

    animationFrame = requestAnimationFrame(drawFrame);
    return {
      promise,
      renderer: "webgl",
      transitionName: transition.name,
      cancel() {
        try {
          renderer.draw(1, fromTexture, toTexture, canvas.width, canvas.height);
        } finally {
          cleanup();
        }
      },
    };
  }

  async function changeTile(tile) {
    const excluded = new Set(tiles.map((candidate) => candidate.imageIndex));
    excluded.delete(tile.imageIndex);
    const nextIndex = nextImageIndex(excluded);
    if (nextIndex < 0) return;

    transitionInProgress = true;
    activeTransitions += 1;
    maximumConcurrentTransitions = Math.max(maximumConcurrentTransitions, activeTransitions);
    const nextActive = tile.dataset.active === "0" ? 1 : 0;
    const nextImage = tile.children[nextActive];
    const previousImage = tile.children[Number(tile.dataset.active)];
    nextImage.src = images[nextIndex];

    try {
      await nextImage.decode();
    } catch {
      // WebKit may reject decode() while still loading and displaying the image.
    }

    const randomPool = settings.randomTransitionNames.length > 0
      ? settings.randomTransitionNames
      : ["fade"];
    const transitionName = settings.transitionStyle === "random"
      ? randomPool[Math.floor(Math.random() * randomPool.length)]
      : settings.transitionStyle;
    const transition = transitionByName.get(transitionName) || transitionByName.get("fade");
    tile.dataset.transition = transition.name;
    let run;
    try {
      run = startGlTransition(tile, previousImage, nextImage, transition, transitionDurationMs());
    } catch (error) {
      console.warn(`Unable to render GL transition ${transition.name}; using a fade`, error);
      run = startCssFallback(tile, previousImage, nextImage, transitionDurationMs());
    }

    currentRun = run;
    await run.promise;
    if (currentRun === run) currentRun = null;

    tile.imageIndex = nextIndex;
    tile.dataset.active = String(nextActive);
    activeTransitions -= 1;
    completedTransitions += 1;
    transitionInProgress = false;
  }

  async function changeNextTile() {
    if (tiles.length === 0 || transitionInProgress) return;
    const tileIndex = updateOrder[updateCursor];
    updateCursor = (updateCursor + 1) % updateOrder.length;
    await changeTile(tiles[tileIndex]);
  }

  function stopScheduler() {
    schedulerGeneration += 1;
    window.clearTimeout(schedulerTimer);
    schedulerTimer = null;
    try {
      currentRun?.cancel();
    } catch (error) {
      console.warn("Unable to finish the interrupted GL transition", error);
    }
    currentRun = null;
  }

  async function validateAllTransitions() {
    const tile = tiles[0];
    const image = tile?.children[Number(tile.dataset.active)];
    if (!tile || !image) return [{ name: "setup", error: "No rendered tile is available" }];
    try {
      await image.decode();
    } catch {
      // The image may already be decoded.
    }

    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(tile.clientWidth));
    canvas.height = Math.max(1, Math.round(tile.clientHeight));
    const gl = canvas.getContext("webgl", { alpha: false, antialias: false, depth: false });
    if (!gl) return [{ name: "setup", error: "WebGL is unavailable" }];

    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, -1, 4, 4, -1]), gl.STATIC_DRAW);
    gl.viewport(0, 0, canvas.width, canvas.height);
    const fromTexture = createTexture(gl, image);
    const toTexture = createTexture(gl, image);
    const failures = [];

    for (const transition of glTransitions) {
      let renderer;
      try {
        renderer = createTransition(gl, transition, { resizeMode: "contain" });
        renderer.draw(0.5, fromTexture, toTexture, canvas.width, canvas.height);
      } catch (error) {
        failures.push({ name: transition.name, error: String(error.message || error) });
      } finally {
        renderer?.dispose();
      }
    }

    fromTexture.dispose();
    toTexture.dispose();
    gl.deleteBuffer(buffer);
    gl.getExtension("WEBGL_lose_context")?.loseContext();
    return failures;
  }

  function scheduleNext(generation, delay = slotDurationMs()) {
    schedulerTimer = window.setTimeout(async () => {
      const startedAt = performance.now();
      await changeNextTile();
      if (generation !== schedulerGeneration) return;
      const remainingDelay = Math.max(0, slotDurationMs() - (performance.now() - startedAt));
      scheduleNext(generation, remainingDelay);
    }, delay);
  }

  function applySettings(candidate) {
    const next = normalizeSettings(candidate);
    const nextSignature = JSON.stringify(next);
    if (nextSignature === settingsSignature) return;

    const dimensionsChanged = next.rows !== settings.rows
      || next.columns !== settings.columns
      || next.topInsetPixels !== settings.topInsetPixels;
    const randomPoolChanged = JSON.stringify(next.randomTransitionNames)
      !== JSON.stringify(settings.randomTransitionNames);
    const transitionChanged = next.transitionStyle !== settings.transitionStyle
      || (next.transitionStyle === "random" && randomPoolChanged);

    stopScheduler();
    settings = next;
    settingsSignature = nextSignature;
    if (dimensionsChanged || tiles.length === 0) renderGrid();

    const generation = schedulerGeneration;
    scheduleNext(generation, transitionChanged ? 0 : slotDurationMs());
  }

  async function fetchSettings() {
    const response = await fetch("/api/settings", { cache: "no-store" });
    if (!response.ok) throw new Error(`Settings request failed: ${response.status}`);
    return response.json();
  }

  async function pollSettings() {
    try {
      applySettings(await fetchSettings());
    } catch (error) {
      console.warn("Unable to refresh wallpaper settings", error);
    }
  }

  async function start() {
    if (images.length === 0) {
      gridElement.textContent = "No images found. Run ./generate-image-manifest.zsh";
      gridElement.removeAttribute("aria-hidden");
      return;
    }

    try {
      applySettings(await fetchSettings());
    } catch (error) {
      console.warn("Using default wallpaper settings", error);
      applySettings(defaults);
    }

    window.setInterval(pollSettings, 150);
  }

  window.wallpaperDebug = {
    get settings() { return { ...settings }; },
    get tileCount() { return tiles.length; },
    get transitionCount() { return glTransitions.length; },
    get slotDurationMs() { return slotDurationMs(); },
    get transitionDurationMs() { return transitionDurationMs(); },
    get activeRenderer() { return currentRun?.renderer || null; },
    get activeTransitionName() { return currentRun?.transitionName || null; },
    get updateCursor() { return updateCursor; },
    get transitionInProgress() { return transitionInProgress; },
    get completedTransitions() { return completedTransitions; },
    get maximumConcurrentTransitions() { return maximumConcurrentTransitions; },
    validateAllTransitions,
  };

  start();
})();
