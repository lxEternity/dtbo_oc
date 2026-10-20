// SPDX-License-Identifier: Apache-2.0
import { exec } from './vendor/kernelsu.js';

const $ = id => document.getElementById(id);
const COMMAND = 'sh /data/adb/modules/dtbo_oc/bin/webuictl.sh';
let state = null;
let busy = false;
let rcBusy = false;
let apBusy = false;
let connected = false;
let dirty = false;
let rcSel = { base: null, ladder: [] };
let rcDirty = false;
let sel = { hz: null, battery: null, oc_mode: null, ltpo_off: null };

const BATT_LABELS = {
  0: ['原版电池', '保持出厂电池与充电策略'],
  1: ['解除充电限流', '电池参数保持原版'],
  2: ['解除限流 + 电池解容', '关机 2.8V / 1% 2.85V / 显示真实电量'],
  3: ['6100mAh 魔改电池', '关机 3.0V / 1% 3.05V / 满充 4.54V'],
  4: ['魔改电池 + 解除限流', '同 6100mAh 并解除充电限流'],
  5: ['原版电池 + 电池解容', '关机 2.8V / 1% 2.85V / 显示真实电量'],
  6: ['GT7P 竞速版解容', '满充 4.55V / 关机 2.85V / 显示真实电量']
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

function licBlocked() {
  const licOk = state?.license?.state === 'ok';
  const needOC = (sel.hz ?? 0) > 0 || (sel.oc_mode === 'dtbo' && (sel.battery ?? 0) > 0);
  return !licOk && needOC;
}

function drawLicense() {
  const lic = state?.license;
  const box = $('verify-state');
  const okLic = lic?.state === 'ok';
  box.classList.toggle('ok', okLic);
  box.classList.toggle('bad', !okLic && !!lic);
  if (okLic) {
    $('verify-text').textContent = lic.expiry === '永久'
      ? '已验证Q群 永久'
      : `已验证Q群 期限${lic.expiry || '未知'}`;
    $('verify-caption').textContent = '已验证';
  } else if (lic?.state === 'expired') {
    $('verify-text').textContent = `授权已过期 (QQ ${lic.qq || ''}), 请重新验证`;
    $('verify-caption').textContent = '已过期';
  } else if (lic?.state === 'wrongmachine') {
    $('verify-text').textContent = `授权绑定于其他设备 (QQ ${lic.qq || ''}), 请在本机重新验证`;
    $('verify-caption').textContent = '设备不符';
  } else if (lic?.state === 'bad') {
    $('verify-text').textContent = '授权文件无效, 请重新验证';
    $('verify-caption').textContent = '无效';
  } else {
    $('verify-text').textContent = '未验证 — 使用超频/刷入功能需先验证已加入QQ群';
    $('verify-caption').textContent = '未验证';
  }
  $('machine-id').textContent = state?.machine || '—';
}

function controls() {
  const ready = connected && state && !busy;
  const sw = switchModeActive();
  const blocked = licBlocked();
  document.body.classList.toggle('busy', busy);
  $('refresh').disabled = busy;
  if (sw) {
    const hasChanges = rcDirty || dirty;
    $('apply').disabled = !ready || busy || !hasChanges || (dirty && blocked);
    $('apply-label').textContent = busy ? '正在处理…'
      : dirty && blocked ? '需先完成QQ群验证'
        : hasChanges ? '保存切换配置' : '已同步';
    const baseT = rcSel.base ? `基准 ${rcSel.base}Hz` : '未设基准';
    const ladT = rcSel.ladder.length ? `升挡 ${rcSel.ladder.join('→')}Hz` : '无升挡序列';
    $('selection').textContent = `${baseT} · ${ladT}${dirty ? ' · 配置待保存' : ''}`;
  } else {
    $('apply').disabled = !ready || blocked;
    $('apply-label').textContent = busy ? '正在处理…' : blocked ? '需先完成QQ群验证' : '保存并应用';
    const hzText = sel.hz === 0 ? '不超频' : sel.hz ? `${sel.hz}Hz` : '—';
    const modeText = sel.oc_mode === 'ko' ? 'KO 挂载' : sel.oc_mode === 'dtbo' ? 'DTBO 补丁' : '—';
    $('selection').textContent = `${hzText} · ${modeText}`;
  }
  $('restore').disabled = !ready || busy;
  syncRcControls();
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

function switchModeActive() {
  const sfOk = state?.sf?.ok && Array.isArray(state.sf.modes);
  if (!sfOk || !state?.oc_capable) return false;
  const maxrate = Number(state.maxrate) || 120;
  return state.sf.modes.some(m => m.hz > maxrate);
}

async function ratectlCommand(args, okMsg) {
  if (rcBusy || busy) return;
  rcBusy = true;
  syncRcControls();
  try {
    const result = await command(`ratectl ${args}`);
    if (result && result.ratectl) {
      state.ratectl = result.ratectl;
      if (!rcDirty) {
        rcSel = {
          base: result.ratectl.base ? Number(result.ratectl.base) : null,
          ladder: Array.isArray(result.ratectl.ladder) ? [...result.ratectl.ladder] : []
        };
      }
      drawRates();
      drawPerapp();
      controls();
    } else {
      render(await command('status'));
    }
    notify(okMsg || result.message || '已保存。');
  } catch (error) {
    notify(error.message, true);
    drawPerapp();
  } finally {
    rcBusy = false;
    syncRcControls();
    controls();
  }
}

function syncRcControls() {
  const off = rcBusy || busy;
  ['perapp-toggle', 'lockboot-toggle'].forEach(id => { $(id).disabled = off; });
  document.querySelectorAll('#app-rows select, #app-rows button').forEach(el => { el.disabled = off; });
}

async function switchHz(hz) {
  if (busy) return;
  busy = true;
  controls();
  try {
    const result = await command(`switch hz=${hz}`, 30000);
    notify(result.message || `已切换至 ${hz}Hz。`);
    render(await command('status'));
  } catch (error) {
    notify(error.message, true);
  } finally {
    busy = false;
    controls();
  }
}

async function releaseRate() {
  if (busy) return;
  busy = true;
  controls();
  try {
    const result = await command('release', 30000);
    notify(result.message || '已交还系统自动调频。');
    render(await command('status'));
  } catch (error) {
    notify(error.message, true);
  } finally {
    busy = false;
    controls();
  }
}

function drawRatesSwitch(fragment, rc) {
  const maxrate = Number(state.maxrate) || 120;
  const activeHz = state.sf.active.hz;
  const modes = [];
  state.sf.modes.forEach(m => {
    if (!modes.includes(m.hz)) modes.push(m.hz);
  });
  modes.sort((a, b) => a - b);
  const ladder = rcSel.ladder;
  const baseHz = rcSel.base;
  const pinned = !!state.sf.pinned;
  const redraw = () => { drawRates(); controls(); };
  modes.forEach(hz => {
    const oc = hz > maxrate;
    const inLadder = ladder.includes(hz);
    const card = document.createElement('div');
    card.className = 'rate-card' + (oc ? ' oc' : ' stock') + (activeHz === hz ? ' cur' : '') + (baseHz === hz ? ' base' : '');
    const head = document.createElement('button');
    head.type = 'button';
    head.className = 'rc-head';
    head.setAttribute('aria-label', `切换到 ${hz}Hz`);
    head.addEventListener('click', () => switchHz(hz));
    head.append(span('rate-number', String(hz)), span('rate-unit', 'Hz'));
    const tags = span('rc-tags', '');
    tags.append(span('rc-tag', oc ? '超频' : '原生'));
    if (activeHz === hz) tags.append(span('rc-tag cur', '当前'));
    if (baseHz === hz) tags.append(span('rc-tag base', '基准'));
    head.append(tags);
    card.append(head);
    const actions = document.createElement('div');
    actions.className = 'rc-actions';
    const baseBtn = document.createElement('button');
    baseBtn.type = 'button';
    baseBtn.className = 'rc-btn' + (baseHz === hz ? ' on' : '');
    baseBtn.textContent = baseHz === hz ? '✓ 基准' : '设为基准';
    baseBtn.addEventListener('click', () => {
      rcSel.base = hz; rcDirty = true; redraw();
    });
    actions.append(baseBtn);
    if (oc) {
      const ocBtn = document.createElement('button');
      ocBtn.type = 'button';
      ocBtn.className = 'rc-btn' + (inLadder ? ' on' : '');
      ocBtn.textContent = '超频';
      ocBtn.addEventListener('click', () => {
        if (inLadder) rcSel.ladder = ladder.filter(v => v !== hz);
        else rcSel.ladder = [...ladder, hz].sort((a, b) => a - b);
        rcDirty = true; redraw();
      });
      actions.append(ocBtn);
      if (inLadder) {
        const order = ladder.indexOf(hz) + 1;
        const orderWrap = span('rc-order', '');
        orderWrap.append(document.createTextNode('顺序'));
        const input = document.createElement('input');
        input.type = 'number';
        input.min = '1';
        input.max = '9';
        input.value = String(order);
        input.setAttribute('aria-label', `${hz}Hz 切换顺序`);
        input.addEventListener('change', () => {
          let n = parseInt(input.value, 10);
          if (!Number.isFinite(n) || n < 1) n = 1;
          if (n > ladder.length) n = ladder.length;
          const rest = ladder.filter(v => v !== hz);
          rcSel.ladder = [...rest.slice(0, n - 1), hz, ...rest.slice(n - 1)];
          rcDirty = true; redraw();
        });
        orderWrap.append(input);
        actions.append(orderWrap);
      }
    }
    card.append(actions);
    fragment.append(card);
  });
  const tools = $('rate-tools');
  tools.hidden = false;
  const lockBtn = $('lock-btn');
  lockBtn.textContent = pinned ? '解锁 (交还系统)' : '锁定基准档位';
  lockBtn.classList.toggle('on', pinned);
  lockBtn.onclick = () => {
    if (pinned) releaseRate();
    else if (rcSel.base) switchHz(rcSel.base);
    else notify('请先在档位卡片上设置基准档。', true);
  };
  const lockState = $('lock-state');
  lockState.textContent = pinned
    ? `已锁定${rcSel.base ? ` · 基准 ${rcSel.base}Hz` : ''}${rc?.perapp === 1 ? ' · 按应用' : ''}`
    : '自动调频';
  $('rate-heading').textContent = '切换档位';
  $('rates-caption').textContent = `共 ${modes.length} 档${rcSel.base ? ` · 基准 ${rcSel.base}Hz` : ''}${rcDirty ? ' · 待保存' : ''}`;
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
  if (switchModeActive()) {
    drawRatesSwitch(fragment, state?.ratectl);
    $('rates').classList.add('two-col');
    $('rates').replaceChildren(fragment);
    return;
  }
  $('rates').classList.remove('two-col');
  $('rate-tools').hidden = true;
  $('rate-heading').textContent = '超频档位';
  if (!state?.oc_capable) {
    sel.hz = 0;
    $('rates-caption').textContent = '本机型不支持超频';
    const frag = document.createDocumentFragment();
    stockHz.forEach(hz => {
      const b = radioButton('rate-choice stock', `${hz}Hz 原厂`, activeHz === hz, () => {}, true);
      b.append(span('rate-number', String(hz)), span('rate-unit', 'Hz'), span('oc-label', '原厂'));
      frag.append(b);
    });
    const off = radioButton('rate-choice', '不超频', true, () => {});
    off.append(span('rate-number', '关'), span('rate-unit', 'OC'));
    frag.append(off);
    $('rates').replaceChildren(frag);
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

function perappRateOptions(rc) {
  const maxrate = Number(state.maxrate) || 120;
  const opts = [];
  if (state?.sf?.ok && Array.isArray(state.sf.modes)) {
    state.sf.modes.forEach(m => { if (!opts.includes(m.hz)) opts.push(m.hz); });
    opts.sort((a, b) => a - b);
  } else {
    (Array.isArray(rc?.ladder) ? rc.ladder : []).forEach(v => { if (!opts.includes(v)) opts.push(v); });
    if (rc?.base && !opts.includes(Number(rc.base))) opts.push(Number(rc.base));
    opts.sort((a, b) => a - b);
  }
  return opts;
}

function drawPerapp() {
  const section = $('perapp-section');
  if (!switchModeActive()) {
    section.hidden = true;
    return;
  }
  section.hidden = false;
  const rc = state?.ratectl || {};
  const ladder = Array.isArray(rc.ladder) ? rc.ladder : [];
  const baseHz = Number(rc.base) || null;
  $('perapp-toggle').checked = rc.perapp === 1;
  $('lockboot-toggle').checked = rc.lockboot === 1;
  const appMap = rc.apps && typeof rc.apps === 'object' ? rc.apps : {};
  const pkgs = Object.keys(appMap);
  const opts = perappRateOptions(rc);
  const rows = document.createDocumentFragment();
  pkgs.forEach(pkg => {
    const hz = Number(appMap[pkg]) || baseHz || opts[0] || 120;
    const row = document.createElement('div');
    row.className = 'app-row';
    const name = span('app-name', appNames[pkg] || pkg);
    if (appNames[pkg] && appNames[pkg] !== pkg) name.append(span('app-pkg-sm', pkg));
    row.append(name);
    const select = document.createElement('select');
    select.className = 'app-hz';
    select.setAttribute('aria-label', `${pkg} 档位`);
    opts.forEach(v => {
      const o = document.createElement('option');
      o.value = String(v);
      o.textContent = `${v}Hz`;
      if (v === hz) o.selected = true;
      select.append(o);
    });
    select.addEventListener('change', () => {
      ratectlCommand(`app set ${pkg} ${select.value}`, `已设置 ${pkg} -> ${select.value}Hz。`);
    });
    row.append(select);
    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'rc-btn del';
    del.textContent = '移除';
    del.addEventListener('click', () => {
      ratectlCommand(`app del ${pkg}`, `已移除 ${pkg}。`);
    });
    row.append(del);
    rows.append(row);
  });
  if (!pkgs.length) {
    const empty = span('app-empty', '尚未配置应用; 点「+ 添加应用」选择应用并设定其最高档位。');
    rows.append(empty);
  }
  $('app-rows').replaceChildren(rows);
  const cap = [];
  cap.push(rc.perapp === 1 ? '已开启' : '未开启');
  if (baseHz) cap.push(`基准 ${baseHz}Hz`);
  if (rc.daemon === 1) cap.push('服务运行中');
  $('perapp-caption').textContent = cap.join(' · ');
  syncRcControls();
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
  if (sel.hz > 0 && Array.isArray(data.choices) && data.choices.length && !data.choices.includes(sel.hz)) {
    notify(`已保存的 ${sel.hz}Hz 档位因稳定性问题已移除, 请重新选择档位。`);
    sel.hz = 0;
    dirty = true;
  }
  if (applied || !rcDirty) {
    const rc = data.ratectl || {};
    rcSel = {
      base: rc.base ? Number(rc.base) : null,
      ladder: Array.isArray(rc.ladder) ? [...rc.ladder] : []
    };
    rcDirty = false;
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
  $('fps-show').checked = data.fps_show === 1;
  if (data.version) $('ver').textContent = data.version;
  drawLicense();
  drawRates();
  drawPerapp();
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
  const sw = switchModeActive();
  if (!sw && licBlocked()) {
    notify('请先完成QQ群验证: 在上方输入QQ号并点击验证。', true);
    return;
  }
  if (sw && !rcDirty && !dirty) return;
  busy = true;
  controls();
  if (sw) {
    notify(rcDirty ? '正在保存切换配置…' : '正在保存配置…');
    try {
      if (rcDirty) {
        const parts = [];
        if (rcSel.base) parts.push(`base=${rcSel.base}`);
        if (rcSel.ladder.length) parts.push(`ladder=${rcSel.ladder.join(',')}`);
        if (parts.length) await command(`ratectl save ${parts.join(' ')}`, 30000);
        rcDirty = false;
      }
      if (dirty) {
        if (sel.oc_mode === 'ko' && sel.battery !== 0) sel.battery = 0;
        await command(`save hz=${sel.hz} battery=${sel.battery} oc_mode=${sel.oc_mode} ltpo_off=${sel.ltpo_off ? 1 : 0}`);
        await command('apply', 120000);
        dirty = false;
      }
      notify('切换配置已保存。');
      render(await command('status'));
    } catch (error) {
      notify(error.message, true);
      try { render(await command('status')); } catch { connected = false; }
    } finally {
      busy = false;
      controls();
    }
    return;
  }
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

async function verify(auto = false) {
  if (busy) return;
  let arg;
  if (auto) {
    arg = 'auto=1';
  } else {
    const qq = $('qq-input').value.trim();
    if (!/^[1-9][0-9]{4,10}$/.test(qq)) {
      notify('请输入正确的QQ号 (5-11位数字, 不以0开头)', true);
      return;
    }
    arg = `qq=${qq}`;
  }
  busy = true;
  controls();
  $('verify-btn').disabled = true;
  $('verify-auto-btn').disabled = true;
  notify(auto ? '正在自动检测本机QQ并联网验证…' : '正在联网验证QQ群成员身份…');
  try {
    await command(`verify ${arg}`, 120000);
    $('qq-input').value = '';
    render(await command('status'));
    notify('');
  } catch (error) {
    notify(error.message, true);
  } finally {
    busy = false;
    $('verify-btn').disabled = false;
    $('verify-auto-btn').disabled = false;
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
$('fps-show').addEventListener('change', async () => {
  const want = $('fps-show').checked;
  const prev = state?.fps_show === 1;
  if (want === prev) return;
  $('fps-show').disabled = true;
  try {
    const r = await command(`fps ${want ? 'on' : 'off'}`, 15000);
    if (state) state.fps_show = r.fps_show === 1 ? 1 : 0;
    notify(r.fps_show === 1 ? '帧率显示已开启。' : '帧率显示已关闭。');
  } catch (error) {
    $('fps-show').checked = prev;
    notify(error.message, true);
  } finally {
    $('fps-show').disabled = false;
  }
});
$('perapp-toggle').addEventListener('change', () => {
  ratectlCommand(`save perapp=${$('perapp-toggle').checked ? 1 : 0}`,
    $('perapp-toggle').checked ? '按应用自动切换已开启。' : '按应用自动切换已关闭。');
});
$('lockboot-toggle').addEventListener('change', () => {
  ratectlCommand(`save lockboot=${$('lockboot-toggle').checked ? 1 : 0}`,
    $('lockboot-toggle').checked ? '开机自动锁定已开启。' : '开机自动锁定已关闭。');
});
let apTimer = 0;
const appNames = {};
async function openAppPicker() {
  if (apBusy) return;
  apBusy = true;
  const picker = $('app-picker');
  const list = $('ap-list');
  list.replaceChildren(span('app-empty', '正在读取应用列表…'));
  picker.hidden = false;
  $('ap-search').value = '';
  try {
    const result = await command('apps', 60000);
    const all = (Array.isArray(result.apps) ? result.apps : [])
      .map(a => (typeof a === 'string' ? { p: a, n: a } : a))
      .filter(a => a && a.p);
    all.forEach(a => { appNames[a.p] = a.n || a.p; });
    const rc = state?.ratectl || {};
    const appMap = rc.apps && typeof rc.apps === 'object' ? rc.apps : {};
    const avail = all.filter(a => !(a.p in appMap));
    renderApList(avail, '');
    $('ap-search').oninput = () => {
      clearTimeout(apTimer);
      apTimer = setTimeout(() => renderApList(avail, $('ap-search').value.trim().toLowerCase()), 120);
    };
  } catch (error) {
    list.replaceChildren(span('app-empty', error.message));
  } finally {
    apBusy = false;
  }
}
function renderApList(avail, kw) {
  const list = $('ap-list');
  const items = kw ? avail.filter(a =>
    a.p.toLowerCase().includes(kw) || (a.n || '').toLowerCase().includes(kw)) : avail;
  const frag = document.createDocumentFragment();
  const rc = state?.ratectl || {};
  const ladder = Array.isArray(rc.ladder) ? rc.ladder : [];
  const baseHz = Number(rc.base) || 120;
  const opts = perappRateOptions(rc);
  const defHz = opts.length ? opts[opts.length - 1] : baseHz;
  items.slice(0, 300).forEach(a => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'ap-item';
    const name = span('ap-name', a.n || a.p);
    const pkg = span('ap-pkg', a.p);
    btn.append(name, pkg);
    btn.addEventListener('click', () => {
      $('app-picker').hidden = true;
      ratectlCommand(`app set ${a.p} ${defHz}`, `已添加 ${a.n || a.p} -> ${defHz}Hz, 可在名单中调整档位。`);
    });
    frag.append(btn);
  });
  if (!items.length) frag.append(span('app-empty', kw ? '无匹配的应用。' : '没有更多可添加的应用。'));
  list.replaceChildren(frag);
}
$('app-add').addEventListener('click', openAppPicker);
$('ap-close').addEventListener('click', () => { $('app-picker').hidden = true; });
$('app-picker').addEventListener('click', event => {
  if (event.target === $('app-picker')) $('app-picker').hidden = true;
});
$('refresh').addEventListener('click', () => refresh(true));
$('apply').addEventListener('click', apply);
$('restore').addEventListener('click', restore);
$('verify-btn').addEventListener('click', () => verify());
$('verify-auto-btn').addEventListener('click', () => verify(true));
$('qq-input').addEventListener('keydown', event => {
  if (event.key === 'Enter') verify();
});

const THEME_KEY = 'dtbo_theme';
let theme = {};
try { theme = JSON.parse(localStorage.getItem(THEME_KEY)) || {}; } catch { theme = {}; }
function saveTheme() {
  try { localStorage.setItem(THEME_KEY, JSON.stringify(theme)); } catch { }
}
let dominantColor = '';
const modeQuery = window.matchMedia ? matchMedia('(prefers-color-scheme: dark)') : null;
function resolvedMode() {
  const pref = theme.mode || 'auto';
  if (pref === 'auto') return modeQuery && modeQuery.matches ? 'dark' : 'light';
  return pref;
}
function applyTheme() {
  const root = document.documentElement.style;
  const glass = !!theme.glass;
  root.setProperty('--bg-show', theme.bgShow ?? 0.35);
  root.setProperty('--card-alpha', theme.cardAlpha ?? 1);
  root.setProperty('--ctl-alpha', theme.ctlAlpha ?? 1);
  document.documentElement.dataset.mode = resolvedMode();
  document.documentElement.dataset.accent = theme.accent || 'green';
  $('bg-layer').style.backgroundImage = theme.img ? `url(${theme.img})` : '';
  document.body.classList.toggle('glass', glass);
  document.body.classList.toggle('hoverfx', theme.hover !== false);
  $('bg-show').value = theme.bgShow ?? 0.35;
  $('card-alpha').value = theme.cardAlpha ?? 1;
  $('ctl-alpha').value = theme.ctlAlpha ?? 1;
  $('glass-toggle').checked = glass;
  $('hover-toggle').checked = theme.hover !== false;
  const pref = theme.mode || 'auto';
  document.querySelectorAll('#mode-seg .mini-btn').forEach(b => b.classList.toggle('on', b.dataset.mode === pref));
  const accent = theme.accent || 'green';
  document.querySelectorAll('#accent-row .swatch').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.accent === accent)));
  updateStatusBar();
}
let themeRaf = 0;
function scheduleTheme() {
  if (themeRaf) return;
  themeRaf = requestAnimationFrame(() => { themeRaf = 0; applyTheme(); });
}
function updateStatusBar() {
  let color = getComputedStyle(document.documentElement).getPropertyValue('--sb').trim() || '#0c1310';
  if (theme.img) {
    if (dominantColor) color = dominantColor;
    else { extractDominant(); return; }
  }
  const meta = document.querySelector('meta[name=theme-color]');
  if (meta) meta.setAttribute('content', color);
  document.documentElement.style.backgroundColor = color;
}
function extractDominant() {
  const img = new Image();
  img.onload = () => {
    try {
      const c = document.createElement('canvas');
      c.width = 8; c.height = 8;
      const ctx = c.getContext('2d');
      ctx.drawImage(img, 0, 0, 8, 8);
      const d = ctx.getImageData(0, 0, 8, 8).data;
      let r = 0, g = 0, b = 0, n = 0;
      for (let i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2]; n++; }
      dominantColor = '#' + [r, g, b].map(v => Math.round(v / n * 0.6).toString(16).padStart(2, '0')).join('');
    } catch { dominantColor = ''; }
    updateStatusBar();
  };
  img.src = theme.img;
}
const panel = $('theme-panel');
let panelTimer = 0;
function panelOpen(open) {
  clearTimeout(panelTimer);
  if (open) {
    panel.hidden = false;
    panel.offsetHeight;
    panel.classList.add('open');
  } else {
    panel.classList.remove('open');
    panelTimer = setTimeout(() => { panel.hidden = true; }, 170);
  }
}
$('theme-btn').addEventListener('click', event => {
  event.stopPropagation();
  panelOpen(panel.hidden || !panel.classList.contains('open'));
});
$('theme-panel').addEventListener('click', event => event.stopPropagation());
document.addEventListener('click', () => panelOpen(false));
$('mode-seg').addEventListener('click', event => {
  const b = event.target.closest('button[data-mode]');
  if (!b) return;
  theme.mode = b.dataset.mode;
  saveTheme();
  applyTheme();
});
$('accent-row').addEventListener('click', event => {
  const b = event.target.closest('button[data-accent]');
  if (!b) return;
  theme.accent = b.dataset.accent;
  saveTheme();
  applyTheme();
});
if (modeQuery) {
  const onSchemeChange = () => { if ((theme.mode || 'auto') === 'auto') applyTheme(); };
  if (modeQuery.addEventListener) modeQuery.addEventListener('change', onSchemeChange);
  else if (modeQuery.addListener) modeQuery.addListener(onSchemeChange);
}
$('bg-pick').addEventListener('click', () => $('bg-file').click());
$('bg-clear').addEventListener('click', () => {
  delete theme.img;
  dominantColor = '';
  saveTheme();
  applyTheme();
});
$('bg-file').addEventListener('change', () => {
  const file = $('bg-file').files[0];
  $('bg-file').value = '';
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, 1080 / Math.max(image.width, image.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(image.width * scale);
      canvas.height = Math.round(image.height * scale);
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      theme.img = canvas.toDataURL('image/jpeg', 0.82);
      dominantColor = '';
      saveTheme();
      applyTheme();
    };
    image.src = reader.result;
  };
  reader.readAsDataURL(file);
});
const bindSlider = (id, key) => {
  $(id).addEventListener('input', () => { theme[key] = Number($(id).value); scheduleTheme(); });
  $(id).addEventListener('change', saveTheme);
};
bindSlider('bg-show', 'bgShow');
bindSlider('card-alpha', 'cardAlpha');
bindSlider('ctl-alpha', 'ctlAlpha');
$('glass-toggle').addEventListener('change', () => { theme.glass = $('glass-toggle').checked; saveTheme(); applyTheme(); });
$('hover-toggle').addEventListener('change', () => { theme.hover = $('hover-toggle').checked; saveTheme(); applyTheme(); });
applyTheme();

$('copy-machine').addEventListener('click', async () => {
  const id = state?.machine || $('machine-id').textContent;
  if (!id || id === '—') return;
  try {
    await navigator.clipboard.writeText(id);
    notify(`已复制主板ID: ${id}`);
  } catch {
    const input = document.createElement('textarea');
    input.value = id;
    document.body.append(input);
    input.select();
    document.execCommand('copy');
    input.remove();
    notify(`已复制主板ID: ${id}`);
  }
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) refresh(false);
});
refresh(false);
