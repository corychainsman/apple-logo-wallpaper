import createTransition from "gl-transition";
import glTransitions from "gl-transitions";

(() => {
  "use strict";

  const images = Array.isArray(window.WALLPAPER_IMAGES) ? window.WALLPAPER_IMAGES : [];
  const gridElement = document.querySelector("#grid");
  const displayId = String(window.NATIVE_DISPLAY_ID || new URLSearchParams(location.search).get("display") || "default");
  const transitionByName = new Map(glTransitions.map((transition) => [transition.name, transition]));
  const transitionNames = [...transitionByName.keys()].sort((left, right) => left.localeCompare(right));
  const defaults = {
    rows: 4,
    columns: 8,
    transitionGapSeconds: 0.5,
    fadeDurationSeconds: 0.42,
    topInsetPixels: 28,
    transitionStyle: "fade",
    randomTransitionNames: transitionNames,
    transitionParameters: {},
  };

  let settings = { ...defaults };
  let settingsSignature = "";
  let tiles = [];
  let updateOrder = [];
  let updateCursor = 0;
  let randomDeck = [];
  let schedulerTimer = null;
  let schedulerGeneration = 0;
  const activeRuns = new Set();
  const activeTiles = new Set();
  const maximumSupportedOverlap = 8;
  const glRuntimePool = [];
  let completedTransitions = 0;
  let activeTransitions = 0;
  let maximumConcurrentTransitions = 0;
  let lastRenderer = null;
  let lastTransitionName = null;
  let lastTransitionError = null;
  let dockIconPublishing = Boolean(window.NATIVE_DOCK_ICON_CYCLING);
  let dockIconRunSequence = 0;
  let lastDockIconFrameAt = 0;
  const dockIconCanvas = document.createElement("canvas");
  dockIconCanvas.width = 128;
  dockIconCanvas.height = 128;

  function clamp(value, minimum, maximum) {
    return Math.min(Math.max(Number(value) || minimum, minimum), maximum);
  }

  function clampMinimum(value, minimum) {
    const numeric = Number(value);
    return Number.isFinite(numeric) ? Math.max(numeric, minimum) : minimum;
  }

  function normalizeSettings(candidate = {}) {
    const displaySettings = candidate.displayConfigurations?.[displayId] || candidate;
    const rows = Math.round(clamp(displaySettings.rows ?? candidate.rows, 1, 20));
    const columns = Math.round(clamp(displaySettings.columns ?? candidate.columns, 1, 32));
    const fadeDurationSeconds = clampMinimum(candidate.fadeDurationSeconds, 0);
    const requestedGap = Number(candidate.transitionGapSeconds);
    const legacyRefreshCycle = Number(candidate.persistenceSeconds);
    const transitionGapSeconds = Number.isFinite(requestedGap)
      ? Math.min(Math.max(requestedGap, -86400), 86400)
      : Number.isFinite(legacyRefreshCycle)
      ? (legacyRefreshCycle / Math.max(rows * columns, 1)) - fadeDurationSeconds
      : defaults.transitionGapSeconds;
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
      rows,
      columns,
      transitionGapSeconds,
      fadeDurationSeconds,
      topInsetPixels: Number.isFinite(Number(window.NATIVE_TOP_INSET_PIXELS))
        ? clamp(window.NATIVE_TOP_INSET_PIXELS, 0, 200)
        : clamp(candidate.topInsetPixels, 0, 200),
      transitionStyle,
      randomTransitionNames,
      transitionParameters: candidate.transitionParameters || {},
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

  function transitionDurationMs() {
    return settings.fadeDurationSeconds * 1000;
  }

  function transitionStartIntervalMs() {
    return Math.max(0, transitionDurationMs() + (settings.transitionGapSeconds * 1000));
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

  function createGlRuntime() {
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl", {
      alpha: false,
      antialias: false,
      depth: false,
      preserveDrawingBuffer: false,
    });
    if (!gl) throw new Error("WebGL is unavailable");

    const buffer = gl.createBuffer();
    return { canvas, gl, buffer, inUse: false };
  }

  function acquireGlRuntime() {
    let runtime = glRuntimePool.find((candidate) => !candidate.inUse && !candidate.gl.isContextLost());
    if (!runtime) {
      if (glRuntimePool.length >= maximumSupportedOverlap) {
        throw new Error("No WebGL transition renderer is currently available");
      }
      runtime = createGlRuntime();
      glRuntimePool.push(runtime);
    }
    runtime.inUse = true;
    return runtime;
  }

  function releaseGlRuntime(runtime) {
    runtime.canvas.remove();
    runtime.inUse = false;
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

  function startGlTransition(tile, previousImage, nextImage, transition, duration, parameters) {
    const runtime = acquireGlRuntime();
    const { canvas, gl, buffer } = runtime;
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
      renderer.draw(0, fromTexture, toTexture, canvas.width, canvas.height, parameters);
    } catch (error) {
      renderer?.dispose();
      fromTexture?.dispose();
      toTexture?.dispose();
      releaseGlRuntime(runtime);
      throw error;
    }

    let animationFrame = null;
    let startedAt = null;
    const dockIconRun = ++dockIconRunSequence;
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
      releaseGlRuntime(runtime);
      resolvePromise();
    }

    function drawFrame(timestamp) {
      if (startedAt === null) startedAt = timestamp;
      const linearProgress = duration === 0 ? 1 : Math.min((timestamp - startedAt) / duration, 1);
      const easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress);
      renderer.draw(easedProgress, fromTexture, toTexture, canvas.width, canvas.height, parameters);
      if (dockIconPublishing
          && window.NATIVE_DOCK_ICON_SOURCE
          && dockIconRun === dockIconRunSequence
          && (timestamp - lastDockIconFrameAt >= 80 || linearProgress >= 1)) {
        const context = dockIconCanvas.getContext("2d");
        const squareSide = Math.min(canvas.width, canvas.height);
        context.clearRect(0, 0, dockIconCanvas.width, dockIconCanvas.height);
        context.drawImage(
          canvas,
          (canvas.width - squareSide) / 2,
          (canvas.height - squareSide) / 2,
          squareSide,
          squareSide,
          0,
          0,
          dockIconCanvas.width,
          dockIconCanvas.height,
        );
        window.webkit?.messageHandlers?.dockIconFrame?.postMessage(
          dockIconCanvas.toDataURL("image/png"),
        );
        lastDockIconFrameAt = timestamp;
      }
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
          renderer.draw(1, fromTexture, toTexture, canvas.width, canvas.height, parameters);
        } finally {
          cleanup();
        }
      },
    };
  }

  async function changeTile(tile) {
    if (activeTiles.has(tile)) return false;
    const excluded = new Set(tiles.map((candidate) => candidate.imageIndex));
    excluded.delete(tile.imageIndex);
    const nextIndex = nextImageIndex(excluded);
    if (nextIndex < 0) return false;

    activeTiles.add(tile);
    activeTransitions += 1;
    maximumConcurrentTransitions = Math.max(maximumConcurrentTransitions, activeTransitions);
    const nextActive = tile.dataset.active === "0" ? 1 : 0;
    const nextImage = tile.children[nextActive];
    const previousImage = tile.children[Number(tile.dataset.active)];
    nextImage.src = images[nextIndex];

    let run;
    try {
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
      const transitionParameters = settings.transitionParameters[transition.name] || {};
      tile.dataset.transition = transition.name;
      try {
        run = startGlTransition(
          tile,
          previousImage,
          nextImage,
          transition,
          transitionDurationMs(),
          transitionParameters,
        );
        lastTransitionError = null;
      } catch (error) {
        console.warn(`Unable to render GL transition ${transition.name}; using a fade`, error);
        lastTransitionError = String(error?.message || error);
        run = startCssFallback(tile, previousImage, nextImage, transitionDurationMs());
      }

      lastRenderer = run.renderer;
      lastTransitionName = transition.name;
      activeRuns.add(run);
      await run.promise;
      tile.imageIndex = nextIndex;
      tile.dataset.active = String(nextActive);
      completedTransitions += 1;
      return true;
    } finally {
      if (run) activeRuns.delete(run);
      activeTiles.delete(tile);
      activeTransitions -= 1;
    }
  }

  function changeNextTile() {
    if (tiles.length === 0 || activeTransitions >= maximumSupportedOverlap) return false;
    for (let attempt = 0; attempt < updateOrder.length; attempt += 1) {
      const tileIndex = updateOrder[updateCursor];
      updateCursor = (updateCursor + 1) % updateOrder.length;
      const tile = tiles[tileIndex];
      if (activeTiles.has(tile)) continue;
      void changeTile(tile);
      return true;
    }
    return false;
  }

  function stopScheduler() {
    schedulerGeneration += 1;
    window.clearTimeout(schedulerTimer);
    schedulerTimer = null;
    for (const run of [...activeRuns]) {
      try {
        run.cancel();
      } catch (error) {
        console.warn("Unable to finish an interrupted GL transition", error);
      }
    }
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

  function scheduleNext(generation, delay = transitionStartIntervalMs()) {
    schedulerTimer = window.setTimeout(() => {
      if (generation !== schedulerGeneration) return;
      const started = changeNextTile();
      const interval = Math.max(16, transitionStartIntervalMs());
      scheduleNext(generation, started ? interval : Math.min(interval, 50));
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
    scheduleNext(generation, transitionChanged ? 0 : transitionStartIntervalMs());
  }

  function previewSelectedTransition() {
    stopScheduler();
    const generation = schedulerGeneration;
    scheduleNext(generation, 0);
  }

  function start() {
    if (images.length === 0) {
      gridElement.textContent = "No images found. Run ./generate-image-manifest.zsh";
      gridElement.removeAttribute("aria-hidden");
      return;
    }

    applySettings(window.NATIVE_WALLPAPER_SETTINGS || defaults);
  }

  window.wallpaperDebug = {
    get settings() { return { ...settings }; },
    get tileCount() { return tiles.length; },
    get transitionCount() { return glTransitions.length; },
    get transitionStartIntervalMs() { return transitionStartIntervalMs(); },
    get transitionDurationMs() { return transitionDurationMs(); },
    get activeRenderer() { return [...activeRuns][0]?.renderer || null; },
    get activeTransitionName() { return [...activeRuns][0]?.transitionName || null; },
    get updateCursor() { return updateCursor; },
    get transitionInProgress() { return activeTransitions > 0; },
    get activeTransitions() { return activeTransitions; },
    get completedTransitions() { return completedTransitions; },
    get maximumConcurrentTransitions() { return maximumConcurrentTransitions; },
    get lastRenderer() { return lastRenderer; },
    get lastTransitionName() { return lastTransitionName; },
    get lastTransitionError() { return lastTransitionError; },
    validateAllTransitions,
  };

  window.applyNativeWallpaperSettings = (nextSettings) => {
    window.NATIVE_WALLPAPER_SETTINGS = nextSettings;
    applySettings(nextSettings);
  };
  window.previewNativeTransition = previewSelectedTransition;
  window.setDockIconPublishing = (enabled) => {
    dockIconPublishing = Boolean(enabled);
  };

  start();
})();
