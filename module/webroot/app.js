// SPDX-License-Identifier: Apache-2.0
import { exec } from './vendor/kernelsu.js';

const $ = id => document.getElementById(id);
const COMMAND = 'sh /data/adb/modules/dtbo_oc/bin/webuictl.sh';
let state = null;
let busy = false;
let connected = false;
let dirty = false;
let sel = { hz: null, battery: null, oc_mode: null, ltpo_off: null };

const BATT_LABELS = {
  0: ['原版电池', '保持出厂电池与充电策略'],
  1: ['解除充电限流', '电池参数保持原版'],
  2: ['解除限流 + 电池解容', '关机 2.8V / 1% 2.85V / 充电欠压 2.7V'],
  3: ['6100mAh 魔改电池', '关机 3.0V / 1% 3.05V / 满充 4.54V'],
  4: ['魔改电池 + 解除限流', '同 6100mAh 并解除充电限流'],
  5: ['原版电池 + 电池解容', '关机 2.8V / 1% 2.85V / 充电欠压 2.7V'],
  6: ['GT7P 竞速版解容', '满充 4.55V / 关机 2.85V / 解除限流']
};

function notify(message, isError = false) {
  const box = $(isError ? 'error' : 'notice');
  $(isError ? 'notice' : 'error').hidden = true;
  box.textContent = message;
  box.hidden = !message;
}

async function command(args, timeoutMs = 60000) {
  if (!window.ksu || typeof window.ksu.exec !== 'function') {
    throw new Error('请从 KernelSU 管理器打开本模块的 WebUI。');
  }
  let timeoutId;
  try {
    const result = await Promise.race([
      exec(`${COMMAND} ${args}`),
      new Promise((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error('请求超时, 请稍后刷新当前状态。')), timeoutMs);
      }),
    ]);
    let data;
    try { data = JSON.parse(result.stdout.trim()); }
    catch { throw new Error('无法读取控制接口的返回结果, 请确认模块已安装并重启。'); }
    if (Number(result.errno) !== 0 && data.ok) throw new Error('控制接口执行失败, 请刷新当前状态。');
    if (!data || data.ok !== true) throw new Error(data?.message || '操作失败。');
    return data;
  } finally {
    clearTimeout(timeoutId);
  }
}

function controls() {
  const ready = connected && state && !busy;
  document.body.classList.toggle('busy', busy);
  $('refresh').disabled = busy;
  $('apply').disabled = !ready;
  $('restore').disabled = !ready || busy;
  $('apply-label').textContent = busy ? '正在处理…' : '保存并应用';
  const hzText = sel.hz === 0 ? '不超频' : sel.hz ? `${sel.hz}Hz` : '—';
  const modeText = sel.oc_mode === 'ko' ? 'KO 挂载' : sel.oc_mode === 'dtbo' ? 'DTBO 补丁' : '—';
  $('selection').textContent = `${hzText} · ${modeText}`;
}

function radioButton(className, label, checked, onClick, disabled = false) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = className;
  button.setAttribute('role', 'radio');
  button.setAttribute('aria-label', label);
  button.setAttribute('aria-checked', String(checked));
  button.disabled = disabled;
  button.tabIndex = checked ? 0 : -1;
  button.addEventListener('click', onClick);
  return button;
}
function span(className, text) {
  const element = document.createElement('span');
  element.className = className;
  element.textContent = text;
  return element;
}

function drawRates() {
  const fragment = document.createDocumentFragment();
  const choices = state?.choices || [];
  const sfOk = state?.sf?.ok && Array.isArray(state.sf.modes);
  const activeHz = sfOk ? state.sf.active.hz : null;
  const stockHz = [];
  if (sfOk) {
    state.sf.modes.forEach(m => {
      if (m.hz < 130 && !stockHz.includes(m.hz)) stockHz.push(m.hz);
    });
    stockHz.sort((a, b) => a - b);
  }
  if (!state?.oc_capable) {
    sel.hz = 0;
    $('rates-caption').textContent = '本机型不支持超频';
    if (stockHz.length) {
      const frag = document.createDocumentFragment();
      stockHz.forEach(hz => {
        const b = radioButton('rate-choice stock', `${hz}Hz 原厂`, activeHz === hz, () => {}, true);
        b.append(span('rate-number', String(hz)), span('rate-unit', 'Hz'), span('oc-label', '原厂'));
        frag.append(b);
      });
      $('rates').replaceChildren(frag);
    } else {
      $('rates').replaceChildren(span('placeholder', '本机型不支持刷新率超频 (仅电池/充电方案)'));
    }
    return;
  }
  stockHz.forEach(hz => {
    const checked = activeHz === hz;
    const b = radioButton('rate-choice stock', `${hz}Hz 原厂`, checked, () => {}, true);
    b.append(span('rate-number', String(hz)), span('rate-unit', 'Hz'), span('oc-label', '原厂'));
    fragment.append(b);
  });
  choices.forEach(c => {
    const checked = sel.hz === c || (activeHz === c && sel.hz === null);
    const button = radioButton('rate-choice overclock', `${c}Hz 超频`, checked, () => {
      sel.hz = c; dirty = true; drawRates(); controls();
    });
    button.append(span('rate-number', String(c)), span('rate-unit', 'Hz'), span('oc-label', '超频'));
    fragment.append(button);
  });
  const off = radioButton('rate-choice', '不超频', sel.hz === 0, () => {
    sel.hz = 0; dirty = true; drawRates(); controls();
  });
  off.append(span('rate-number', '关'), span('rate-unit', 'OC'));
  fragment.append(off);
  $('rates').replaceChildren(fragment);
  $('rates-caption').textContent = `原厂 ${stockHz.length} 档 + 超频 ${choices.length} 档`;
}

function drawBatts() {
  const options = [0, 1, 2, 5];
  if (state?.batt_capable) options.push(3, 4);
  if (state?.device === 'gt7p') options.length = 0, options.push(0, 6);
  const fragment = document.createDocumentFragment();
  options.forEach(v => {
    const [title, detail] = BATT_LABELS[v] || [`选项 ${v}`, ''];
    const checked = sel.battery === v;
    const button = radioButton('batt-choice', title, checked, () => {
      sel.battery = v; dirty = true; drawBatts(); controls();
    });
    const t = span('b-title', title);
    if (v === 3 || v === 4) t.classList.add('warn');
    button.append(t, span('b-detail', detail));
    fragment.append(button);
  });
  $('batts').replaceChildren(fragment);
  $('batt-caption').textContent = `${options.length} 个方案`;
}

function drawModes() {
  const fragment = document.createDocumentFragment();
  const koOnly = !!state?.ko_only;
  const koAvail = !!state?.ko?.available;
  if (!koOnly) {
    const dtbo = radioButton('mode-choice', 'DTBO 补丁', sel.oc_mode === 'dtbo', () => {
      sel.oc_mode = 'dtbo'; dirty = true; drawModes(); controls();
    });
    dtbo.append(span('m-title', 'DTBO 补丁'), span('m-detail', '生成超频 DTBO 并刷入, 重启后生效'));
    fragment.append(dtbo);
  }
  if (koAvail || koOnly) {
    const koWarn = state?.ko?.vermatch === 0;
    const ko = radioButton('mode-choice ko', 'KO 内核挂载', sel.oc_mode === 'ko', () => {
      sel.oc_mode = 'ko'; dirty = true;
      if (sel.battery !== 0) sel.battery = 0;
      drawModes(); drawBatts(); controls();
    });
    ko.append(span('m-title', 'KO 内核挂载'), span('m-detail', koWarn
      ? 'KO 与当前内核版本不匹配, OTA 后需等待模块更新'
      : state?.ko?.builtin
        ? '开机加载内置内核模块, 不动 DTBO, 重启生效'
        : '开机加载内核模块, 不动 DTBO, 重启生效'));
    fragment.append(ko);
  }
  $('modes').replaceChildren(fragment);
  $('mode-caption').textContent = sel.oc_mode === 'ko' ? 'KO 挂载' : 'DTBO 补丁';
}

function render(data, applied = false) {
  state = data;
  connected = true;
  if (applied || !dirty) {
    sel = { hz: data.hz, battery: data.battery, oc_mode: data.oc_mode, ltpo_off: data.ltpo_off };
    dirty = false;
  }
  $('connection').textContent = '已连接';
  $('connection').className = 'badge online';
  document.querySelector('.current-card').classList.add('connected');
  $('device-name').textContent = data.name || '未知机型';
  $('device-rate').textContent = data.maxrate ? `原厂最高 ${data.maxrate}Hz` : '';
  const curHz = data.hz === 0 ? '不超频' : String(data.hz);
  $('current-rate').textContent = curHz;
  $('current-rate-unit').textContent = data.hz === 0 ? '' : 'Hz';
  if (data.oc_mode === 'ko') {
    $('current-mode').textContent = 'KO 挂载';
    if (data.ko?.vermatch === 0) {
      $('current-detail').textContent = 'KO 与当前内核不匹配, 已拒绝加载 (等待模块更新)';
    } else if (data.ko?.loaded) {
      $('current-detail').textContent = data.ko?.installed ? '已挂载并启用' : '已挂载 (状态待确认)';
    } else if (data.ko?.available) {
      $('current-detail').textContent = '待加载 (保存后重启生效)';
    } else {
      $('current-detail').textContent = '未安装';
    }
  } else {
    $('current-mode').textContent = 'DTBO 补丁';
    $('current-detail').textContent = data.dtbo_patched ? 'DTBO: 已修改' : 'DTBO: 原厂';
  }
  $('ltpo-off').checked = data.ltpo_off === 1;
  drawRates();
  drawBatts();
  drawModes();
  controls();
}

async function refresh(manual) {
  if (busy) return;
  busy = true;
  controls();
  try {
    render(await command('status'));
    $('error').hidden = true;
    if (manual) notify('已更新当前状态。');
  } catch (error) {
    connected = false;
    $('connection').textContent = '未连接';
    $('connection').className = 'badge offline';
    document.querySelector('.current-card').classList.remove('connected');
    notify(error.message, true);
  } finally {
    busy = false;
    controls();
  }
}

async function apply() {
  if (busy || !connected || !state) return;
  busy = true;
  controls();
  notify('正在保存配置并应用… (DTBO 方案包含解包/打包/刷入, 请稍候)');
  try {
    if (sel.oc_mode === 'ko' && sel.battery !== 0) sel.battery = 0;
    await command(`save hz=${sel.hz} battery=${sel.battery} oc_mode=${sel.oc_mode} ltpo_off=${sel.ltpo_off ? 1 : 0}`);
    const result = await command('apply', 120000);
    notify(result.message || '已应用, 重启后生效。');
    dirty = false;
    render(await command('status'));
  } catch (error) {
    notify(error.message, true);
    try { render(await command('status')); } catch { connected = false; }
  } finally {
    busy = false;
    controls();
  }
}

async function restore() {
  if (busy || !connected) return;
  busy = true;
  controls();
  notify('正在恢复原厂 DTBO / 卸载 KO…');
  try {
    const result = await command('restore', 90000);
    notify(result.message || '已恢复原厂。');
    dirty = false;
    render(await command('status'));
  } catch (error) {
    notify(error.message, true);
  } finally {
    busy = false;
    controls();
  }
}

['rates', 'batts', 'modes'].forEach(id => $(id).addEventListener('keydown', event => {
  if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
  const options = [...$(id).querySelectorAll('button:not(:disabled)')];
  const i = options.indexOf(event.target);
  if (i < 0 || !options.length) return;
  event.preventDefault();
  const direction = ['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 1;
  options[(i + direction + options.length) % options.length].click();
}));

$('ltpo-off').addEventListener('change', () => {
  sel.ltpo_off = $('ltpo-off').checked ? 1 : 0;
  dirty = true;
  controls();
});
$('refresh').addEventListener('click', () => refresh(true));
$('apply').addEventListener('click', apply);
$('restore').addEventListener('click', restore);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) refresh(false);
});
refresh(false);
