(() => {
  "use strict";

  const defaults = {
    rows: 4,
    columns: 8,
    persistenceSeconds: 30,
    fadeDurationSeconds: 0.42,
    topInsetPixels: 28,
    transitionStyle: "fade",
    randomTransitionNames: [],
  };

  const form = document.querySelector("#settings-form");
  const rowsInput = document.querySelector("#rows");
  const columnsInput = document.querySelector("#columns");
  const persistenceInput = document.querySelector("#persistence-seconds");
  const fadeInput = document.querySelector("#fade-duration-seconds");
  const topInsetInput = document.querySelector("#top-inset-pixels");
  const transitionList = document.querySelector("#transition-list");
  const transitionCount = document.querySelector("#transition-count");
  const randomIncludedCount = document.querySelector("#random-included-count");
  const tileCountOutput = document.querySelector("#tile-count");
  const cadenceOutput = document.querySelector("#change-cadence");
  const effectiveFadeOutput = document.querySelector("#effective-fade");
  const saveStatus = document.querySelector("#save-status");
  const resetButton = document.querySelector("#reset-settings");
  let saveTimer = null;
  let pendingSettings = null;
  let saveInProgress = false;

  const transitionNames = Array.isArray(window.GL_TRANSITION_NAMES)
    ? window.GL_TRANSITION_NAMES
    : [defaults.transitionStyle];
  defaults.randomTransitionNames = [...transitionNames];

  function createTransitionRow(name, index, isRandom = false) {
    const row = document.createElement("div");
    const choice = document.createElement("label");
    const radio = document.createElement("input");
    const nameLabel = document.createElement("span");
    const radioId = `transition-choice-${index}`;

    row.className = "transition-row";
    row.dataset.transition = name;
    choice.className = "transition-choice";
    choice.htmlFor = radioId;
    radio.id = radioId;
    radio.name = "transitionStyle";
    radio.type = "radio";
    radio.value = name;
    radio.required = true;
    nameLabel.textContent = isRandom ? "Random" : name;
    choice.append(radio, nameLabel);
    row.append(choice);

    if (isRandom) {
      const unavailable = document.createElement("span");
      unavailable.className = "random-unavailable";
      unavailable.textContent = "—";
      row.append(unavailable);
    } else {
      const includeLabel = document.createElement("label");
      const checkbox = document.createElement("input");
      const accessibleLabel = document.createElement("span");
      const checkboxId = `random-inclusion-${index}`;

      includeLabel.className = "random-toggle";
      includeLabel.htmlFor = checkboxId;
      checkbox.id = checkboxId;
      checkbox.name = "randomTransitionNames";
      checkbox.type = "checkbox";
      checkbox.value = name;
      checkbox.checked = true;
      accessibleLabel.className = "visually-hidden";
      accessibleLabel.textContent = `Include ${name} in Random`;
      includeLabel.append(checkbox, accessibleLabel);
      row.append(includeLabel);
    }

    return row;
  }

  const transitionRows = document.createDocumentFragment();
  transitionRows.append(createTransitionRow("random", 0, true));
  transitionNames.forEach((name, index) => {
    transitionRows.append(createTransitionRow(name, index + 1));
  });
  transitionList.replaceChildren(transitionRows);
  transitionCount.textContent = `(${transitionNames.length} + Random)`;

  function transitionStyleInputs() {
    return Array.from(form.querySelectorAll('input[name="transitionStyle"]'));
  }

  function randomTransitionInputs() {
    return Array.from(form.querySelectorAll('input[name="randomTransitionNames"]'));
  }

  function readForm() {
    return {
      rows: Number(rowsInput.value),
      columns: Number(columnsInput.value),
      persistenceSeconds: Number(persistenceInput.value),
      fadeDurationSeconds: Number(fadeInput.value),
      topInsetPixels: Number(topInsetInput.value),
      transitionStyle: form.querySelector('input[name="transitionStyle"]:checked')?.value
        || defaults.transitionStyle,
      randomTransitionNames: randomTransitionInputs()
        .filter((input) => input.checked)
        .map((input) => input.value),
    };
  }

  function writeForm(settings, scrollSelection = false) {
    rowsInput.value = settings.rows;
    columnsInput.value = settings.columns;
    persistenceInput.value = settings.persistenceSeconds;
    fadeInput.value = settings.fadeDurationSeconds;
    topInsetInput.value = settings.topInsetPixels;
    const selectedStyle = settings.transitionStyle || defaults.transitionStyle;
    transitionStyleInputs().forEach((input) => {
      input.checked = input.value === selectedStyle;
    });
    const includedNames = new Set(
      Array.isArray(settings.randomTransitionNames)
        ? settings.randomTransitionNames
        : transitionNames,
    );
    randomTransitionInputs().forEach((input) => {
      input.checked = includedNames.has(input.value);
    });
    randomIncludedCount.textContent = `(${includedNames.size})`;
    if (scrollSelection) {
      requestAnimationFrame(() => {
        form.querySelector('input[name="transitionStyle"]:checked')
          ?.closest(".transition-row")
          ?.scrollIntoView({ block: "nearest" });
      });
    }
    updateSummary();
  }

  function formatSeconds(value) {
    if (value < 0.1) return `${Math.round(value * 1000)}ms`;
    return `${Number(value.toFixed(value < 1 ? 2 : 1))}s`;
  }

  function updateSummary() {
    const settings = readForm();
    const count = Math.max(1, settings.rows * settings.columns);
    const cadence = settings.persistenceSeconds / count;
    const actualCadence = Math.max(cadence, settings.fadeDurationSeconds);

    tileCountOutput.textContent = count;
    cadenceOutput.textContent = formatSeconds(actualCadence);
    effectiveFadeOutput.textContent = formatSeconds(settings.fadeDurationSeconds);
  }

  async function flushSaves() {
    if (saveInProgress) return;
    saveInProgress = true;
    saveStatus.textContent = "Saving…";

    try {
      while (pendingSettings) {
        const payload = pendingSettings;
        pendingSettings = null;
        const response = await fetch("/api/settings", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        if (!response.ok) throw new Error(`Save failed: ${response.status}`);
        const savedSettings = await response.json();
        if (!pendingSettings) writeForm(savedSettings);
      }
      saveStatus.textContent = "Saved — Plash updates automatically";
    } catch (error) {
      saveStatus.textContent = "Could not save settings";
      console.error(error);
    } finally {
      saveInProgress = false;
      if (pendingSettings) flushSaves();
    }
  }

  function save() {
    if (!form.reportValidity()) return;
    pendingSettings = readForm();
    flushSaves();
  }

  function queueSave(delay = 300) {
    updateSummary();
    window.clearTimeout(saveTimer);
    saveTimer = window.setTimeout(save, delay);
  }

  form.addEventListener("input", (event) => {
    const isTransitionControl = event.target.matches(
      'input[name="transitionStyle"], input[name="randomTransitionNames"]',
    );
    if (event.target.name === "randomTransitionNames") {
      randomIncludedCount.textContent = `(${randomTransitionInputs().filter((input) => input.checked).length})`;
    }
    queueSave(isTransitionControl ? 0 : 300);
  });
  form.addEventListener("submit", (event) => event.preventDefault());
  resetButton.addEventListener("click", () => {
    writeForm(defaults, true);
    save();
  });

  fetch("/api/settings", { cache: "no-store" })
    .then((response) => {
      if (!response.ok) throw new Error(`Load failed: ${response.status}`);
      return response.json();
    })
    .then((settings) => {
      writeForm(settings, true);
      saveStatus.textContent = "Settings loaded";
    })
    .catch((error) => {
      writeForm(defaults, true);
      saveStatus.textContent = "Using defaults — server unavailable";
      console.error(error);
    });
})();
