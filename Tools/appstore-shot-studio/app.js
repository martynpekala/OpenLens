const presets = [
  { id: 'iphone69', label: 'iPhone 6.9" Portrait', width: 1320, height: 2868, deviceAspect: 1320 / 2868, deviceId: 'iphone17pm' },
  { id: 'iphone65', label: 'iPhone 6.5" Portrait', width: 1242, height: 2688, deviceAspect: 1242 / 2688, deviceId: 'iphone17pm' },
  { id: 'iphone55', label: 'iPhone 5.5" Portrait', width: 1242, height: 2208, deviceAspect: 1242 / 2208, deviceId: 'iphone17pm' },
  { id: 'ipad13', label: 'iPad 13" Portrait', width: 2064, height: 2752, deviceAspect: 2064 / 2752, deviceId: 'ipadair' }
];

const themes = [
  {
    id: 'linen',
    label: 'Linen Paper',
    palette: ['#f4ecde', '#ebe2d2', '#f9f5ee'],
    text: '#15251f',
    accent: '#215949',
    subtext: '#5c6a63'
  },
  {
    id: 'ocean',
    label: 'Steel Ocean',
    palette: ['#dfe9f1', '#bfd1e6', '#eef4fa'],
    text: '#102033',
    accent: '#1a4fb5',
    subtext: '#5b6c83'
  },
  {
    id: 'sunrise',
    label: 'Amber Sunrise',
    palette: ['#f7e4ca', '#f3c9a5', '#fff6ea'],
    text: '#2d1e13',
    accent: '#ab5522',
    subtext: '#735646'
  },
  {
    id: 'forest',
    label: 'Moss Studio',
    palette: ['#d8e4d4', '#b5c9b4', '#eef5ed'],
    text: '#16261b',
    accent: '#1d6a48',
    subtext: '#5f7064'
  }
];

const templates = [
  {
    id: 'live-monitoring',
    label: 'Live Monitoring',
    text: 'See every coding session at a glance.'
  },
  {
    id: 'review-flow',
    label: 'Review Flow',
    text: 'Inspect diffs before anything ships.'
  },
  {
    id: 'workspace-control',
    label: 'Workspace Control',
    text: 'Keep repository context close.'
  },
  {
    id: 'inbox-approval',
    label: 'Inbox Approval',
    text: 'Approve agent actions with confidence.'
  }
];

const fonts = [
  {
    id: 'editorial',
    label: 'Editorial Serif',
    stack: 'Georgia, "Iowan Old Style", "Palatino Linotype", serif'
  },
  {
    id: 'system-sans',
    label: 'System Sans',
    stack: '"Avenir Next", "Helvetica Neue", Helvetica, Arial, sans-serif'
  },
  {
    id: 'condensed',
    label: 'Condensed Sans',
    stack: '"Avenir Next Condensed", "Arial Narrow", sans-serif'
  },
  {
    id: 'rounded',
    label: 'Rounded Sans',
    stack: '"Arial Rounded MT Bold", "Trebuchet MS", "Avenir Next", sans-serif'
  },
  {
    id: 'mono',
    label: 'Monospace',
    stack: '"SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace'
  }
];

const fontWeights = [
  { id: 'regular', label: 'Regular', value: '400' },
  { id: 'semibold', label: 'Semibold', value: '600' },
  { id: 'bold', label: 'Bold', value: '700' }
];

const deviceProfiles = {
  iphone17pm: {
    id: 'iphone17pm',
    name: 'iPhone 17 Pro Max 2025',
    path: './mockup_apple_iphone_17_pro_max_2025.png',
    crop: { x: 494, y: 34, width: 453, height: 932 },
    screen: { x: 20, y: 16, width: 414, height: 900 },
    layout: {
      widthRatio: 0.68,
      bottomMarginRatio: 0.06,
      screenCornerRatio: 0.093
    },
    keyColors: [
      { red: 255, green: 255, blue: 255, tolerance: 18 },
      { red: 226, green: 226, blue: 226, tolerance: 18 },
      { red: 232, green: 232, blue: 232, tolerance: 18 }
    ],
    image: null,
    overlayCanvas: null,
    ready: false
  },
  ipadair: {
    id: 'ipadair',
    name: 'iPad Air',
    path: './mockup_apple_ipad_air_4_1be2891561.png',
    crop: { x: 166, y: 38, width: 668, height: 925 },
    screen: { x: 39, y: 39, width: 591, height: 847 },
    layout: {
      widthRatio: 0.72,
      bottomMarginRatio: 0.058,
      screenCornerRatio: 0.03
    },
    keyColors: [
      { red: 255, green: 255, blue: 255, tolerance: 18 },
      { red: 226, green: 226, blue: 226, tolerance: 18 }
    ],
    image: null,
    overlayCanvas: null,
    ready: false
  }
};

const state = {
  presetId: 'iphone69',
  themeId: 'linen',
  fontId: 'editorial',
  fontWeightId: 'bold',
  fontSizeScale: 1,
  textOffsetY: 0,
  templateId: 'live-monitoring',
  textAlign: 'left',
  headline: 'Stay on top of every coding session.',
  filenameBase: 'openlens-appstore-shot',
  gradientColors: ['#f4ecde', '#ebe2d2', '#f9f5ee'],
  gradientAngle: 135,
  fitMode: 'stretch',
  zoom: 1,
  offsetX: 0,
  offsetY: 0,
  deviceScale: 0.92,
  autoFitOnImport: true,
  gradientOnly: false,
  showFrame: true,
  showShadow: true,
  showTextPanel: true,
  image: null,
  imageName: ''
};

const elements = {
  fileInput: document.getElementById('fileInput'),
  dropzone: document.getElementById('dropzone'),
  fileStatus: document.getElementById('fileStatus'),
  presetSelect: document.getElementById('presetSelect'),
  themeSelect: document.getElementById('themeSelect'),
  fontSelect: document.getElementById('fontSelect'),
  fontWeightSelect: document.getElementById('fontWeightSelect'),
  templateSelect: document.getElementById('templateSelect'),
  deviceMockupInput: document.getElementById('deviceMockupInput'),
  filenameInput: document.getElementById('filenameInput'),
  gradientStartInput: document.getElementById('gradientStartInput'),
  gradientMiddleInput: document.getElementById('gradientMiddleInput'),
  gradientEndInput: document.getElementById('gradientEndInput'),
  gradientAngleRange: document.getElementById('gradientAngleRange'),
  gradientAngleLabel: document.getElementById('gradientAngleLabel'),
  fitModeSelect: document.getElementById('fitModeSelect'),
  fitNowButton: document.getElementById('fitNowButton'),
  textAlignSelect: document.getElementById('textAlignSelect'),
  headlineInput: document.getElementById('headlineInput'),
  fontSizeRange: document.getElementById('fontSizeRange'),
  fontSizeValue: document.getElementById('fontSizeValue'),
  textOffsetYRange: document.getElementById('textOffsetYRange'),
  textOffsetYValue: document.getElementById('textOffsetYValue'),
  zoomRange: document.getElementById('zoomRange'),
  offsetXRange: document.getElementById('offsetXRange'),
  offsetYRange: document.getElementById('offsetYRange'),
  deviceScaleRange: document.getElementById('deviceScaleRange'),
  autoFitCheckbox: document.getElementById('autoFitCheckbox'),
  gradientOnlyCheckbox: document.getElementById('gradientOnlyCheckbox'),
  showFrameCheckbox: document.getElementById('showFrameCheckbox'),
  showShadowCheckbox: document.getElementById('showShadowCheckbox'),
  showTextPanelCheckbox: document.getElementById('showTextPanelCheckbox'),
  downloadButton: document.getElementById('downloadButton'),
  downloadAllButton: document.getElementById('downloadAllButton'),
  copySpecButton: document.getElementById('copySpecButton'),
  resetButton: document.getElementById('resetButton'),
  canvas: document.getElementById('previewCanvas'),
  stageTitle: document.getElementById('stageTitle'),
  stageMeta: document.getElementById('stageMeta')
};

const ctx = elements.canvas.getContext('2d');

init();

function init() {
  fillSelect(elements.presetSelect, presets, state.presetId);
  fillSelect(elements.themeSelect, themes, state.themeId);
  fillSelect(elements.fontSelect, fonts, state.fontId);
  fillSelect(elements.fontWeightSelect, fontWeights, state.fontWeightId);
  fillSelect(elements.templateSelect, templates, state.templateId);

  bindEvents();
  syncSelectedDeviceMockup();
  syncGradientControls();
  syncTypographyControls();
  loadMockupAssets();
  render();
}

function fillSelect(select, options, initialValue) {
  select.innerHTML = options
    .map((option) => `<option value="${option.id}">${option.label}</option>`)
    .join('');
  select.value = initialValue;
}

function bindEvents() {
  elements.fileInput.addEventListener('change', (event) => {
    const [file] = event.target.files;
    if (file) {
      loadImageFile(file);
    }
  });

  ['dragenter', 'dragover'].forEach((eventName) => {
    elements.dropzone.addEventListener(eventName, (event) => {
      event.preventDefault();
      elements.dropzone.classList.add('is-dragover');
    });
  });

  ['dragleave', 'dragend', 'drop'].forEach((eventName) => {
    elements.dropzone.addEventListener(eventName, (event) => {
      event.preventDefault();
      elements.dropzone.classList.remove('is-dragover');
    });
  });

  elements.dropzone.addEventListener('drop', (event) => {
    const [file] = event.dataTransfer.files;
    if (file) {
      loadImageFile(file);
    }
  });

  elements.presetSelect.addEventListener('change', () => {
    state.presetId = elements.presetSelect.value;
    syncSelectedDeviceMockup();
    render();
  });

  elements.themeSelect.addEventListener('change', () => {
    applyTheme(elements.themeSelect.value);
  });

  elements.fontSelect.addEventListener('change', () => {
    state.fontId = elements.fontSelect.value;
    render();
  });

  elements.fontWeightSelect.addEventListener('change', () => {
    state.fontWeightId = elements.fontWeightSelect.value;
    render();
  });

  elements.templateSelect.addEventListener('change', () => {
    applyTemplate(elements.templateSelect.value);
  });

  elements.filenameInput.addEventListener('input', () => {
    state.filenameBase = sanitizeFilename(elements.filenameInput.value) || 'openlens-appstore-shot';
  });

  elements.fitModeSelect.addEventListener('change', () => {
    state.fitMode = elements.fitModeSelect.value;
    render();
  });

  elements.fitNowButton.addEventListener('click', () => {
    fitImportedImage();
    render();
  });

  elements.gradientStartInput.addEventListener('input', () => {
    state.gradientColors[0] = elements.gradientStartInput.value;
    render();
  });

  elements.gradientMiddleInput.addEventListener('input', () => {
    state.gradientColors[1] = elements.gradientMiddleInput.value;
    render();
  });

  elements.gradientEndInput.addEventListener('input', () => {
    state.gradientColors[2] = elements.gradientEndInput.value;
    render();
  });

  elements.gradientAngleRange.addEventListener('input', () => {
    state.gradientAngle = Number(elements.gradientAngleRange.value);
    syncGradientControls();
    render();
  });

  elements.textAlignSelect.addEventListener('change', () => {
    state.textAlign = elements.textAlignSelect.value;
    render();
  });

  elements.headlineInput.addEventListener('input', () => {
    state.headline = elements.headlineInput.value.trim();
    render();
  });

  elements.fontSizeRange.addEventListener('input', () => {
    state.fontSizeScale = Number(elements.fontSizeRange.value);
    syncTypographyControls();
    render();
  });

  elements.textOffsetYRange.addEventListener('input', () => {
    state.textOffsetY = Number(elements.textOffsetYRange.value);
    syncTypographyControls();
    render();
  });

  elements.zoomRange.addEventListener('input', () => {
    state.zoom = Number(elements.zoomRange.value);
    render();
  });

  elements.offsetXRange.addEventListener('input', () => {
    state.offsetX = Number(elements.offsetXRange.value);
    render();
  });

  elements.offsetYRange.addEventListener('input', () => {
    state.offsetY = Number(elements.offsetYRange.value);
    render();
  });

  elements.deviceScaleRange.addEventListener('input', () => {
    state.deviceScale = Number(elements.deviceScaleRange.value);
    render();
  });

  elements.autoFitCheckbox.addEventListener('change', () => {
    state.autoFitOnImport = elements.autoFitCheckbox.checked;
  });

  elements.gradientOnlyCheckbox.addEventListener('change', () => {
    state.gradientOnly = elements.gradientOnlyCheckbox.checked;
    render();
  });

  elements.showFrameCheckbox.addEventListener('change', () => {
    state.showFrame = elements.showFrameCheckbox.checked;
    render();
  });

  elements.showShadowCheckbox.addEventListener('change', () => {
    state.showShadow = elements.showShadowCheckbox.checked;
    render();
  });

  elements.showTextPanelCheckbox.addEventListener('change', () => {
    state.showTextPanel = elements.showTextPanelCheckbox.checked;
    render();
  });

  elements.downloadButton.addEventListener('click', downloadCurrentImage);
  elements.downloadAllButton.addEventListener('click', downloadAllPresets);
  elements.copySpecButton.addEventListener('click', copySpec);
  elements.resetButton.addEventListener('click', resetState);
}

function applyTemplate(templateId) {
  const template = templates.find((entry) => entry.id === templateId);
  if (!template) {
    return;
  }

  state.templateId = template.id;
  state.headline = template.text;

  elements.templateSelect.value = state.templateId;
  elements.headlineInput.value = state.headline;
  render();
}

function applyTheme(themeId) {
  const theme = themes.find((entry) => entry.id === themeId);
  if (!theme) {
    return;
  }

  state.themeId = theme.id;
  state.gradientColors = [...theme.palette];
  syncGradientControls();
  elements.themeSelect.value = state.themeId;
  render();
}

function syncGradientControls() {
  elements.gradientStartInput.value = state.gradientColors[0];
  elements.gradientMiddleInput.value = state.gradientColors[1];
  elements.gradientEndInput.value = state.gradientColors[2];
  elements.gradientAngleRange.value = state.gradientAngle;
  elements.gradientAngleLabel.textContent = `${state.gradientAngle}°`;
}

function syncTypographyControls() {
  elements.fontSizeRange.value = state.fontSizeScale;
  elements.fontSizeValue.textContent = `${Math.round(state.fontSizeScale * 100)}%`;
  elements.textOffsetYRange.value = state.textOffsetY;
  elements.textOffsetYValue.textContent = `${state.textOffsetY} px`;
}

function loadImageFile(file) {
  const reader = new FileReader();
  reader.onload = () => {
    const image = new Image();
    image.onload = () => {
      state.image = image;
      state.imageName = file.name.replace(/\.[^.]+$/, '');
      if (state.autoFitOnImport) {
        fitImportedImage();
      }
      elements.fileStatus.textContent = `${file.name} · ${image.width} × ${image.height}`;
      render();
    };
    image.src = reader.result;
  };
  reader.readAsDataURL(file);
}

function fitImportedImage() {
  state.zoom = 1;
  state.offsetX = 0;
  state.offsetY = 0;
  elements.zoomRange.value = state.zoom;
  elements.offsetXRange.value = state.offsetX;
  elements.offsetYRange.value = state.offsetY;
}

function resetState() {
  state.presetId = 'iphone69';
  state.themeId = 'linen';
  state.fontId = 'editorial';
  state.fontWeightId = 'bold';
  state.fontSizeScale = 1;
  state.textOffsetY = 0;
  state.templateId = 'live-monitoring';
  state.textAlign = 'left';
  state.filenameBase = 'openlens-appstore-shot';
  state.gradientColors = ['#f4ecde', '#ebe2d2', '#f9f5ee'];
  state.gradientAngle = 135;
  state.fitMode = 'stretch';
  state.zoom = 1;
  state.offsetX = 0;
  state.offsetY = 0;
  state.deviceScale = 0.92;
  state.autoFitOnImport = true;
  state.gradientOnly = false;
  state.showFrame = true;
  state.showShadow = true;
  state.showTextPanel = true;
  state.image = null;
  state.imageName = '';

  elements.fileInput.value = '';
  elements.fileStatus.textContent = 'No file loaded';
  elements.presetSelect.value = state.presetId;
  elements.themeSelect.value = state.themeId;
  elements.fontSelect.value = state.fontId;
  elements.fontWeightSelect.value = state.fontWeightId;
  elements.templateSelect.value = state.templateId;
  elements.filenameInput.value = state.filenameBase;
  elements.fitModeSelect.value = state.fitMode;
  elements.textAlignSelect.value = state.textAlign;
  elements.zoomRange.value = state.zoom;
  elements.offsetXRange.value = state.offsetX;
  elements.offsetYRange.value = state.offsetY;
  elements.deviceScaleRange.value = state.deviceScale;
  elements.autoFitCheckbox.checked = state.autoFitOnImport;
  elements.gradientOnlyCheckbox.checked = state.gradientOnly;
  elements.showFrameCheckbox.checked = state.showFrame;
  elements.showShadowCheckbox.checked = state.showShadow;
  elements.showTextPanelCheckbox.checked = state.showTextPanel;
  syncSelectedDeviceMockup();
  syncGradientControls();
  syncTypographyControls();
  applyTemplate(state.templateId);
}

function copySpec() {
  const preset = activePreset();
  const deviceProfile = activeDeviceProfile();
  const payload = [
    `Preset: ${preset.label}`,
    `Dimensions: ${preset.width} × ${preset.height}`,
    `Theme: ${activeTheme().label}`,
    `Font: ${activeFont().label}`,
    `Font weight: ${activeFontWeight().label}`,
    `Font size: ${Math.round(state.fontSizeScale * 100)}%`,
    `Text vertical position: ${state.textOffsetY}px`,
    `Background mode: ${state.gradientOnly ? 'Gradient only' : 'Gradient + accents'}`,
    `Gradient: ${state.gradientColors.join(' → ')} @ ${state.gradientAngle}°`,
    `Frame: ${deviceProfile.name}`,
    `Top text: ${state.headline}`
  ].join('\n');

  navigator.clipboard.writeText(payload).then(() => {
    elements.copySpecButton.textContent = 'Copied';
    window.setTimeout(() => {
      elements.copySpecButton.textContent = 'Copy Spec';
    }, 1200);
  });
}

function downloadCurrentImage() {
  render();
  const preset = activePreset();
  const link = document.createElement('a');
  link.href = elements.canvas.toDataURL('image/png');
  link.download = `${resolvedFilenameBase()}-${preset.id}.png`;
  link.click();
}

function downloadAllPresets() {
  const originalPreset = state.presetId;

  presets.forEach((preset, index) => {
    window.setTimeout(() => {
      state.presetId = preset.id;
      elements.presetSelect.value = preset.id;
      render();

      const link = document.createElement('a');
      link.href = elements.canvas.toDataURL('image/png');
      link.download = `${resolvedFilenameBase()}-${preset.id}.png`;
      link.click();

      if (index === presets.length - 1) {
        state.presetId = originalPreset;
        elements.presetSelect.value = originalPreset;
        render();
      }
    }, index * 180);
  });
}

function activePreset() {
  return presets.find((preset) => preset.id === state.presetId) || presets[0];
}

function presetById(presetId) {
  return presets.find((preset) => preset.id === presetId) || presets[0];
}

function activeDeviceProfile() {
  const preset = activePreset();
  return deviceProfiles[preset.deviceId] || deviceProfiles.iphone17pm;
}

function syncSelectedDeviceMockup() {
  const preset = presetById(elements.presetSelect.value || state.presetId);
  const deviceProfile = deviceProfiles[preset.deviceId] || deviceProfiles.iphone17pm;
  elements.deviceMockupInput.value = deviceProfile.name;
}

function activeTheme() {
  return themes.find((theme) => theme.id === state.themeId) || themes[0];
}

function activeFont() {
  return fonts.find((font) => font.id === state.fontId) || fonts[0];
}

function activeFontWeight() {
  return fontWeights.find((weight) => weight.id === state.fontWeightId) || fontWeights[0];
}

function render() {
  const preset = activePreset();
  const theme = activeTheme();
  const deviceProfile = activeDeviceProfile();
  const deviceLayout = resolveDeviceLayout(preset, deviceProfile);

  elements.canvas.width = preset.width;
  elements.canvas.height = preset.height;
  elements.stageTitle.textContent = preset.label;
  elements.stageMeta.textContent = `${preset.width} × ${preset.height}`;
  elements.deviceMockupInput.value = deviceProfile.name;

  drawBackground(ctx, preset, theme);
  if (state.showTextPanel) {
    drawTextBlock(ctx, preset, theme, deviceLayout);
  }
  drawDevice(ctx, preset, deviceLayout, deviceProfile);
}

function drawBackground(context, preset, theme) {
  const gradient = createAngledGradient(context, preset.width, preset.height, state.gradientAngle);
  gradient.addColorStop(0, state.gradientColors[0]);
  gradient.addColorStop(0.52, state.gradientColors[1]);
  gradient.addColorStop(1, state.gradientColors[2]);

  context.fillStyle = gradient;
  context.fillRect(0, 0, preset.width, preset.height);

  if (state.gradientOnly) {
    return;
  }

  context.save();
  context.globalAlpha = 0.28;
  context.fillStyle = theme.accent;
  context.beginPath();
  context.ellipse(preset.width * 0.12, preset.height * 0.1, preset.width * 0.22, preset.height * 0.12, -0.8, 0, Math.PI * 2);
  context.fill();
  context.beginPath();
  context.ellipse(preset.width * 0.85, preset.height * 0.9, preset.width * 0.28, preset.height * 0.14, 0.4, 0, Math.PI * 2);
  context.fill();
  context.restore();
}

function drawTextBlock(context, preset, theme, deviceLayout) {
  const align = state.textAlign;
  const font = activeFont();
  const fontWeight = activeFontWeight();
  const textWidth = preset.width * 0.76;
  const x = align === 'center' ? preset.width / 2 : preset.width * 0.12;
  const topPadding = preset.height * 0.035;
  const safeBottom = deviceLayout.outerY - preset.height * 0.018;
  const requestedY = preset.height * 0.115 + state.textOffsetY;
  const minFontSize = Math.round(preset.width * 0.03);
  let fontSize = Math.round(preset.width * 0.068 * state.fontSizeScale);
  let lineHeight = Math.round(preset.width * 0.078 * state.fontSizeScale);

  context.textAlign = align;
  context.textBaseline = 'top';

  let textLayout = layoutWrappedText(context, state.headline, `${fontWeight.value} ${fontSize}px ${font.stack}`, textWidth, lineHeight);
  const availableHeight = Math.max(lineHeight, safeBottom - topPadding);

  while (textLayout.height > availableHeight && fontSize > minFontSize) {
    fontSize = Math.max(minFontSize, Math.round(fontSize * 0.96));
    lineHeight = Math.max(Math.round(fontSize * 1.14), Math.round(lineHeight * 0.96));
    textLayout = layoutWrappedText(context, state.headline, `${fontWeight.value} ${fontSize}px ${font.stack}`, textWidth, lineHeight);
    if (fontSize === minFontSize) {
      break;
    }
  }

  const y = Math.max(topPadding, Math.min(requestedY, safeBottom - textLayout.height));
  context.fillStyle = theme.text;
  drawWrappedTextLayout(context, textLayout, x, y);
}

function drawDevice(context, preset, deviceLayout, deviceProfile) {
  const { outerWidth, outerHeight, outerX, outerY, screenRect } = deviceLayout;
  const screenRadius = screenRect.width * deviceProfile.layout.screenCornerRatio;

  context.save();
  if (state.showShadow) {
    context.shadowColor = 'rgba(10, 18, 15, 0.28)';
    context.shadowBlur = preset.width * 0.045;
    context.shadowOffsetY = preset.height * 0.012;
  }

  context.save();
  drawRoundedRect(context, screenRect.x, screenRect.y, screenRect.width, screenRect.height, screenRadius);
  context.clip();
  if (state.image) {
    drawScreenshotCover(context, state.image, screenRect.x, screenRect.y, screenRect.width, screenRect.height);
  } else {
    drawPlaceholderScreen(context, screenRect.x, screenRect.y, screenRect.width, screenRect.height, preset);
  }
  context.restore();

  context.shadowColor = 'transparent';
  if (state.showFrame && deviceProfile.overlayCanvas) {
    context.drawImage(deviceProfile.overlayCanvas, outerX, outerY, outerWidth, outerHeight);
  }

  context.restore();
}

function resolveDeviceLayout(preset, deviceProfile) {
  const outerWidth = preset.width * deviceProfile.layout.widthRatio * state.deviceScale;
  const outerHeight = outerWidth / (deviceProfile.crop.width / deviceProfile.crop.height);
  const outerX = (preset.width - outerWidth) / 2;
  const outerY = preset.height - outerHeight - preset.height * deviceProfile.layout.bottomMarginRatio;
  const screenRect = resolveMockupScreenRect(outerX, outerY, outerWidth, outerHeight, deviceProfile);

  return {
    outerWidth,
    outerHeight,
    outerX,
    outerY,
    screenRect
  };
}

function resolveMockupScreenRect(outerX, outerY, outerWidth, outerHeight, deviceProfile) {
  return {
    x: outerX + (deviceProfile.screen.x / deviceProfile.crop.width) * outerWidth,
    y: outerY + (deviceProfile.screen.y / deviceProfile.crop.height) * outerHeight,
    width: (deviceProfile.screen.width / deviceProfile.crop.width) * outerWidth,
    height: (deviceProfile.screen.height / deviceProfile.crop.height) * outerHeight
  };
}

function resolvedFilenameBase() {
  return sanitizeFilename(state.filenameBase) || sanitizeFilename(state.imageName) || 'openlens-appstore-shot';
}

function sanitizeFilename(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

function loadMockupAssets() {
  Object.values(deviceProfiles).forEach((deviceProfile) => {
    const image = new Image();
    image.onload = () => {
      deviceProfile.image = image;
      deviceProfile.overlayCanvas = buildMockupOverlay(deviceProfile, image);
      deviceProfile.ready = true;
      render();
    };
    image.src = deviceProfile.path;
  });
}

function buildMockupOverlay(deviceProfile, image) {
  const canvas = document.createElement('canvas');
  canvas.width = deviceProfile.crop.width;
  canvas.height = deviceProfile.crop.height;

  const overlayContext = canvas.getContext('2d');
  overlayContext.drawImage(
    image,
    deviceProfile.crop.x,
    deviceProfile.crop.y,
    deviceProfile.crop.width,
    deviceProfile.crop.height,
    0,
    0,
    deviceProfile.crop.width,
    deviceProfile.crop.height
  );

  if (deviceProfile.keyColors.length === 0) {
    return canvas;
  }

  const imageData = overlayContext.getImageData(0, 0, canvas.width, canvas.height);
  const { data } = imageData;
  for (let index = 0; index < data.length; index += 4) {
    if (isKeyedPixel(data[index], data[index + 1], data[index + 2], deviceProfile.keyColors)) {
      data[index + 3] = 0;
    }
  }
  overlayContext.putImageData(imageData, 0, 0);
  return canvas;
}

function isKeyedPixel(red, green, blue, keyColors) {
  const channelSpread = Math.max(red, green, blue) - Math.min(red, green, blue);
  if (channelSpread > 4) {
    return false;
  }

  return keyColors.some((keyColor) => isWithinTolerance(
    red,
    green,
    blue,
    keyColor.red,
    keyColor.green,
    keyColor.blue,
    keyColor.tolerance
  ));
}

function isWithinTolerance(red, green, blue, targetRed, targetGreen, targetBlue, tolerance) {
  return Math.abs(red - targetRed) <= tolerance
    && Math.abs(green - targetGreen) <= tolerance
    && Math.abs(blue - targetBlue) <= tolerance;
}

function drawScreenshotCover(context, image, x, y, width, height) {
  let drawWidth;
  let drawHeight;

  if (state.fitMode === 'stretch') {
    drawWidth = width * state.zoom;
    drawHeight = height * state.zoom;
  } else {
    const baseScale = state.fitMode === 'contain'
      ? Math.min(width / image.width, height / image.height)
      : Math.max(width / image.width, height / image.height);
    const scale = baseScale * state.zoom;
    drawWidth = image.width * scale;
    drawHeight = image.height * scale;
  }

  const drawX = x + (width - drawWidth) / 2 + state.offsetX;
  const drawY = y + (height - drawHeight) / 2 + state.offsetY;
  context.drawImage(image, drawX, drawY, drawWidth, drawHeight);
}

function drawPlaceholderScreen(context, x, y, width, height, preset) {
  const placeholder = context.createLinearGradient(x, y, x + width, y + height);
  placeholder.addColorStop(0, '#121d34');
  placeholder.addColorStop(1, '#26496d');
  context.fillStyle = placeholder;
  context.fillRect(x, y, width, height);

  context.fillStyle = 'rgba(255,255,255,0.12)';
  context.fillRect(x + width * 0.08, y + height * 0.11, width * 0.84, height * 0.12);
  context.fillRect(x + width * 0.08, y + height * 0.28, width * 0.84, height * 0.08);
  context.fillRect(x + width * 0.08, y + height * 0.39, width * 0.7, height * 0.08);
  context.fillRect(x + width * 0.08, y + height * 0.56, width * 0.84, height * 0.2);

  context.fillStyle = 'rgba(255,255,255,0.9)';
  context.textAlign = 'center';
  context.font = `700 ${Math.round(preset.width * 0.032)}px Georgia`;
  context.fillText('Upload a screenshot to preview it here', x + width / 2, y + height * 0.84);
}

function fillWrappedText(context, text, x, y, maxWidth, lineHeight) {
  const layout = layoutWrappedText(context, text, context.font, maxWidth, lineHeight);
  drawWrappedTextLayout(context, layout, x, y);
  return layout.height;
}

function layoutWrappedText(context, text, font, maxWidth, lineHeight) {
  if (!text) {
    return { font, lineHeight, lines: [], height: 0 };
  }

  context.font = font;
  const words = text.split(/\s+/).filter(Boolean);
  const lines = [];
  let currentLine = '';

  words.forEach((word) => {
    const trialLine = currentLine ? `${currentLine} ${word}` : word;
    if (context.measureText(trialLine).width > maxWidth && currentLine) {
      lines.push(currentLine);
      currentLine = word;
      return;
    }
    currentLine = trialLine;
  });

  if (currentLine) {
    lines.push(currentLine);
  }

  return {
    font,
    lineHeight,
    lines,
    height: lines.length * lineHeight
  };
}

function drawWrappedTextLayout(context, layout, x, y) {
  context.font = layout.font;
  layout.lines.forEach((line, index) => {
    context.fillText(line, x, y + (index * layout.lineHeight));
  });
}

function drawRoundedRect(context, x, y, width, height, radius) {
  const clippedRadius = Math.min(radius, width / 2, height / 2);
  context.beginPath();
  context.moveTo(x + clippedRadius, y);
  context.arcTo(x + width, y, x + width, y + height, clippedRadius);
  context.arcTo(x + width, y + height, x, y + height, clippedRadius);
  context.arcTo(x, y + height, x, y, clippedRadius);
  context.arcTo(x, y, x + width, y, clippedRadius);
  context.closePath();
}

function createAngledGradient(context, width, height, angleDegrees) {
  const radians = (angleDegrees - 90) * (Math.PI / 180);
  const centerX = width / 2;
  const centerY = height / 2;
  const length = Math.abs(width * Math.cos(radians)) + Math.abs(height * Math.sin(radians));
  const halfLength = length / 2;
  const x0 = centerX - Math.cos(radians) * halfLength;
  const y0 = centerY - Math.sin(radians) * halfLength;
  const x1 = centerX + Math.cos(radians) * halfLength;
  const y1 = centerY + Math.sin(radians) * halfLength;
  return context.createLinearGradient(x0, y0, x1, y1);
}